`timescale 1ns / 100ps

// fpAdder at EXP_W=8, MAN_W=23 against fp32Adder on the shared stimulus: results, underflow, invalid and done cycles bit for bit;
// overflow too, except where fp32Adder raises it on a cancellation that underflows (D-1), which is counted and listed.
module TB_fpAdderEq #(
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
  fpAdder #(.EXP_W(EXP_W), .MAN_W(MAN_W)) dut (
      .clk_i(clk), .rstn_i(rstn), .valid_i(valid), .A(a), .B(b),
      .result_o(rg), .done_o(dg), .overflow_o(og), .underflow_o(ug), .invalid_o(ig));
  fp32Adder ref_add (
      .clk_i(clk), .rstn_i(rstn), .valid_i(valid), .A(a), .B(b),
      .result_o(rr), .done_o(dr), .overflow_o(orr), .underflow_o(ur), .invalid_o(ir));

  int errs = 0, quirk = 0;
  longint checked = 0;
  logic [W-1:0] qa[$], qb[$];
  always @(posedge clk)
    if (rstn && (dg || dr)) begin
      logic [W-1:0] x, y;
      x = qa.pop_front();
      y = qb.pop_front();
      checked++;
      if (dg !== dr || {rg, ug, ig} !== {rr, ur, ir}) begin
        errs++;
        if (errs <= 20)
          $display("[FAIL] %h + %h: fpAdder %h (done %b ov %b un %b inv %b), fp32Adder %h (done %b ov %b un %b inv %b)",
                   x, y, rg, dg, og, ug, ig, rr, dr, orr, ur, ir);
      end else if (og !== orr) begin
        if (orr && !og && ur && rr[W-2:0] == '0) begin
          quirk++;
          if (quirk <= 5) $display("[D-1] %h + %h: fp32Adder raises overflow with a flushed underflow", x, y);
        end else begin
          errs++;
          if (errs <= 20) $display("[FAIL] %h + %h: overflow fpAdder %b, fp32Adder %b", x, y, og, orr);
        end
      end
    end

  initial begin
    build_stimulus(RANDOM);
    repeat (8) @(posedge clk);  // the fp32 units' unreset valid stages need 4+ cycles of reset to flush
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
    $display("fpAdder (8, 23) against fp32Adder: %0d sums, %0d mismatches, %0d D-1 overflow flags", checked, errs, quirk);
    $display("RESULT: %s", errs == 0 ? "PASSED" : "FAILED");
    $finish;
  end
endmodule
