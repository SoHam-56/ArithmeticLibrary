`timescale 1ns / 100ps

// Number formats a SIENNA build may use: the constants and steps of the one format +define+FMT_<F> selects.
package sienna_fmt_pkg;

  // ── define map: the precision constants one of +define+FMT_FP32, FMT_BF16 or FMT_INT8 sets (fp32 with none) ──
  /* verilator lint_save */
  /* verilator lint_off UNUSEDPARAM */  // a package of constants: no single top reads every one

  // Two precision defines at once stop the preprocessor at an undefined macro named for the pair.
`ifdef FMT_INT8
`ifdef FMT_BF16
`SIENNA_FMT_ERROR_FMT_INT8_AND_FMT_BF16_BOTH_DEFINED
`endif
`ifdef FMT_FP32
`SIENNA_FMT_ERROR_FMT_INT8_AND_FMT_FP32_BOTH_DEFINED
`endif
`elsif FMT_BF16
`ifdef FMT_FP32
`SIENNA_FMT_ERROR_FMT_BF16_AND_FMT_FP32_BOTH_DEFINED
`endif
`endif

  // How many precision defines are set; every Fmt wrapper repeats the check at elaboration.
  localparam int FMT_DEFINE_COUNT = 0
`ifdef FMT_FP32
      + 1
`endif
`ifdef FMT_BF16
      + 1
`endif
`ifdef FMT_INT8
      + 1
`endif
      ;

`ifdef FMT_INT8
  localparam string FORMAT_NAME = "int8";  // for logs only: control never keys on it
  localparam int EXPONENT_WIDTH = 0;  // math modules only
  localparam int MANTISSA_WIDTH = 7;
  localparam int DATA_WIDTH = 8;
  localparam int ACC_DATA_WIDTH = 32;  // int32 accumulator
  localparam int RESULT_DATA_WIDTH = 32;  // mesh result word: int32, requantized at the lane feed
  localparam int BIAS_DATA_WIDTH = 32;  // int32 bias
  localparam int ACTIVATION_DATA_WIDTH = 16;  // lane arithmetic in Q4.11
  localparam int MUL_LATENCY = 1;  // mesh product: int8Multiplier
  localparam int ADD_LATENCY = 1;  // fmt_add: int32Adder
  localparam int LANE_MUL_LATENCY = 1;  // lane multiply: GPNAE's int16Multiplier and int24Multiplier
  localparam int LANE_ADD_LATENCY = 0;  // no lane add in int8: fmt_add is int32Adder only
  localparam int ACT_IN_LATENCY = 5;  // gpnae_act_in: LANE_MUL_LATENCY + 4: the rescale product, then round, saturate, classify, base
  localparam int HORNER_STEP_LATENCY = 3;  // one register, then GPNAE's fixedPointMultiplyAdd, 2 cycles
  localparam int HORNER_COEFFICIENT_LAG = 1;  // c_i is sampled one cycle after valid_i
  localparam int REQUANT_LATENCY = 5;  // int8Requantizer: the product over two stages
  localparam int QUANT_ADD_LATENCY = 6;  // int8QuantizedAdder
  localparam int DROPOUT_SCALE_LATENCY = 0;  // dropout keeps x: the 1/keep factor is in the next layer's scale
  localparam logic [DATA_WIDTH-1:0] LOWEST_VALUE = 8'h80;  // -128
  localparam logic [DATA_WIDTH-1:0] ONE_VALUE = 8'h01;
  localparam bit HAS_FLOAT_TAIL = 1'b0;
  localparam bit HAS_REQUANT_EPILOGUE = 1'b1;
  localparam bit HAS_RESIDUAL_ADD = 1'b1;
  // Per-set lane words, as gpnae_poly's gp_* ports: the input rescale, then SELU's output requantize.
  typedef struct packed {
    logic [15:0] in_rescale_mantissa;    // input rescale mantissa, below 2^15
    logic [4:0]  in_rescale_shift;       // input rescale right shift
    logic [7:0]  in_zero_point;          // input zero point
    logic [23:0] selu_out_mantissa;      // SELU output scale's mantissa
    logic [5:0]  selu_out_shift;         // SELU output scale's right shift
    logic [7:0]  selu_out_zero_point;    // SELU output zero point
  } lane_params_t;
  // int8Requantizer's words per output channel: the scale as mantissa * 2^-shift, the zero point and the clamp.
  typedef struct packed {
    logic [23:0] mantissa;
    logic [5:0]  shift;
    logic [7:0]  zero_point;
    logic [7:0]  act_min;
    logic [7:0]  act_max;
  } requant_params_t;
  // int8QuantizedAdder's words, in sienna_add_pkg's add_words_t order: s1 / s_out and s2 / s_out as mantissas on one shared shift.
  typedef struct packed {
    logic [7:0]  in1_zero_point;
    logic [7:0]  in2_zero_point;
    logic [31:0] in1_mantissa;
    logic [31:0] in2_mantissa;
    logic [5:0]  shift;
    logic [7:0]  out_zero_point;
    logic [7:0]  act_min;
    logic [7:0]  act_max;
  } add_params_t;
  // One pack entry's words in SIENNA's sideband and layer configuration: the requantize output zero point and clamp, then the lane's
  // input rescale and SELU output requantize (the lane's input zero point is zero_point, or the ADD's out_zero_point after an ADD).
  typedef struct packed {
    logic [7:0]  zero_point;
    logic [7:0]  act_min;
    logic [7:0]  act_max;
    logic [15:0] in_rescale_mantissa;
    logic [4:0]  in_rescale_shift;
    logic [23:0] selu_out_mantissa;
    logic [5:0]  selu_out_shift;
    logic [7:0]  selu_out_zero_point;
  } lane_entry_t;
  // One output channel's requantize scale, mantissa * 2^-shift (int8Requantizer's mult_i and shift_i).
  typedef struct packed {
    logic [23:0] mantissa;
    logic [5:0]  shift;
  } requant_scale_t;
  localparam logic [DATA_WIDTH-1:0] DROPOUT_KEEP_SCALE = 8'h01;  // unused: int8 keeps x (DROPOUT_SCALE_LATENCY 0)

