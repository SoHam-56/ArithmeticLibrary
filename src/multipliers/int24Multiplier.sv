`timescale 1ns / 100ps

// 24 x 24 signed over three cycles (intMulPipe: 24 rows, the carry-save tree registered halfway, one add): sienna_fmt_pkg's int8
// POST_MUL_LATENCY.
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
  intMulPipe #(.AW(DATA_WIDTH), .BW(DATA_WIDTH), .STAGES(3)) u (
      .clk_i(clk_i), .rstn_i(rstn_i), .valid_i(valid_i), .a_i(a_i), .b_i(b_i), .result_o(result_o), .done_o(done_o));

endmodule
