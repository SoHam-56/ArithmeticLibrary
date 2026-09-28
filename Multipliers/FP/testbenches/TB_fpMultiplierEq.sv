`timescale 1ns / 100ps

// fpMultiplier at EXP_W=8, MAN_W=23 against fp32Multiplier on the shared stimulus: results, flags and done cycles bit for bit.
module TB_fpMultiplierEq #(
    parameter int RANDOM = 200000
);
  localparam int EXP_W = 8, MAN_W = 23, W = 32;
  logic clk = 0, rstn = 0;
  always #5 clk = ~clk;
  logic valid = 0;
  logic [W-1:0] a = '0, b = '0;
  logic [W-1:0] va[$], vb[$];
  `include "fp_stim.svh"

  logic [W-1:0] rg, rr;
  logic dg, dr, og, orr, ug, ur, ig, ir;
  fpMultiplier #(.EXP_W(EXP_W), .MAN_W(MAN_W)) dut (
      .clk_i(clk), .rstn_i(rstn), .valid_i(valid), .A(a), .B(b),
      .result_o(rg), .done_o(dg), .overflow_o(og), .underflow_o(ug), .invalid_o(ig));
  fp32Multiplier ref_mul (
      .clk_i(clk), .rstn_i(rstn), .valid_i(valid), .A(a), .B(b),
      .result_o(rr), .done_o(dr), .overflow_o(orr), .underflow_o(ur), .invalid_o(ir));

  int errs = 0;
  longint checked = 0;
  logic [W-1:0] qa[$], qb[$];
  always @(posedge clk)
    if (rstn && (dg || dr)) begin
      logic [W-1:0] x, y;
      x = qa.pop_front();
      y = qb.pop_front();
      checked++;
      if (dg !== dr || {rg, og, ug, ig} !== {rr, orr, ur, ir}) begin
        errs++;
        if (errs <= 20)
          $display("[FAIL] %h * %h: fpMultiplier %h (done %b ov %b un %b inv %b), fp32Multiplier %h (done %b ov %b un %b inv %b)",
                   x, y, rg, dg, og, ug, ig, rr, dr, orr, ur, ir);
      end
    end

  initial begin
    build_stimulus(RANDOM);
    repeat (3) @(posedge clk);
    #1 rstn = 1;
    repeat (2) @(posedge clk);
    foreach (va[i]) begin
      #1 valid = 1;
      a = va[i];
      b = vb[i];
      qa.push_back(a);
      qb.push_back(b);
      @(posedge clk);
    end
    #1 valid = 0;
    repeat (20) @(posedge clk);
    if (checked != va.size()) begin
      errs++;
      $display("[FAIL] %0d results for %0d inputs", checked, va.size());
    end
    $display("fpMultiplier (8, 23) against fp32Multiplier: %0d products, %0d mismatches", checked, errs);
    $display("RESULT: %s", errs == 0 ? "PASSED" : "FAILED");
    $finish;
  end
endmodule
