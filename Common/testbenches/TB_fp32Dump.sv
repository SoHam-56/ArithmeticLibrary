`timescale 1ns / 100ps

// Drives fp32Multiplier and fp32Adder with the shared stimulus and dumps every result for the Python model: mul32.txt, add32.txt.
module TB_fp32Dump #(
    parameter int RANDOM = 200000
);
  localparam int EXP_W = 8, MAN_W = 23, W = 32;
  logic clk = 0, rstn = 0;
  always #5 clk = ~clk;
  logic valid = 0;
  logic [W-1:0] a = '0, b = '0;
  logic [W-1:0] va[$], vb[$];
  `include "fp_stim.svh"

  logic [W-1:0] rm, ra;
  logic dm, da, ovm, ova, unm, una, ivm, iva;
  fp32Multiplier MUL (.clk_i(clk), .rstn_i(rstn), .valid_i(valid), .A(a), .B(b), .result_o(rm), .done_o(dm),
                      .overflow_o(ovm), .underflow_o(unm), .invalid_o(ivm));
  fp32Adder ADD (.clk_i(clk), .rstn_i(rstn), .valid_i(valid), .A(a), .B(b), .result_o(ra), .done_o(da),
                 .overflow_o(ova), .underflow_o(una), .invalid_o(iva));

  logic [W-1:0] qa[$], qb[$], qa2[$], qb2[$];
  int fm, fa, nm = 0, na = 0;
  // Operands are popped into locals first: Verilator mis-evaluates two pop_front() calls in one $fwrite.
  always @(posedge clk) begin
    logic [W-1:0] x, y;
    if (dm) begin
      x = qa.pop_front();
      y = qb.pop_front();
      $fwrite(fm, "%h %h %h %b%b%b\n", x, y, rm, ovm, unm, ivm);
      nm++;
    end
    if (da) begin
      x = qa2.pop_front();
      y = qb2.pop_front();
      $fwrite(fa, "%h %h %h %b%b%b\n", x, y, ra, ova, una, iva);
      na++;
    end
  end

  initial begin
    fm = $fopen("mul32.txt", "w");
    fa = $fopen("add32.txt", "w");
    build_stimulus(RANDOM);
    repeat (3) @(posedge clk);
    #1 rstn = 1;
    repeat (2) @(posedge clk);
    foreach (va[i]) begin
      #1 valid = 1;
      a = va[i];
      b = vb[i];
      qa.push_back(a); qb.push_back(b); qa2.push_back(a); qb2.push_back(b);
      @(posedge clk);
    end
    #1 valid = 0;
    repeat (20) @(posedge clk);
    $fclose(fm);
    $fclose(fa);
    $display("TB_fp32Dump: %0d inputs, %0d products, %0d sums", va.size(), nm, na);
    $display("RESULT: %s", (nm == va.size() && na == va.size()) ? "PASSED" : "FAILED");
    $finish;
  end
endmodule
