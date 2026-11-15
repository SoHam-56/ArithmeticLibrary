`timescale 1ns / 100ps

// The generic W x W signed multiplier the per-width units are proven against (eq_tops.sv): intMulPipe at the same STAGES as the unit.
module intMultiplier #(
    parameter int W      = 8,
    parameter int STAGES = 2
) (
    input  logic                  clk_i,
    input  logic                  rstn_i,
    input  logic                  valid_i,
    input  logic signed [W-1:0]   A,
    input  logic signed [W-1:0]   B,
    output logic signed [2*W-1:0] result_o,
    output logic                  done_o
);
  intMulPipe #(.AW(W), .BW(W), .STAGES(STAGES)) u (
      .clk_i(clk_i), .rstn_i(rstn_i), .valid_i(valid_i), .a_i(A), .b_i(B), .result_o(result_o), .done_o(done_o));

endmodule
