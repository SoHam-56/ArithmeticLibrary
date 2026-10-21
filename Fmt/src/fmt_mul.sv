`timescale 1ns / 100ps

// Multiply DATA_WIDTH-bit operands into an EXT_DATA_WIDTH-bit product: fp32 fp32Multiplier; bf16 bf16Multiplier at
// EXT_DATA_WIDTH = DATA_WIDTH, or bf16WideMultiplier, the exact fp32 product, at EXT_DATA_WIDTH = 32; int8 int8Multiplier, the
// 16-bit product sign-extended to EXT_DATA_WIDTH. No register of its own.
module fmt_mul #(
    parameter int DATA_WIDTH = sienna_fmt_pkg::DATA_WIDTH
`ifdef FMT_INT8
    , parameter int EXT_DATA_WIDTH = 2 * DATA_WIDTH
`else
    , parameter int EXT_DATA_WIDTH = DATA_WIDTH
`endif
) (
    input  logic                      clk_i,
    input  logic                      rstn_i,
    input  logic                      valid_i,
    input  logic [    DATA_WIDTH-1:0] a_i,
    input  logic [    DATA_WIDTH-1:0] b_i,
    output logic [EXT_DATA_WIDTH-1:0] product_o,
    output logic                      done_o
);
  if (sienna_fmt_pkg::FMT_DEFINE_COUNT > 1) begin : G_BAD_DEFINE
    $fatal(1, "fmt_mul: %0d precision defines, at most one", sienna_fmt_pkg::FMT_DEFINE_COUNT);
  end
  /* verilator lint_off PINCONNECTEMPTY */
`ifdef FMT_INT8
  if (DATA_WIDTH != 8 || EXT_DATA_WIDTH < 16) begin : G_BAD_DATA_WIDTH
    $fatal(1, "fmt_mul: int8 multiplies DATA_WIDTH = 8 into EXT_DATA_WIDTH >= 16, not %0d into %0d", DATA_WIDTH, EXT_DATA_WIDTH);
  end else begin : G_INT8  // only a legal width elaborates the multiplier
    logic signed [15:0] int8_product;
    int8Multiplier MUL (.clk_i(clk_i), .rstn_i(rstn_i), .valid_i(valid_i), .a_i(a_i), .b_i(b_i), .result_o(int8_product), .done_o(done_o));
    assign product_o = EXT_DATA_WIDTH'(int8_product);  // sign-extended: int8_product is signed
  end
`elsif FMT_BF16
  if (DATA_WIDTH != 16 || (EXT_DATA_WIDTH != 16 && EXT_DATA_WIDTH != 32)) begin : G_BAD_DATA_WIDTH
    $fatal(1, "fmt_mul: bf16 multiplies DATA_WIDTH = 16 into EXT_DATA_WIDTH = 16 or 32, not %0d into %0d", DATA_WIDTH, EXT_DATA_WIDTH);
  end else if (EXT_DATA_WIDTH == 32) begin : G_WIDEN
    bf16WideMultiplier MUL (.clk_i(clk_i), .rstn_i(rstn_i), .valid_i(valid_i), .a_i(a_i), .b_i(b_i), .result_o(product_o),
        .done_o(done_o), .overflow_o(), .underflow_o(), .invalid_o());
  end else begin : G_LANE
    bf16Multiplier MUL (.clk_i(clk_i), .rstn_i(rstn_i), .valid_i(valid_i), .a_i(a_i), .b_i(b_i), .result_o(product_o),
        .done_o(done_o), .overflow_o(), .underflow_o(), .invalid_o());
  end
`else
  if (DATA_WIDTH != 32 || EXT_DATA_WIDTH != 32) begin : G_BAD_DATA_WIDTH
    $fatal(1, "fmt_mul: fp32 multiplies DATA_WIDTH = 32 into EXT_DATA_WIDTH = 32, not %0d into %0d", DATA_WIDTH, EXT_DATA_WIDTH);
  end else begin : G_FP32  // only a legal width elaborates the multiplier
    fp32Multiplier MUL (.clk_i(clk_i), .rstn_i(rstn_i), .valid_i(valid_i), .A(a_i), .B(b_i), .result_o(product_o),
        .done_o(done_o), .overflow_o(), .underflow_o(), .invalid_o());
  end
`endif
  /* verilator lint_on PINCONNECTEMPTY */
endmodule