`elsif FMT_BF16
  localparam string FORMAT_NAME = "bf16";
  localparam int EXPONENT_WIDTH = 8;
  localparam int MANTISSA_WIDTH = 7;
  localparam int DATA_WIDTH = 16;
  localparam int ACC_DATA_WIDTH = 32;  // fp32 accumulator
  localparam int RESULT_DATA_WIDTH = 16;  // narrowed in the mesh reducer
  localparam int BIAS_DATA_WIDTH = 16;
  localparam int ACTIVATION_DATA_WIDTH = 16;
  localparam int MUL_LATENCY = 3;  // bf16WideMultiplier
  localparam int ADD_LATENCY = 5;  // fp32Adder
  localparam int LANE_MUL_LATENCY = 3;  // bf16Multiplier
  localparam int LANE_ADD_LATENCY = 5;  // bf16Adder
  localparam int ACT_IN_LATENCY = 4;  // gpnae_act_in: LANE_MUL_LATENCY + 1, the class rides beside the operand multiply
  localparam int HORNER_STEP_LATENCY = 8;  // LANE_MUL_LATENCY + LANE_ADD_LATENCY
  localparam int HORNER_COEFFICIENT_LAG = 3;  // the add issues as the product lands
  localparam int REQUANT_LATENCY = 0;
  localparam int QUANT_ADD_LATENCY = 0;
  localparam int DROPOUT_SCALE_LATENCY = 3;  // x * 2.0 on bf16Multiplier
  localparam logic [DATA_WIDTH-1:0] LOWEST_VALUE = 16'hFF80;  // -Inf
  localparam logic [DATA_WIDTH-1:0] ONE_VALUE = 16'h3F80;
  localparam bit HAS_FLOAT_TAIL = 1'b1;  // GPNAE's negative sigmoid past its Q set runs in fp32 on the tail
  localparam bit HAS_REQUANT_EPILOGUE = 1'b0;
  localparam bit HAS_RESIDUAL_ADD = 1'b0;
  typedef logic lane_params_t;  // 1-bit dummies in floats
  typedef logic requant_params_t;
  typedef logic add_params_t;
  typedef logic lane_entry_t;
  typedef logic requant_scale_t;
  localparam logic [DATA_WIDTH-1:0] DROPOUT_KEEP_SCALE = 16'h4000;  // 2.0: a kept word is x * 2, 1/(1 - p) at p = 50%

`else  // fp32: FMT_FP32 or no define
  localparam string FORMAT_NAME = "fp32";
  localparam int EXPONENT_WIDTH = 8;
  localparam int MANTISSA_WIDTH = 23;
  localparam int DATA_WIDTH = 32;
  localparam int ACC_DATA_WIDTH = 32;
  localparam int RESULT_DATA_WIDTH = 32;
  localparam int BIAS_DATA_WIDTH = 32;
  localparam int ACTIVATION_DATA_WIDTH = 32;
  localparam int MUL_LATENCY = 8;  // fp32Multiplier: Karatsuba product
  localparam int ADD_LATENCY = 5;
  localparam int LANE_MUL_LATENCY = 8;
  localparam int LANE_ADD_LATENCY = 5;
  localparam int ACT_IN_LATENCY = 9;  // gpnae_act_in: LANE_MUL_LATENCY + 1, the class rides beside the operand multiply
  localparam int HORNER_STEP_LATENCY = 13;
  localparam int HORNER_COEFFICIENT_LAG = 8;
  localparam int REQUANT_LATENCY = 0;
  localparam int QUANT_ADD_LATENCY = 0;
  localparam int DROPOUT_SCALE_LATENCY = 8;
  localparam logic [DATA_WIDTH-1:0] LOWEST_VALUE = 32'hFF800000;
  localparam logic [DATA_WIDTH-1:0] ONE_VALUE = 32'h3F800000;
  localparam bit HAS_FLOAT_TAIL = 1'b0;  // GPNAE's negative sigmoid runs on the barrel MAC: no tail
  localparam bit HAS_REQUANT_EPILOGUE = 1'b0;
  localparam bit HAS_RESIDUAL_ADD = 1'b0;
  typedef logic lane_params_t;
  typedef logic requant_params_t;
  typedef logic add_params_t;
  typedef logic lane_entry_t;
  typedef logic requant_scale_t;
  localparam logic [DATA_WIDTH-1:0] DROPOUT_KEEP_SCALE = 32'h40000000;  // 2.0
