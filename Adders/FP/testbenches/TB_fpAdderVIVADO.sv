`timescale 1ns / 100ps

// fpAdder against a gen_vectors.cpp file (A B Res Flags in hex) with TB_fpAdder's rules; no DPI, so it runs in Vivado.
module TB_fpAdderVIVADO #(
    parameter int    EXP_W       = 8,
    parameter int    MAN_W       = 7,
    parameter int    NUM_VECTORS = 10000,
    parameter string VEC_FILE    = "vectors_bf16.mem"
);
  localparam int W = 1 + EXP_W + MAN_W;
  localparam int TOL = 3;
  logic [3*W+7:0] vec[NUM_VECTORS];
  logic clk = 0, rstn = 0;
  always #5 clk = ~clk;
  logic valid = 0;
  logic [W-1:0] a = '0, b = '0, res;
  logic done, ov, un, inv;
  fpAdder #(.EXP_W(EXP_W), .MAN_W(MAN_W)) dut (
      .clk_i(clk), .rstn_i(rstn), .valid_i(valid), .A(a), .B(b),
      .result_o(res), .done_o(done), .overflow_o(ov), .underflow_o(un), .invalid_o(inv));

  int errs = 0, checked = 0;
  logic [3*W+7:0] q[$];

  // Distance in ulps on the ordered line of values: -0 and +0 are the same point, as sign-magnitude subtraction is not.
  function automatic longint ord(input logic [W-1:0] x);
    return x[W-1] ? -longint'(x[W-2:0]) : longint'(x[W-2:0]);
  endfunction

  function automatic bit is_nan(input logic [W-1:0] x);
    return (x[W-2:MAN_W] == '1) && (x[MAN_W-1:0] != '0);
  endfunction

  always @(posedge clk)
    if (rstn && done) begin
      logic [W-1:0] ea, eb, er;
      logic [7:0] fl;
      logic [3*W+7:0] v;
      bit rm, fm;
      int diff;
      v = q.pop_front();  // a temporary: Verilator mishandles pop_front() inside a concatenation
      {ea, eb, er, fl} = v;
      checked++;
      diff = int'(ord(res) - ord(er));
      if (diff < 0) diff = -diff;
      rm = (res == er) || (is_nan(er) && is_nan(res)) || (!is_nan(er) && diff <= TOL) ||
           (un && res[W-2:0] == '0 && er[W-2:MAN_W] == '0);
      fm = (ov == fl[2]) && (inv == fl[4]) && ((un == fl[1]) || (un && res[W-2:0] == '0));
      if (!rm || !fm) begin
        errs++;
        if (errs <= 20) $display("[FAIL] %h + %h: got %h (ov %b un %b inv %b), expected %h flags %h", ea, eb, res, ov, un, inv, er, fl);
      end
    end

  initial begin
    $readmemh(VEC_FILE, vec);
    if (^vec[0] === 1'bx) $fatal(1, "TB_fpAdderVIVADO: could not read %s", VEC_FILE);
    repeat (3) @(posedge clk);
    #1 rstn = 1;
    repeat (2) @(posedge clk);
    for (int i = 0; i < NUM_VECTORS; i++) begin
      #1 valid = 1;
      {a, b} = vec[i][3*W+7:W+8];
      q.push_back(vec[i]);
      @(posedge clk);
    end
    #1 valid = 0;
    repeat (20) @(posedge clk);
    $display("fpAdder vectors %s: %0d checked, %0d errors", VEC_FILE, checked, errs);
    $display("RESULT: %s", (errs == 0 && checked == NUM_VECTORS) ? "PASSED" : "FAILED");
    $finish;
  end
endmodule
