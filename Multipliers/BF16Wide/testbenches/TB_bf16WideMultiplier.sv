`timescale 1ns / 100ps

// bf16WideMultiplier against Berkeley SoftFloat through DPI (fp_ref_core.h fpref_mul_wide): the fp32 product of two bf16 values is exact,
// so the result must equal SoftFloat's bit for bit (any NaN for a NaN, a flush to a signed zero where SoftFloat's product is tiny), flags
// checked. Shared stimulus by default; +A_LO=+A_HI= runs every b for each a in [A_LO, A_HI).
module TB_bf16WideMultiplier #(
    parameter int RANDOM = 200000
);
  localparam int EXPONENT_WIDTH = 8, MANTISSA_WIDTH = 7, DATA_WIDTH = 16, PRODUCT_WIDTH = 32;
  localparam int EXP_W = EXPONENT_WIDTH, MAN_W = MANTISSA_WIDTH, W = DATA_WIDTH;  // the names fp_stim.svh reads
  import "DPI-C" function int c_fp_mul_wide(input int a, input int b, input int man_w, output int flags);

  logic clk = 0, rstn = 0;
  always #5 clk = ~clk;
  logic valid = 0;
  logic [W-1:0] a = '0, b = '0;
  logic [W-1:0] va[$], vb[$];
  `include "fp_stim.svh"

  logic [PRODUCT_WIDTH-1:0] res;
  logic done, ov, un, inv;
  bf16WideMultiplier dut (
      .clk_i(clk), .rstn_i(rstn), .valid_i(valid), .a_i(a), .b_i(b),
      .result_o(res), .done_o(done), .overflow_o(ov), .underflow_o(un), .invalid_o(inv));

  typedef struct {
    logic [W-1:0] a, b;
    logic [PRODUCT_WIDTH-1:0] res;
    bit ov, un, inv;
  } tx_t;
  tx_t q[$];
  longint checked = 0, errs = 0;
  int cyc = 0, t_issue = -1, lat = -1;

  function automatic bit is_nan32(input logic [PRODUCT_WIDTH-1:0] x);
    return (x[30:23] == '1) && (x[22:0] != '0);
  endfunction

  task automatic drive(input logic [W-1:0] x, input logic [W-1:0] y);
    tx_t t;
    int fl;
    t.a = x;
    t.b = y;
    t.res = PRODUCT_WIDTH'(c_fp_mul_wide(int'(x), int'(y), MAN_W, fl));
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
      bit result_ok, flags_ok;
      if (lat < 0) lat = cyc - t_issue;  // edges from the one that took valid_i to the one that sees done_o
      if (q.size() == 0) begin
        errs++;
        $display("[FAIL] a result with nothing issued");
      end else begin
        t = q.pop_front();
        checked++;
        result_ok = (res == t.res) || (is_nan32(t.res) && is_nan32(res));  // exact: no rounding tolerance
        flags_ok = (ov == t.ov) && (inv == t.inv) && (un == t.un);
        if (!result_ok || !flags_ok) begin
          errs++;
          if (errs <= 20)
            $display("[FAIL] %h * %h: got %h (ov %b un %b inv %b), SoftFloat %h (ov %b un %b inv %b)",
                     t.a, t.b, res, ov, un, inv, t.res, t.ov, t.un, t.inv);
        end
      end
    end
  end

  initial begin
    int lo, hi;
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
    if (q.size() != 0) begin
      errs++;
      $display("[FAIL] %0d results never came out", q.size());
    end
    if (lat != sienna_fmt_pkg::MUL_LATENCY) begin
      errs++;
      $display("[FAIL] latency %0d, sienna_fmt_pkg::MUL_LATENCY says %0d", lat, sienna_fmt_pkg::MUL_LATENCY);
    end
    $display("bf16WideMultiplier: %0d exact fp32 products against SoftFloat, %0d errors, latency %0d", checked, errs, lat);
    $display("RESULT: %s", errs == 0 ? "PASSED" : "FAILED");
    $finish;
  end
endmodule
