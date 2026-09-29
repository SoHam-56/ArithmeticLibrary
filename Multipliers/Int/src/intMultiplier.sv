`timescale 1ns / 100ps

// Signed integer multiplier: result_o = A * B, the full 2W-bit product; done_o one cycle after valid_i; only done_o is reset (D-8).
module intMultiplier #(
    parameter int W = 8
) (
    input  logic                  clk_i,
    input  logic                  rstn_i,
    input  logic                  valid_i,
    input  logic signed [W-1:0]   A,
    input  logic signed [W-1:0]   B,
    output logic signed [2*W-1:0] result_o,
    output logic                  done_o
);
  always_ff @(posedge clk_i or negedge rstn_i)
    if (!rstn_i) done_o <= 1'b0;
    else done_o <= valid_i;

  // Both operands sign-extended to 2W bits, so the product is exact.
  always_ff @(posedge clk_i) if (valid_i) result_o <= (2 * W)'(A) * (2 * W)'(B);

endmodule
