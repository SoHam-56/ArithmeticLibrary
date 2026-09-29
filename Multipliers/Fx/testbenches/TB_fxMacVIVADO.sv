`timescale 1ns / 100ps

// fxMac against a gen_int_vectors.cpp file (A X C Res in hex), bit for bit; no DPI, so it runs in Vivado.
module TB_fxMacVIVADO #(
    parameter int    W           = 16,
    parameter int    FRAC        = 11,
    parameter int    NUM_VECTORS = 10000,
    parameter string VEC_FILE    = "vectors_q4_11.mem"
);
  logic [4*W-1:0] vec[NUM_VECTORS];
  logic clk = 0, rstn = 0;
  always #5 clk = ~clk;
  logic valid = 0;
  logic signed [W-1:0] a = '0, x = '0, c = '0, res;
  logic done;
  fxMac #(.W(W), .FRAC(FRAC)) dut (
      .clk_i(clk), .rstn_i(rstn), .valid_i(valid), .A(a), .X(x), .C(c), .result_o(res), .done_o(done));

  int errs = 0, checked = 0;
  logic [4*W-1:0] q[$];

  always @(posedge clk)
    if (rstn && done) begin
      logic [W-1:0] ea, ex, ec, er;
      logic [4*W-1:0] v;
      v = q.pop_front();  // a temporary: Verilator mishandles pop_front() inside a concatenation
      {ea, ex, ec, er} = v;
      checked++;
      if (res !== er) begin
        errs++;
        if (errs <= 20) $display("[FAIL] %h * %h + %h: got %h, expected %h", ea, ex, ec, res, er);
      end
    end

  initial begin
    $readmemh(VEC_FILE, vec);
    if (^vec[0] === 1'bx) $fatal(1, "TB_fxMacVIVADO: could not read %s", VEC_FILE);
    repeat (8) @(posedge clk);
    #1 rstn = 1;
    repeat (2) @(posedge clk);
    for (int i = 0; i < NUM_VECTORS; i++) begin
      #1 valid = 1;
      {a, x, c} = vec[i][4*W-1:W];
      q.push_back(vec[i]);
      @(posedge clk);
    end
    #1 valid = 0;
    repeat (20) @(posedge clk);
    $display("fxMac vectors %s: %0d checked, %0d errors", VEC_FILE, checked, errs);
    $display("RESULT: %s", (errs == 0 && checked == NUM_VECTORS) ? "PASSED" : "FAILED");
    $finish;
  end
endmodule
