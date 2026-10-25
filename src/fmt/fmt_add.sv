`timescale 1ns / 100ps

// Add at DATA_WIDTH bits, the adder picked by width: fp32Adder in fp32 and in bf16 at DATA_WIDTH = 32 (PE, reducer); bf16Adder in bf16
// at DATA_WIDTH = 16 (GPNAE POSTD); int32Adder in int8. add_latency(DATA_WIDTH) cycles. No register of its own.
module fmt_add #(
    parameter int DATA_WIDTH = sienna_fmt_pkg::ACC_DATA_WIDTH
) (
    input  logic                  clk_i,
    input  logic                  rstn_i,
    input  logic                  valid_i,
    input  logic [DATA_WIDTH-1:0] a_i,
    input  logic [DATA_WIDTH-1:0] b_i,
    output logic [DATA_WIDTH-1:0] sum_o,
    output logic                  done_o
);
  if (sienna_fmt_pkg::FMT_DEFINE_COUNT > 1) begin : G_BAD_DEFINE
    $fatal(1, "fmt_add: %0d precision defines, at most one", sienna_fmt_pkg::FMT_DEFINE_COUNT);
  end
  /* verilator lint_off PINCONNECTEMPTY */
`ifdef FMT_INT8
  if (DATA_WIDTH != sienna_fmt_pkg::ACC_DATA_WIDTH) begin : G_BAD_DATA_WIDTH
    $fatal(1, "fmt_add: int8 adds at the accumulator width %0d only (int32Adder; no lane add), not DATA_WIDTH = %0d", sienna_fmt_pkg::ACC_DATA_WIDTH, DATA_WIDTH);
  end else begin : G_INT32  // only a legal width elaborates the adder
    int32Adder ADD (.clk_i(clk_i), .rstn_i(rstn_i), .valid_i(valid_i), .a_i(a_i), .b_i(b_i), .result_o(sum_o), .done_o(done_o));
  end
`elsif FMT_BF16
  if (DATA_WIDTH != 32 && DATA_WIDTH != 16) begin : G_BAD_DATA_WIDTH
    $fatal(1, "fmt_add: a float build adds at the accumulator width %0d or the format width %0d, not DATA_WIDTH = %0d", sienna_fmt_pkg::ACC_DATA_WIDTH, sienna_fmt_pkg::DATA_WIDTH, DATA_WIDTH);
  end else if (DATA_WIDTH == 32) begin : G_FP32  // the accumulator add: fp32 in bf16 builds too
    fp32Adder ADD (.clk_i(clk_i), .rstn_i(rstn_i), .valid_i(valid_i), .A(a_i), .B(b_i), .result_o(sum_o), .done_o(done_o), .overflow_o(),
        .underflow_o(), .invalid_o());
  end else begin : G_BF16
    bf16Adder ADD (.clk_i(clk_i), .rstn_i(rstn_i), .valid_i(valid_i), .a_i(a_i), .b_i(b_i), .result_o(sum_o), .done_o(done_o), .overflow_o(),
        .underflow_o(), .invalid_o());
  end
`else
  if (DATA_WIDTH != 32) begin : G_BAD_DATA_WIDTH
    $fatal(1, "fmt_add: a float build adds at the accumulator width %0d or the format width %0d, not DATA_WIDTH = %0d", sienna_fmt_pkg::ACC_DATA_WIDTH, sienna_fmt_pkg::DATA_WIDTH, DATA_WIDTH);
  end else begin : G_FP32  // only a legal width elaborates an adder
    fp32Adder ADD (.clk_i(clk_i), .rstn_i(rstn_i), .valid_i(valid_i), .A(a_i), .B(b_i), .result_o(sum_o), .done_o(done_o), .overflow_o(),
        .underflow_o(), .invalid_o());
  end
`endif
  /* verilator lint_on PINCONNECTEMPTY */
endmodule
