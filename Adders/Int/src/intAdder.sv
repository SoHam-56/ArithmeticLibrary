`timescale 1ns / 100ps

// Signed integer adder: result_o = A + B mod 2^W (two's-complement wrap); done_o one cycle after valid_i; only done_o is reset (D-8).
module intAdder #(
    parameter int W = 32
) (
    input  logic                clk_i,
    input  logic                rstn_i,
    input  logic                valid_i,
    input  logic signed [W-1:0] A,
    input  logic signed [W-1:0] B,
    output logic signed [W-1:0] result_o,
    output logic                done_o
);
  always_ff @(posedge clk_i or negedge rstn_i)
    if (!rstn_i) done_o <= 1'b0;
    else done_o <= valid_i;

  // W-bit sum: the carry out of the top bit is dropped, which is the wrap.
  always_ff @(posedge clk_i) if (valid_i) result_o <= A + B;

endmodule
