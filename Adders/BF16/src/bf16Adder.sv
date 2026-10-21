`timescale 1ns / 100ps

// bf16 adder: fpAdder's algorithm with the format fixed at 8 exponent and 7 mantissa bits, so its words and done cycles are
// fpAdder (8, 7)'s. Aligns with three extra low bits, normalizes by leading zeros, truncates; subnormal inputs read as zero, underflow
// flushes to a signed zero, NaN is the canonical quiet NaN. valid_i at t, done_o at t+5.
module bf16Adder #(
    localparam int EXPONENT_WIDTH = 8,
    localparam int MANTISSA_WIDTH = 7,
    localparam int DATA_WIDTH = 16
) (
    input  wire         clk_i,
    input  wire         rstn_i,
    input  wire         valid_i,
    input  wire [DATA_WIDTH-1:0] a_i,
    input  wire [DATA_WIDTH-1:0] b_i,
    output reg  [DATA_WIDTH-1:0] result_o,
    output reg          done_o,
    output reg          overflow_o,
    output reg          underflow_o,
    output reg          invalid_o
);
  localparam int SIGNIFICAND_WIDTH = MANTISSA_WIDTH + 1;
  localparam int ALIGNED_WIDTH = SIGNIFICAND_WIDTH + 3;  // aligned significand with three extra low bits
  localparam int SUM_WIDTH = ALIGNED_WIDTH + 1;  // sum with its carry
  localparam int LEADING_ZERO_COUNT_WIDTH = $clog2(SUM_WIDTH + 1);
  localparam int NORMALIZED_EXPONENT_WIDTH = EXPONENT_WIDTH + 1;  // normalized exponent with a sign bit
  localparam int EXPONENT_INF_CODE = (1 << EXPONENT_WIDTH) - 1;
  localparam logic [EXPONENT_WIDTH-1:0] EXPONENT_ALL_ONES = '1;
  localparam logic [DATA_WIDTH-1:0] CANONICAL_QNAN = {1'b0, EXPONENT_ALL_ONES, 1'b1, {(MANTISSA_WIDTH - 1) {1'b0}}};

  // Integer formats have their own units (int8Multiplier, int32Adder): an int8 build must never fall through to this one.
  if (EXPONENT_WIDTH < 2) begin : G_BAD_FORMAT
    $fatal(1, "bf16Adder: EXPONENT_WIDTH=%0d is an integer format, not a float one", EXPONENT_WIDTH);
  end

  typedef struct packed {
    logic             invalid;
    logic             nan;
    logic             inf;
    logic             zero;
    logic             bypass;  // exactly one operand is zero: the other passes through
    logic             sign;
    logic [EXPONENT_WIDTH-1:0] big_exponent;
    logic             is_subtract;
  } operation_class_t;

  // Leading zeros of the sum; SUM_WIDTH when it is zero.
  function automatic logic [LEADING_ZERO_COUNT_WIDTH-1:0] leading_zero_count(input logic [SUM_WIDTH-1:0] x);
    leading_zero_count = LEADING_ZERO_COUNT_WIDTH'(SUM_WIDTH);
    for (int i = 0; i < SUM_WIDTH; i++) if (x[i]) leading_zero_count = LEADING_ZERO_COUNT_WIDTH'(SUM_WIDTH - 1 - i);
  endfunction

  // Stage 1: unpack, classify, order the operands by magnitude.
  logic s1_valid;
  logic [EXPONENT_WIDTH-1:0] s1_exponent_diff;
  logic [SIGNIFICAND_WIDTH-1:0] s1_big_significand, s1_small_significand;
  operation_class_t s1_class;

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      s1_valid     <= 1'b0;
      s1_exponent_diff  <= '0;
      s1_big_significand   <= '0;
      s1_small_significand <= '0;
      s1_class     <= '0;
    end else begin
      s1_valid <= valid_i;
      if (valid_i) begin
        automatic logic [EXPONENT_WIDTH-1:0] exponent_a = a_i[DATA_WIDTH-2:MANTISSA_WIDTH], exponent_b = b_i[DATA_WIDTH-2:MANTISSA_WIDTH];
        automatic logic zero_a = (exponent_a == '0), zero_b = (exponent_b == '0);
        automatic logic [MANTISSA_WIDTH-1:0] mantissa_a = zero_a ? '0 : a_i[MANTISSA_WIDTH-1:0], mantissa_b = zero_b ? '0 : b_i[MANTISSA_WIDTH-1:0];
        automatic logic inf_a = (exponent_a == EXPONENT_ALL_ONES) && (a_i[MANTISSA_WIDTH-1:0] == '0), inf_b = (exponent_b == EXPONENT_ALL_ONES) && (b_i[MANTISSA_WIDTH-1:0] == '0);
        automatic logic nan_a = (exponent_a == EXPONENT_ALL_ONES) && (a_i[MANTISSA_WIDTH-1:0] != '0), nan_b = (exponent_b == EXPONENT_ALL_ONES) && (b_i[MANTISSA_WIDTH-1:0] != '0);
        automatic logic signaling_nan_in = (nan_a && !a_i[MANTISSA_WIDTH-1]) || (nan_b && !b_i[MANTISSA_WIDTH-1]);
        automatic logic inf_minus_inf = inf_a && inf_b && (a_i[DATA_WIDTH-1] != b_i[DATA_WIDTH-1]);
        automatic logic a_magnitude_ge_b = {exponent_a, mantissa_a} >= {exponent_b, mantissa_b};
        s1_class.invalid    <= inf_minus_inf || signaling_nan_in;
        s1_class.nan    <= nan_a || nan_b || inf_minus_inf;
        s1_class.inf    <= inf_a || inf_b;
        s1_class.zero   <= zero_a && zero_b;
        s1_class.bypass <= zero_a ^ zero_b;
        s1_class.is_subtract    <= a_i[DATA_WIDTH-1] ^ b_i[DATA_WIDTH-1];
        s1_class.big_exponent    <= a_magnitude_ge_b ? exponent_a : exponent_b;
        s1_class.sign   <= a_magnitude_ge_b ? a_i[DATA_WIDTH-1] : b_i[DATA_WIDTH-1];
        s1_big_significand      <= a_magnitude_ge_b ? {!zero_a, mantissa_a} : {!zero_b, mantissa_b};
        s1_small_significand    <= a_magnitude_ge_b ? {!zero_b, mantissa_b} : {!zero_a, mantissa_a};
        s1_exponent_diff     <= a_magnitude_ge_b ? exponent_a - exponent_b : exponent_b - exponent_a;
      end
    end
  end

  // Stage 2: align the smaller significand.
  logic s2_valid;
  logic [ALIGNED_WIDTH-1:0] s2_big_significand, s2_small_significand;
  operation_class_t s2_class;
  always_ff @(posedge clk_i or negedge rstn_i)
    if (!rstn_i) s2_valid <= 1'b0;
    else s2_valid <= s1_valid;
  always_ff @(posedge clk_i)
    if (s1_valid) begin
      s2_class   <= s1_class;
      s2_big_significand <= {s1_big_significand, 3'b000};
      if (s1_class.bypass) s2_small_significand <= '0;
      else if (s1_exponent_diff >= EXPONENT_WIDTH'(SIGNIFICAND_WIDTH + 2)) s2_small_significand <= ALIGNED_WIDTH'(1);
      else s2_small_significand <= {s1_small_significand, 3'b000} >> s1_exponent_diff;
    end

  // Stage 3: add or subtract.
  logic s3_valid;
  logic [SUM_WIDTH-1:0] s3_sum;
  operation_class_t s3_class;
  always_ff @(posedge clk_i or negedge rstn_i)
    if (!rstn_i) s3_valid <= 1'b0;
    else s3_valid <= s2_valid;
  always_ff @(posedge clk_i)
    if (s2_valid) begin
      s3_class   <= s2_class;
      s3_sum <= s2_class.is_subtract ? {1'b0, s2_big_significand} - {1'b0, s2_small_significand} : {1'b0, s2_big_significand} + {1'b0, s2_small_significand};
    end

  // Stage 4: count leading zeros.
  logic s4_valid;
  logic [SUM_WIDTH-1:0] s4_sum;
  logic [LEADING_ZERO_COUNT_WIDTH-1:0] s4_leading_zeros;
  /* verilator lint_off UNUSEDSIGNAL */  // s4_class's last field (sub) is spent by stage 4; as fpAdder
  operation_class_t s4_class;
  /* verilator lint_on UNUSEDSIGNAL */
  always_ff @(posedge clk_i or negedge rstn_i)
    if (!rstn_i) s4_valid <= 1'b0;
    else s4_valid <= s3_valid;
  always_ff @(posedge clk_i)
    if (s3_valid) begin
      s4_sum <= s3_sum;
      s4_class   <= s3_class;
      s4_leading_zeros  <= leading_zero_count(s3_sum);
      if (s3_sum == '0) s4_class.zero <= 1'b1;
    end

  // Normalize, in fp32Adder's order of cases.
  /* verilator lint_off UNUSEDSIGNAL */  // the carry, hidden-bit and three guard bits of normalized_mantissa are dropped by truncation; as fpAdder
  logic [SUM_WIDTH-1:0] normalized_mantissa;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [NORMALIZED_EXPONENT_WIDTH-1:0] normalized_exponent;
  always_comb begin
    normalized_mantissa = s4_sum;
    normalized_exponent = NORMALIZED_EXPONENT_WIDTH'(s4_class.big_exponent);
    if (!s4_class.bypass) begin
      if (s4_sum[SUM_WIDTH-1]) begin
        normalized_mantissa = s4_sum >> 1;
        normalized_exponent = NORMALIZED_EXPONENT_WIDTH'(s4_class.big_exponent) + NORMALIZED_EXPONENT_WIDTH'(1);
      end else if (s4_leading_zeros == LEADING_ZERO_COUNT_WIDTH'(1)) normalized_mantissa = s4_sum;
      else if (s4_class.zero) begin
        normalized_mantissa = '0;
        normalized_exponent = '0;
      end else if (s4_leading_zeros > LEADING_ZERO_COUNT_WIDTH'(1)) begin
        normalized_mantissa = s4_sum << (s4_leading_zeros - LEADING_ZERO_COUNT_WIDTH'(1));
        normalized_exponent = NORMALIZED_EXPONENT_WIDTH'(s4_class.big_exponent) - NORMALIZED_EXPONENT_WIDTH'(s4_leading_zeros - LEADING_ZERO_COUNT_WIDTH'(1));
      end
    end
  end

  logic normalized_exponent_negative, normalized_exponent_nonpositive;
  assign normalized_exponent_negative    = normalized_exponent[NORMALIZED_EXPONENT_WIDTH-1];
  assign normalized_exponent_nonpositive = normalized_exponent_negative || (normalized_exponent == '0);

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      result_o    <= '0;
      done_o      <= 1'b0;
      overflow_o  <= 1'b0;
      underflow_o <= 1'b0;
      invalid_o   <= 1'b0;
    end else begin
      done_o      <= s4_valid;
      overflow_o  <= 1'b0;
      underflow_o <= 1'b0;
      invalid_o   <= 1'b0;
      if (s4_valid) begin
        invalid_o  <= s4_class.invalid;
        overflow_o <= !normalized_exponent_negative && (normalized_exponent >= NORMALIZED_EXPONENT_WIDTH'(EXPONENT_INF_CODE)) && !s4_class.inf && !s4_class.nan;
        if (s4_class.nan) result_o <= CANONICAL_QNAN;
        else if (s4_class.inf) result_o <= {s4_class.sign, EXPONENT_ALL_ONES, {MANTISSA_WIDTH{1'b0}}};
        else if (s4_class.zero) result_o <= {s4_class.sign, {(DATA_WIDTH - 1) {1'b0}}};
        else if (normalized_exponent_nonpositive && !s4_class.bypass) begin
          result_o    <= {s4_class.sign, {(DATA_WIDTH - 1) {1'b0}}};
          underflow_o <= 1'b1;
        end else if (normalized_exponent >= NORMALIZED_EXPONENT_WIDTH'(EXPONENT_INF_CODE)) result_o <= {s4_class.sign, EXPONENT_ALL_ONES, {MANTISSA_WIDTH{1'b0}}};
        else result_o <= {s4_class.sign, normalized_exponent[EXPONENT_WIDTH-1:0], normalized_mantissa[ALIGNED_WIDTH-2-:MANTISSA_WIDTH]};
      end
    end
  end

endmodule
