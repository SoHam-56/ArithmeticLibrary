`timescale 1ns / 100ps

// Signed 24 x 24 -> 48 multiplier (GPNAE's POSTM): intMultiplier's algorithm at 24 bits; done_o one cycle after valid_i;
// only done_o is reset (D-8).
module int24Multiplier #(
    localparam int DATA_WIDTH = 24
) (
    input  logic                  clk_i,
    input  logic                  rstn_i,
    input  logic                  valid_i,
    input  logic signed [DATA_WIDTH-1:0]   a_i,
    input  logic signed [DATA_WIDTH-1:0]   b_i,
    output logic signed [2*DATA_WIDTH-1:0] result_o,
    output logic                  done_o
);
  always_ff @(posedge clk_i or negedge rstn_i)
    if (!rstn_i) done_o <= 1'b0;
    else done_o <= valid_i;

  // Both operands sign-extended to 2*DATA_WIDTH bits, so the product is exact.
  always_ff @(posedge clk_i) if (valid_i) result_o <= (2 * DATA_WIDTH)'(a_i) * (2 * DATA_WIDTH)'(b_i);

endmodule
