`timescale 1ns / 100ps

// fpAdder against Berkeley SoftFloat through DPI with TB_fp32Adder's rules: 3 ulp, any NaN for a NaN, flags checked,
// a flush accepted where the reference is tiny. Shared stimulus by default; +A_LO=+A_HI= runs every b for each a in [A_LO, A_HI).
// +DUMP=<file> writes every result for check_fpu.py.
module TB_fpAdder #(
    parameter int EXP_W  = 8,
    parameter int MAN_W  = 7,
    parameter int RANDOM = 200000
);
  localparam int W = 1 + EXP_W + MAN_W;
  localparam int TOL = 3;
  import "DPI-C" function int c_fp_add(input int a, input int b, input int man_w, output int flags);

  logic clk = 0, rstn = 0;
  always #5 clk = ~clk;
  logic valid = 0;
  logic [W-1:0] a = '0, b = '0;
  logic [W-1:0] va[$], vb[$];
  `include "fp_stim.svh"

  logic [W-1:0] res;
  logic done, ov, un, inv;
  fpAdder #(.EXP_W(EXP_W), .MAN_W(MAN_W)) dut (
      .clk_i(clk), .rstn_i(rstn), .valid_i(valid), .A(a), .B(b),
      .result_o(res), .done_o(done), .overflow_o(ov), .underflow_o(un), .invalid_o(inv));

  typedef struct {
    logic [W-1:0] a, b, res;
    bit ov, un, inv;
  } tx_t;
  tx_t q[$];
  longint checked = 0, errs = 0;
  int fd = 0, cyc = 0, t_issue = -1, lat = -1;
  string dump;

  // Distance in ulps on the ordered line of values: -0 and +0 are the same point, as sign-magnitude subtraction is not.
  function automatic longint ord(input logic [W-1:0] x);
    return x[W-1] ? -longint'(x[W-2:0]) : longint'(x[W-2:0]);
  endfunction

  function automatic bit is_nan(input logic [W-1:0] x);
    return (x[W-2:MAN_W] == '1) && (x[MAN_W-1:0] != '0);
  endfunction

  task automatic drive(input logic [W-1:0] x, input logic [W-1:0] y);
    tx_t t;
    int fl;
    t.a = x;
    t.b = y;
    t.res = W'(c_fp_add(int'(x), int'(y), MAN_W, fl));
    t.un = fl[1];
    t.ov = fl[2];
    t.inv = fl[4];
    q.push_back(t);
    #1 valid = 1;
    a = x;
    b = y;
    @(posedge clk);
  endtask

  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (valid && t_issue < 0) t_issue = cyc;
    if (rstn && done) begin
      tx_t t;
      bit rm, fm;
      int diff;
      if (lat < 0) lat = cyc - t_issue;  // edges from the one that took valid_i to the one that sees done_o
      if (q.size() == 0) begin
        errs++;
        $display("[FAIL] a result with nothing issued");
      end else begin
        t = q.pop_front();
        checked++;
        diff = int'(ord(res) - ord(t.res));
        if (diff < 0) diff = -diff;
        rm = (res == t.res) || (is_nan(t.res) && is_nan(res)) || (!is_nan(t.res) && diff <= TOL) ||
             (un && res[W-2:0] == '0 && t.res[W-2:MAN_W] == '0);
        fm = (ov == t.ov) && (inv == t.inv) && ((un == t.un) || (un && res[W-2:0] == '0));
        if (!rm || !fm) begin
          errs++;
          if (errs <= 20)
            $display("[FAIL] %h + %h: got %h (ov %b un %b inv %b), SoftFloat %h (ov %b un %b inv %b)",
                     t.a, t.b, res, ov, un, inv, t.res, t.ov, t.un, t.inv);
        end
        if (fd != 0) $fwrite(fd, "%h %h %h %b%b%b\n", t.a, t.b, res, ov, un, inv);
      end
    end
  end

  initial begin
    int lo, hi;
    if (EXP_W != 8) $fatal(1, "TB_fpAdder: the SoftFloat reference needs an 8-bit exponent");
    if ($value$plusargs("DUMP=%s", dump)) fd = $fopen(dump, "w");
    repeat (3) @(posedge clk);
    #1 rstn = 1;
    repeat (2) @(posedge clk);
    if ($value$plusargs("A_LO=%d", lo) && $value$plusargs("A_HI=%d", hi)) begin
      for (int x = lo; x < hi; x++)
        for (int y = 0; y < (1 << W); y++) drive(W'(x), W'(y));
    end else begin
      build_stimulus(RANDOM);
      foreach (va[i]) drive(va[i], vb[i]);
    end
    #1 valid = 0;
    repeat (20) @(posedge clk);
    if (fd != 0) $fclose(fd);
    if (q.size() != 0) begin
      errs++;
      $display("[FAIL] %0d results never came out", q.size());
    end
    if (lat != sienna_fmt_pkg::add_lat(EXP_W, MAN_W)) begin
      errs++;
      $display("[FAIL] latency %0d, sienna_fmt_pkg::add_lat says %0d", lat, sienna_fmt_pkg::add_lat(EXP_W, MAN_W));
    end
    $display("fpAdder EXP_W=%0d MAN_W=%0d: %0d sums against SoftFloat, %0d errors, latency %0d", EXP_W, MAN_W,
             checked, errs, lat);
    $display("RESULT: %s", errs == 0 ? "PASSED" : "FAILED");
    $finish;
  end
endmodule
