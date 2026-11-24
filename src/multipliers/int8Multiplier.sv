`timescale 1ns / 100ps

// 8 x 8 signed over four cycles (the operands registered here, then intMulPipe: one row per bit of b_i, two of the tree's four levels,
// the other two, one add):
// sienna_fmt_pkg's int8 MUL_LATENCY, the mesh product (the rows and the whole tree in stage 1, behind the operand's fanout, were the int8
// meshes' 0.86-0.91 ns at 0.8, PE b_o -> MUL s1_q).
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
  // The operands registered here first: in the PE, a_i and b_i are the registers that also feed the next PE, and their fanout into the
  // rows was ahead of stage 1 (PE a_o/b_o -> MUL s1_q).
  logic                         v_q;
  logic signed [DATA_WIDTH-1:0] a_q, b_q;
  always_ff @(posedge clk_i or negedge rstn_i)
    if (!rstn_i) v_q <= 1'b0;
    else v_q <= valid_i;
  always_ff @(posedge clk_i)
    if (valid_i) {a_q, b_q} <= {a_i, b_i};  // no reset: read only with v_q
  intMulPipe #(.AW(DATA_WIDTH), .BW(DATA_WIDTH), .STAGES(3)) u (
      .clk_i(clk_i), .rstn_i(rstn_i), .valid_i(v_q), .a_i(a_q), .b_i(b_q), .result_o(result_o), .done_o(done_o));

endmodule
