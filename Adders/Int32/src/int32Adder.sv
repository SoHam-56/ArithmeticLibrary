`timescale 1ns / 100ps

// Signed 32-bit adder (PE accumulate, reducer tree): intAdder's algorithm at 32 bits, A + B mod 2^32 (two's-complement wrap);
// done_o one cycle after valid_i; only done_o is reset (D-8).
module int32Adder #(
    localparam int DATA_WIDTH = 32
) (
    input  logic                clk_i,
    input  logic                rstn_i,
    input  logic                valid_i,
    input  logic signed [DATA_WIDTH-1:0] a_i,
    input  logic signed [DATA_WIDTH-1:0] b_i,
    output logic signed [DATA_WIDTH-1:0] result_o,
    output logic                done_o
);
  always_ff @(posedge clk_i or negedge rstn_i)
    if (!rstn_i) done_o <= 1'b0;
    else done_o <= valid_i;

  // DATA_WIDTH-bit sum: the carry out of the top bit is dropped, which is the wrap.
  always_ff @(posedge clk_i) if (valid_i) result_o <= a_i + b_i;

endmodule
