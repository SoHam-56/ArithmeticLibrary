`timescale 1ns / 100ps

// Checks sienna_fmt_pkg's define map under the build's define against the restructure spec's table, typed in here independently: the
// precision constants, the bundles' widths, the lane constants, the latency functions at each width, fmt_greater_than, fmt_relu and fmt_drop; +define+NO_FMT_DEFINE
// marks a build with no define, which must give fp32's values with FMT_DEFINE_COUNT 0.
module TB_sienna_fmt_map;
  import sienna_fmt_pkg::*;
  int errs = 0, checks = 0;

  task automatic expect_eq(input string what, input int got, input int want);
    checks++;
    if (got != want) begin
      errs++;
      $display("[FAIL] %s %s: got %0d (%0h), want %0d (%0h)", FORMAT_NAME, what, got, got, want, want);
    end
  endtask

`ifdef FMT_INT8
  localparam string WANT_NAME = "int8";
  localparam int WANT[15] = '{8, 32, 32, 32, 16, 1, 1, 1, 0, 4, 6, 0, 0, 1, 1};  // widths, latencies, the HAS_ flags
  localparam int WANT_LOWEST = 32'h80, WANT_ONE = 1;
  localparam int WANT_BITS[5] = '{67, 54, 110, 83, 30};  // lane_params_t, requant_params_t, add_params_t, lane_entry_t, requant_scale_t
  localparam int WANT_KEEP = 1;  // DROPOUT_KEEP_SCALE, unused in int8
  localparam int WANT_LANE[4] = '{0, 7, 3, 1};  // EXPONENT_WIDTH, MANTISSA_WIDTH, HORNER_STEP_LATENCY, HORNER_COEFFICIENT_LAG
`elsif FMT_BF16
  localparam string WANT_NAME = "bf16";
  localparam int WANT[15] = '{16, 32, 16, 16, 16, 3, 5, 3, 5, 0, 0, 3, 1, 0, 0};
  localparam int WANT_LOWEST = 32'hFF80, WANT_ONE = 32'h3F80;
  localparam int WANT_BITS[5] = '{1, 1, 1, 1, 1};
  localparam int WANT_KEEP = 32'h4000;
  localparam int WANT_LANE[4] = '{8, 7, 8, 3};
`else
  localparam string WANT_NAME = "fp32";
  localparam int WANT[15] = '{32, 32, 32, 32, 32, 8, 5, 8, 5, 0, 0, 8, 0, 0, 0};  // fp32 has no GPNAE tail
  localparam int WANT_LOWEST = 32'hFF800000, WANT_ONE = 32'h3F800000;
  localparam int WANT_BITS[5] = '{1, 1, 1, 1, 1};
  localparam int WANT_KEEP = 32'h40000000;
  localparam int WANT_LANE[4] = '{8, 23, 13, 8};
`endif
`ifdef NO_FMT_DEFINE
  localparam int WANT_DEFINES = 0;