`endif

  // fmt_add's latency at data_width: the accumulator add (ACC_DATA_WIDTH) takes ADD_LATENCY, the float lane add LANE_ADD_LATENCY.
  function automatic int add_latency(input int data_width);
    return (data_width == ACC_DATA_WIDTH) ? ADD_LATENCY : LANE_ADD_LATENCY;
  endfunction

  // fmt_mul's latency from data_width into ext_data_width bits: the mesh product (into ACC_DATA_WIDTH) takes MUL_LATENCY, a lane product LANE_MUL_LATENCY.
  function automatic int mul_latency(input int data_width, input int ext_data_width);
    return (ext_data_width == ACC_DATA_WIDTH && data_width != ACC_DATA_WIDTH) ? MUL_LATENCY : LANE_MUL_LATENCY;
  endfunction

  // a > b, the compare Maxpool_2D keeps: floats sign-magnitude with +0 equal to -0; int8 signed codes.
  function automatic logic fmt_greater_than(input logic [DATA_WIDTH-1:0] a, input logic [DATA_WIDTH-1:0] b);
`ifdef FMT_INT8
    return $signed(a) > $signed(b);
`else
    if ((a[DATA_WIDTH-2:0] == '0) && (b[DATA_WIDTH-2:0] == '0)) return 1'b0;
    if (a[DATA_WIDTH-1] != b[DATA_WIDTH-1]) return !a[DATA_WIDTH-1];
    if (!a[DATA_WIDTH-1]) return a[DATA_WIDTH-2:0] > b[DATA_WIDTH-2:0];
    return a[DATA_WIDTH-2:0] < b[DATA_WIDTH-2:0];
`endif
  endfunction

  // ReLU: floats +0 when the sign bit is set; int8 max(q, zp) on signed codes, zp the code of 0.0 (floats leave zp unused).
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [DATA_WIDTH-1:0] fmt_relu(input logic [DATA_WIDTH-1:0] x, input logic [DATA_WIDTH-1:0] zero_point);
`ifdef FMT_INT8
    return ($signed(x) < $signed(zero_point)) ? zero_point : x;
`else
    return x[DATA_WIDTH-1] ? '0 : x;
`endif
  endfunction

  // Dropout's dropped word: floats a zero with x's sign, as x * 0 gives; int8 the output zero point, the code of 0.0.
  function automatic logic [DATA_WIDTH-1:0] fmt_drop(input logic [DATA_WIDTH-1:0] x, input logic [DATA_WIDTH-1:0] zero_point);
`ifdef FMT_INT8
    return zero_point;
`else
    return {x[DATA_WIDTH-1], {(DATA_WIDTH - 1) {1'b0}}};
`endif
  endfunction
  /* verilator lint_restore */

endpackage
