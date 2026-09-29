`timescale 1ns / 100ps

// fxMac against the C reference through DPI: default triples, or +MODE/+FIXED/+LO/+HI sweep slices with a +DIGEST for check_ipu.py.
module TB_fxMac #(
    parameter int W      = 16,
    parameter int FRAC   = 11,
    parameter int RANDOM = 200000,
    parameter int BOUND  = 5000
);
  localparam int LAT = sienna_fmt_pkg::fx_lat();  // fxMac's latency
  localparam int ONE = 1 << FRAC;
  localparam int MAXV = (1 << (W - 1)) - 1;
  localparam int MINV = -(1 << (W - 1));
  import "DPI-C" function int c_fx_mac(input int a, input int x, input int c, input int w, input int frac);

  // A, X, C and the Q4.11 result worked by hand: floor on negative products, saturation after the add and not before.
  localparam int NK = 10;
  localparam int KV[NK][4] = '{'{-1, 1, 0, -1}, '{3, -683, 0, -2}, '{2048, 2048, 0, 2048}, '{-32768, -32768, 0, 32767},
                               '{32767, -32768, 0, -32768}, '{2048, 32767, 1, 32767}, '{2048, 32766, 1, 32767},
                               '{2048, -32768, -1, -32768}, '{-2048, -32768, -1, 32767}, '{-2048, -32768, -32768, 0}};
  localparam int NC = 19;
  localparam int CORNER[NC] = '{0, 1, -1, 2, -2, ONE - 1, ONE, ONE + 1, -(ONE - 1), -ONE, -(ONE + 1), 2 * ONE, -2 * ONE,
                                MAXV / 2 + 1, MINV / 2, int'({(W / 2) {2'b01}}), int'($signed({(W / 2) {2'b10}})), MAXV, MINV};
  localparam int NCC = 7;
  localparam int CC[NCC] = '{0, 1, -1, ONE / 2, -(ONE / 2), MAXV, MINV};

  logic clk = 0, rstn = 0;
  always #5 clk = ~clk;
  logic valid = 0;
  logic signed [W-1:0] a = '0, x = '0, c = '0, res;
  logic done;
  fxMac #(.W(W), .FRAC(FRAC)) dut (
      .clk_i(clk), .rstn_i(rstn), .valid_i(valid), .A(a), .X(x), .C(c), .result_o(res), .done_o(done));

  typedef struct {
    logic [W-1:0] a, x, c, res;
    int outer, inner;
  } tx_t;
  tx_t q[$];
  logic [W-1:0] va[$], vx[$], vc[$];
  longint checked = 0, errs = 0, idles = 0, n_expect = 0, s1 = 0, s2 = 0;
  int fd = 0, fdig = 0, cyc = 0, t_issue = -1, lat = -1, cur = -1;
  string dump, dig, mode;

  function automatic int sx(input logic [W-1:0] v);  // a W-bit pattern as a signed int
    return int'($signed(v));
  endfunction

  function automatic void push(input int ia, input int ix, input int ic);
    va.push_back(W'(ia));
    vx.push_back(W'(ix));
    vc.push_back(W'(ic));
  endfunction

  task automatic build_stimulus();
    if (W == 16 && FRAC == 11)
      for (int i = 0; i < NK; i++) push(KV[i][0], KV[i][1], KV[i][2]);
    for (int i = 0; i < NC; i++)
      for (int j = 0; j < NC; j++)
        for (int k = 0; k < NCC; k++) push(CORNER[i], CORNER[j], CC[k]);
    // C chosen so floor(A*X / 2^FRAC) + C is MAX-1, MAX, MAX+1, MIN-1, MIN or MIN+1, where such a C exists.
    for (int n = 0; n < BOUND; n++) begin
      automatic int ra = int'($urandom_range(0, 4 * ONE)) - 2 * ONE;
      automatic int rx = sx(W'($urandom));
      automatic longint p = (longint'(ra) * longint'(rx)) >>> FRAC;
      for (int d = -1; d <= 1; d++) begin
        automatic longint ch = longint'(MAXV) - p + d;
        automatic longint cl = longint'(MINV) - p + d;
        if (ch >= MINV && ch <= MAXV) push(ra, rx, int'(ch));
        if (cl >= MINV && cl <= MAXV) push(ra, rx, int'(cl));
      end
    end
    for (int n = 0; n < RANDOM; n++) push(sx(W'($urandom)), sx(W'($urandom)), sx(W'($urandom)));
  endtask

  task automatic drive(input logic [W-1:0] ia, input logic [W-1:0] ix, input logic [W-1:0] ic, input int outer, input int inner);
    tx_t t;
    t.a = ia;
    t.x = ix;
    t.c = ic;
    t.res = W'(c_fx_mac(sx(ia), sx(ix), sx(ic), W, FRAC));
    t.outer = outer;
    t.inner = inner;
    q.push_back(t);
    #1 valid = 1;
    a = ia;
    x = ix;
    c = ic;
    @(posedge clk);
  endtask

  // One cycle without valid_i, with junk on the operands.
  task automatic idle();
    #1 valid = 0;
    a = W'($urandom);
    x = W'($urandom);
    c = W'($urandom);
    idles++;
    @(posedge clk);
  endtask

  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (valid && t_issue < 0) t_issue = cyc;
    if (rstn && done) begin
      tx_t t;
      logic [W-1:0] ru;
      if (lat < 0) lat = cyc - t_issue;  // edges from the one that took valid_i to the one that sees done_o
      if (q.size() == 0) begin
        errs++;
        $display("[FAIL] a result with nothing issued");
      end else begin
        t = q.pop_front();
        checked++;
        ru = res;
        if (ru !== t.res) begin
          errs++;
          if (errs <= 20) $display("[FAIL] %h * %h + %h: got %h, reference %h", t.a, t.x, t.c, ru, t.res);
        end
        if (fd != 0) $fwrite(fd, "%h %h %h %h\n", t.a, t.x, t.c, ru);
        if (fdig != 0) begin
          if (t.outer != cur) begin
            if (cur >= 0) $fwrite(fdig, "%0d %0d %0d\n", cur, s1, s2);
            cur = t.outer;
            s1 = 0;
            s2 = 0;
          end
          s1 += longint'(ru);
          s2 += longint'(ru) * longint'(t.inner);
        end
      end
    end
  end

  initial begin
    int lo, hi;
    bit ax;
    logic [W-1:0] fixed;
    if (W > 16) $fatal(1, "TB_fxMac: the sweep and the DPI reference assume W <= 16");
    if (W == 16 && FRAC == 11)
      for (int i = 0; i < NK; i++)
        if (c_fx_mac(KV[i][0], KV[i][1], KV[i][2], W, FRAC) != KV[i][3])
          $fatal(1, "TB_fxMac: the C reference fails known triple %0d", i);
    if ($value$plusargs("DUMP=%s", dump)) fd = $fopen(dump, "w");
    repeat (8) @(posedge clk);
    #1 rstn = 1;
    repeat (2) @(posedge clk);
    if ($value$plusargs("MODE=%s", mode)) begin
      if (!$value$plusargs("FIXED=%h", fixed) || !$value$plusargs("LO=%d", lo) || !$value$plusargs("HI=%d", hi))
        $fatal(1, "TB_fxMac: a sweep needs +FIXED=, +LO= and +HI=");
      if (mode != "AX" && mode != "XC") $fatal(1, "TB_fxMac: MODE is AX or XC, not %s", mode);
      ax = (mode == "AX");
      n_expect = longint'(hi - lo) << W;
      if ($value$plusargs("DIGEST=%s", dig)) begin
        fdig = $fopen(dig, "w");
        $fwrite(fdig, "# fxMac digest MODE=%s FIXED=%h LO=%0d HI=%0d\n", mode, fixed, lo, hi);
      end
      $display("sweep MODE=%s FIXED=%h outer [%0d, %0d)", mode, fixed, lo, hi);
      for (int o = lo; o < hi; o++)
        for (int i = 0; i < (1 << W); i++)
          if (ax) drive(W'(o), W'(i), fixed, o, i);
          else drive(fixed, W'(o), W'(i), o, i);
    end else begin
      build_stimulus();
      n_expect = va.size();
      foreach (va[k]) begin
        drive(va[k], vx[k], vc[k], k, 0);
        if ($urandom_range(0, 7) == 0) idle();
      end
    end
    #1 valid = 0;
    repeat (20) @(posedge clk);
    if (fd != 0) $fclose(fd);
    if (fdig != 0) begin
      if (cur >= 0) $fwrite(fdig, "%0d %0d %0d\n", cur, s1, s2);
      $fclose(fdig);
    end
    if (q.size() != 0) begin
      errs++;
      $display("[FAIL] %0d results never came out", q.size());
    end
    if (checked != n_expect) begin
      errs++;
      $display("[FAIL] %0d results for %0d inputs", checked, n_expect);
    end
    if (lat != LAT) begin
      errs++;
      $display("[FAIL] latency %0d, fxMac's is %0d", lat, LAT);
    end
    $display("fxMac W=%0d FRAC=%0d: %0d results against the C reference, %0d errors, latency %0d, %0d idle cycles", W, FRAC,
             checked, errs, lat, idles);
    $display("RESULT: %s", errs == 0 ? "PASSED" : "FAILED");
    $finish;
  end
endmodule