`else
  localparam int WANT_DEFINES = 1;
`endif

  initial begin
    if (FORMAT_NAME != WANT_NAME) begin
      errs++;
      $display("[FAIL] FORMAT_NAME %s, want %s", FORMAT_NAME, WANT_NAME);
    end
    expect_eq("FMT_DEFINE_COUNT", int'(FMT_DEFINE_COUNT), WANT_DEFINES);
    expect_eq("DATA_WIDTH", int'(DATA_WIDTH), WANT[0]);
    expect_eq("ACC_DATA_WIDTH", int'(ACC_DATA_WIDTH), WANT[1]);
    expect_eq("RESULT_DATA_WIDTH", int'(RESULT_DATA_WIDTH), WANT[2]);
    expect_eq("BIAS_DATA_WIDTH", int'(BIAS_DATA_WIDTH), WANT[3]);
    expect_eq("ACTIVATION_DATA_WIDTH", int'(ACTIVATION_DATA_WIDTH), WANT[4]);
    expect_eq("MUL_LATENCY", int'(MUL_LATENCY), WANT[5]);
    expect_eq("ADD_LATENCY", int'(ADD_LATENCY), WANT[6]);
    expect_eq("LANE_MUL_LATENCY", int'(LANE_MUL_LATENCY), WANT[7]);
    expect_eq("LANE_ADD_LATENCY", int'(LANE_ADD_LATENCY), WANT[8]);
    expect_eq("REQUANT_LATENCY", int'(REQUANT_LATENCY), WANT[9]);
    expect_eq("QUANT_ADD_LATENCY", int'(QUANT_ADD_LATENCY), WANT[10]);
    expect_eq("DROPOUT_SCALE_LATENCY", int'(DROPOUT_SCALE_LATENCY), WANT[11]);
    expect_eq("HAS_FLOAT_TAIL", int'(HAS_FLOAT_TAIL), WANT[12]);
    expect_eq("HAS_REQUANT_EPILOGUE", int'(HAS_REQUANT_EPILOGUE), WANT[13]);
    expect_eq("HAS_RESIDUAL_ADD", int'(HAS_RESIDUAL_ADD), WANT[14]);
    expect_eq("LOWEST_VALUE", int'(LOWEST_VALUE), WANT_LOWEST);
    expect_eq("ONE_VALUE", int'(ONE_VALUE), WANT_ONE);
    expect_eq("$bits(lane_params_t)", int'($bits(lane_params_t)), WANT_BITS[0]);
    expect_eq("$bits(requant_params_t)", int'($bits(requant_params_t)), WANT_BITS[1]);
    expect_eq("$bits(add_params_t)", int'($bits(add_params_t)), WANT_BITS[2]);
    expect_eq("$bits(lane_entry_t)", int'($bits(lane_entry_t)), WANT_BITS[3]);
    expect_eq("$bits(requant_scale_t)", int'($bits(requant_scale_t)), WANT_BITS[4]);
    expect_eq("DROPOUT_KEEP_SCALE", int'(DROPOUT_KEEP_SCALE), WANT_KEEP);
    expect_eq("EXPONENT_WIDTH", int'(EXPONENT_WIDTH), WANT_LANE[0]);
    expect_eq("MANTISSA_WIDTH", int'(MANTISSA_WIDTH), WANT_LANE[1]);
    expect_eq("HORNER_STEP_LATENCY", int'(HORNER_STEP_LATENCY), WANT_LANE[2]);
    expect_eq("HORNER_COEFFICIENT_LAG", int'(HORNER_COEFFICIENT_LAG), WANT_LANE[3]);
    // the latency functions at each width the wrappers take
    expect_eq("add_latency(ACC_DATA_WIDTH)", int'(add_latency(ACC_DATA_WIDTH)), WANT[6]);
    expect_eq("mul_latency(DATA_WIDTH, ACC_DATA_WIDTH)", int'(mul_latency(DATA_WIDTH, ACC_DATA_WIDTH)), (DATA_WIDTH == 32) ? WANT[7] : WANT[5]);
    expect_eq("mul_latency(DATA_WIDTH, DATA_WIDTH)", int'(mul_latency(DATA_WIDTH, DATA_WIDTH)), WANT[7]);
    if (WANT_NAME == "bf16") expect_eq("add_latency(16)", int'(add_latency(16)), WANT[8]);
    // the package functions on a few hand cases: 2 > 1, -1 > -2, +0 vs -0, ReLU of a negative and of a positive
`ifdef FMT_INT8
    expect_eq("fmt_greater_than(2, 1)", int'(fmt_greater_than(8'd2, 8'd1)), 1);
    expect_eq("fmt_greater_than(-1, -2)", int'(fmt_greater_than(8'hFF, 8'hFE)), 1);
    expect_eq("fmt_greater_than(-128, 127)", int'(fmt_greater_than(8'h80, 8'h7F)), 0);
    expect_eq("fmt_relu(-5, zp 3)", int'(fmt_relu(8'hFB, 8'd3)), 3);
    expect_eq("fmt_relu(9, zp 3)", int'(fmt_relu(8'd9, 8'd3)), 9);
    expect_eq("fmt_drop(9, zp 3)", int'(fmt_drop(8'd9, 8'd3)), 3);
    expect_eq("fmt_drop(-5, zp -128)", int'(fmt_drop(8'hFB, 8'h80)), 'h80);
`elsif FMT_BF16
    expect_eq("fmt_greater_than(2.0, 1.0)", int'(fmt_greater_than(16'h4000, 16'h3F80)), 1);
    expect_eq("fmt_greater_than(-1.0, -2.0)", int'(fmt_greater_than(16'hBF80, 16'hC000)), 1);
    expect_eq("fmt_greater_than(+0, -0)", int'(fmt_greater_than(16'h0000, 16'h8000)), 0);
    expect_eq("fmt_relu(-3.0)", int'(fmt_relu(16'hC040, 16'h0)), 0);
    expect_eq("fmt_relu(3.0)", int'(fmt_relu(16'h4040, 16'h0)), 'h4040);
    expect_eq("fmt_drop(-3.0)", int'(fmt_drop(16'hC040, 16'h0)), 'h8000);
    expect_eq("fmt_drop(3.0)", int'(fmt_drop(16'h4040, 16'h1)), 0);
`else
    expect_eq("fmt_greater_than(2.0, 1.0)", int'(fmt_greater_than(32'h40000000, 32'h3F800000)), 1);
    expect_eq("fmt_greater_than(-1.0, -2.0)", int'(fmt_greater_than(32'hBF800000, 32'hC0000000)), 1);
    expect_eq("fmt_greater_than(+0, -0)", int'(fmt_greater_than(32'h00000000, 32'h80000000)), 0);
    expect_eq("fmt_relu(-3.0)", int'(fmt_relu(32'hC0400000, 32'h0)), 0);
    expect_eq("fmt_relu(3.0)", int'(fmt_relu(32'h40400000, 32'h0)), 'h40400000);
    expect_eq("fmt_drop(-3.0)", int'(fmt_drop(32'hC0400000, 32'h0)), 32'h80000000);
    expect_eq("fmt_drop(3.0)", int'(fmt_drop(32'h40400000, 32'h1)), 0);
`endif
    $display("sienna_fmt_pkg define map %s (%0d defines): %0d checks, %0d errors", FORMAT_NAME, FMT_DEFINE_COUNT, checks, errs);
    $display("RESULT: %s", errs == 0 ? "PASSED" : "FAILED");
    $finish;
  end
endmodule
