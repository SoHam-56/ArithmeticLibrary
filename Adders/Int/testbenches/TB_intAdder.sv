`timescale 1ns / 100ps

// intAdder against the C reference through DPI: wrap corners, corner pairs, carry chains, random pairs; +DUMP=<file> writes results.
module TB_intAdder #(
    parameter int W      = 32,
    parameter int RANDOM = 1000000
);
  import "DPI-C" function int c_int_add(input int a, input int b, input int w);
  localparam logic [W-1:0] ONE = W'(1);
  localparam logic [W-1:0] ONES = {W{1'b1}};
  localparam logic [W-1:0] MX = {1'b0, {(W - 1) {1'b1}}};
  localparam logic [W-1:0] MN = {1'b1, {(W - 1) {1'b0}}};
  // MAX+1, MIN-1, MIN+MIN, MAX+MAX, -1+1, MIN+MAX, with their sums worked by hand.
  localparam int NK = 6;
  localparam logic [W-1:0] KA[NK] = '{MX, MN, MN, MX, ONES, MN};
  localparam logic [W-1:0] KB[NK] = '{ONE, ONES, MN, MX, ONE, MX};
  localparam logic [W-1:0] KR[NK] = '{MN, MX, '0, ONES - ONE, '0, ONES};
  localparam int NC = 14;
  localparam logic [W-1:0] CORNER[NC] = '{'0, ONE, ONES, ONE + ONE, ONES - ONE, MX, MN, MX - ONE, MN + ONE, {(W / 2) {2'b01}},
                                          {(W / 2) {2'b10}}, ONES >> (W / 2), ONES << (W / 2), ONE << (W / 2)};

  logic clk = 0, rstn = 0;
  always #5 clk = ~clk;
  logic valid = 0;
  logic signed [W-1:0] a = '0, b = '0, res;
  logic done;
  intAdder #(.W(W)) dut (.clk_i(clk), .rstn_i(rstn), .valid_i(valid), .A(a), .B(b), .result_o(res), .done_o(done));

  typedef struct {
    logic [W-1:0] a, b, res;
  } tx_t;
  tx_t q[$];
  logic [W-1:0] va[$], vb[$];
  longint checked = 0, errs = 0, idles = 0;
  int fd = 0, cyc = 0, t_issue = -1, lat = -1;
  string dump;

  function automatic void push(input logic [W-1:0] x, input logic [W-1:0] y);
    va.push_back(x);
    vb.push_back(y);
  endfunction

  task automatic build_stimulus();
    for (int i = 0; i < NK; i++) push(KA[i], KB[i]);
    for (int i = 0; i < NC; i++)
      for (int j = 0; j < NC; j++) push(CORNER[i], CORNER[j]);
    for (int k = 0; k < W; k++) begin  // carries rippling through k bits, borrows through the top, every power of two doubled
      push((ONE << k) - ONE, ONE);
      push(ONES << k, ONES);
      push(ONE << k, ONE << k);
    end
    for (int n = 0; n < RANDOM; n++)
      if (n % 4 == 0)
        push($urandom_range(0, 1) ? MX - W'($urandom_range(0, 255)) : MN + W'($urandom_range(0, 255)),
             W'($signed(9'($urandom_range(0, 511)))));  // within 255 of a rail, a step of -256..255
      else push(W'($urandom), W'($urandom));
  endtask

  task automatic drive(input logic [W-1:0] x, input logic [W-1:0] y);
    tx_t t;
    t.a = x;
    t.b = y;
    t.res = W'(c_int_add(int'(x), int'(y), W));
    q.push_back(t);
    #1 valid = 1;
    a = x;
    b = y;
    @(posedge clk);
  endtask

  // One cycle without valid_i, with junk on the operands.
  task automatic idle();
    #1 valid = 0;
    a = W'($urandom);
    b = W'($urandom);
    idles++;
    @(posedge clk);
  endtask

  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (valid && t_issue < 0) t_issue = cyc;
    if (rstn && done) begin
      tx_t t;
      if (lat < 0) lat = cyc - t_issue;  // edges from the one that took valid_i to the one that sees done_o
      if (q.size() == 0) begin
        errs++;
        $display("[FAIL] a result with nothing issued");
      end else begin
        t = q.pop_front();
        checked++;
        if (res !== t.res) begin
          errs++;
          if (errs <= 20) $display("[FAIL] %h + %h: got %h, reference %h", t.a, t.b, res, t.res);
        end
        if (fd != 0) $fwrite(fd, "%h %h %h\n", t.a, t.b, res);
      end
    end
  end

  initial begin
    if (W > 32) $fatal(1, "TB_intAdder: the DPI reference passes 32-bit ints");
    for (int i = 0; i < NK; i++)
      if (W'(c_int_add(int'(KA[i]), int'(KB[i]), W)) !== KR[i]) $fatal(1, "TB_intAdder: the C reference fails known sum %0d", i);
    if ($value$plusargs("DUMP=%s", dump)) fd = $fopen(dump, "w");
    build_stimulus();
    repeat (8) @(posedge clk);
    #1 rstn = 1;
    repeat (2) @(posedge clk);
    foreach (va[i]) begin
      drive(va[i], vb[i]);
      if ($urandom_range(0, 7) == 0) idle();
    end
    #1 valid = 0;
    repeat (20) @(posedge clk);
    if (fd != 0) $fclose(fd);
    if (q.size() != 0) begin
      errs++;
      $display("[FAIL] %0d results never came out", q.size());
    end
    if (checked != va.size()) begin
      errs++;
      $display("[FAIL] %0d results for %0d inputs", checked, va.size());
    end
    if (lat != sienna_fmt_pkg::add_lat(0, 7)) begin
      errs++;
      $display("[FAIL] latency %0d, sienna_fmt_pkg::add_lat(0, 7) says %0d", lat, sienna_fmt_pkg::add_lat(0, 7));
    end
    $display("intAdder W=%0d: %0d sums against the C reference, %0d errors, latency %0d, %0d idle cycles", W, checked, errs, lat,
             idles);
    $display("RESULT: %s", errs == 0 ? "PASSED" : "FAILED");
    $finish;
  end
endmodule
