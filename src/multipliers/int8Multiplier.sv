`timescale 1ns / 100ps

// 8 x 8 signed over two cycles (intMulPipe: one row per bit of b_i, a carry-save tree, one add): sienna_fmt_pkg's int8 MUL_LATENCY, the
// mesh product.
module int8Multiplier #(
    localparam int DATA_WIDTH = 8
) (
    input  logic                  clk_i,
    input  logic                  rstn_i,
    input  logic                  valid_i,
    input  logic signed [DATA_WIDTH-1:0]   a_i,
    input  logic signed [DATA_WIDTH-1:0]   b_i,
    output logic signed [2*DATA_WIDTH-1:0] result_o,
    output logic                  done_o
);
  intMulPipe #(.AW(DATA_WIDTH), .BW(DATA_WIDTH), .STAGES(2)) u (
      .clk_i(clk_i), .rstn_i(rstn_i), .valid_i(valid_i), .a_i(a_i), .b_i(b_i), .result_o(result_o), .done_o(done_o));

endmodule
