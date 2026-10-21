`timescale 1ns / 100ps

// bf16 multiplier: fpMultiplier's algorithm with the format fixed at 8 exponent and 7 mantissa bits, so its words and done cycles
// are fpMultiplier (8, 7)'s. Truncates; subnormal inputs read as zero, underflow flushes to a signed zero, overflow gives infinity, any
// NaN the canonical quiet NaN. valid_i at t, done_o at t+3.
module bf16Multiplier #(
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
    output reg          overflow_o,   // finite inputs, infinite result
    output reg          underflow_o,  // result flushed to zero
    output reg          invalid_o     // 0 * Inf, or a signaling NaN input
);
  localparam int SIGNIFICAND_WIDTH = MANTISSA_WIDTH + 1;
  localparam int PRODUCT_WIDTH = 2 * SIGNIFICAND_WIDTH;
  localparam int EXPONENT_BIAS = (1 << (EXPONENT_WIDTH - 1)) - 1;
  localparam int EXPONENT_INF_CODE = (1 << EXPONENT_WIDTH) - 1;
  localparam int EXPONENT_SUM_WIDTH = EXPONENT_WIDTH + 2;  // exponent sum
  localparam bit USE_KARATSUBA = (SIGNIFICAND_WIDTH > 12);
  localparam int PRODUCT_LATENCY = USE_KARATSUBA ? 6 : 1;  // karatsubaUnsigned: valid_i at t, valid_o at t+6
  localparam logic [EXPONENT_WIDTH-1:0] EXPONENT_ALL_ONES = '1;
  localparam logic [DATA_WIDTH-1:0] CANONICAL_QNAN = {1'b0, EXPONENT_ALL_ONES, 1'b1, {(MANTISSA_WIDTH - 1) {1'b0}}};

  // Integer formats have their own units (int8Multiplier, int32Adder): an int8 build must never fall through to this one.
  if (EXPONENT_WIDTH < 2) begin : G_BAD_FORMAT
    $fatal(1, "bf16Multiplier: EXPONENT_WIDTH=%0d is an integer format, not a float one", EXPONENT_WIDTH);
  end

  typedef struct packed {
    logic          nan;
    logic          invalid;
    logic          inf;
    logic          zero;
    logic          sign;
    logic [EXPONENT_SUM_WIDTH-1:0] exponent_sum;
  } operation_class_t;

  // Stage 1: classify, add the exponents, register the significands.
  logic s1_valid;
  operation_class_t s1_class;
  logic [SIGNIFICAND_WIDTH-1:0] s1_significand_a, s1_significand_b;

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      s1_valid  <= 1'b0;
      s1_class  <= '0;
      s1_significand_a <= '0;
      s1_significand_b <= '0;
    end else begin
      s1_valid <= valid_i;
      if (valid_i) begin
        automatic logic [EXPONENT_WIDTH-1:0] exponent_a = a_i[DATA_WIDTH-2:MANTISSA_WIDTH], exponent_b = b_i[DATA_WIDTH-2:MANTISSA_WIDTH];
        automatic logic zero_a = (exponent_a == '0), zero_b = (exponent_b == '0);
        automatic logic inf_a = (exponent_a == EXPONENT_ALL_ONES) && (a_i[MANTISSA_WIDTH-1:0] == '0), inf_b = (exponent_b == EXPONENT_ALL_ONES) && (b_i[MANTISSA_WIDTH-1:0] == '0);
        automatic logic nan_a = (exponent_a == EXPONENT_ALL_ONES) && (a_i[MANTISSA_WIDTH-1:0] != '0), nan_b = (exponent_b == EXPONENT_ALL_ONES) && (b_i[MANTISSA_WIDTH-1:0] != '0);
        automatic logic signaling_nan_in = (nan_a && !a_i[MANTISSA_WIDTH-1]) || (nan_b && !b_i[MANTISSA_WIDTH-1]);
        automatic logic invalid = (zero_a && inf_b) || (inf_a && zero_b);
        s1_class.nan  <= nan_a || nan_b || invalid;
        s1_class.invalid  <= invalid || signaling_nan_in;
        s1_class.inf  <= inf_a || inf_b;
        s1_class.zero <= zero_a || zero_b;
        s1_class.sign <= a_i[DATA_WIDTH-1] ^ b_i[DATA_WIDTH-1];
        s1_class.exponent_sum  <= EXPONENT_SUM_WIDTH'(exponent_a) + EXPONENT_SUM_WIDTH'(exponent_b);
        s1_significand_a     <= {1'b1, a_i[MANTISSA_WIDTH-1:0]};
        s1_significand_b     <= {1'b1, b_i[MANTISSA_WIDTH-1:0]};
      end
    end
  end

  // Significand product: Karatsuba for wide significands, one registered multiply for narrow ones.
  logic          product_valid;
  logic [PRODUCT_WIDTH-1:0] significand_product;
  if (USE_KARATSUBA) begin : G_KARATSUBA
    karatsubaUnsigned #(
        .WIDTH(SIGNIFICAND_WIDTH)
    ) significand_multiplier (
        .clk_i         (clk_i),
        .rstn_i        (rstn_i),
        .valid_i       (s1_valid),
        .multiplicand_i(s1_significand_a),
        .multiplier_i  (s1_significand_b),
        .valid_o       (product_valid),
        .product_o     (significand_product)
    );
  end else begin : G_DIRECT
    always_ff @(posedge clk_i or negedge rstn_i) begin
      if (!rstn_i) begin
        product_valid <= 1'b0;
        significand_product   <= '0;
      end else begin
        product_valid <= s1_valid;
        if (s1_valid) significand_product <= PRODUCT_WIDTH'(s1_significand_a) * PRODUCT_WIDTH'(s1_significand_b);
      end
    end
  end

  // The classification travels beside the product.
  operation_class_t class_delay[PRODUCT_LATENCY];
  always_ff @(posedge clk_i) begin
    class_delay[0] <= s1_class;
    for (int i = 1; i < PRODUCT_LATENCY; i++) class_delay[i] <= class_delay[i-1];
  end
  operation_class_t class_at_product;
  assign class_at_product = class_delay[PRODUCT_LATENCY-1];

  // Range from the exponent sum, as fp32Multiplier's bias stage; normalize a product in [2, 4) by one place.
  logic product_ge_two, exponent_overflow, exponent_underflow;
  logic [EXPONENT_WIDTH-1:0] result_exponent;
  logic [MANTISSA_WIDTH-1:0] result_mantissa;
  always_comb begin
    product_ge_two    = significand_product[PRODUCT_WIDTH-1];
    exponent_overflow = (class_at_product.exponent_sum >= EXPONENT_SUM_WIDTH'(EXPONENT_INF_CODE + EXPONENT_BIAS));
    exponent_underflow  = (class_at_product.exponent_sum < EXPONENT_SUM_WIDTH'(EXPONENT_BIAS)) || ((class_at_product.exponent_sum == EXPONENT_SUM_WIDTH'(EXPONENT_BIAS)) && !product_ge_two);
    result_exponent   = EXPONENT_WIDTH'(class_at_product.exponent_sum - EXPONENT_SUM_WIDTH'(EXPONENT_BIAS)) + EXPONENT_WIDTH'(product_ge_two);
    result_mantissa   = product_ge_two ? significand_product[PRODUCT_WIDTH-2-:MANTISSA_WIDTH] : significand_product[PRODUCT_WIDTH-3-:MANTISSA_WIDTH];
  end

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      result_o    <= '0;
      done_o      <= 1'b0;
      overflow_o  <= 1'b0;
      underflow_o <= 1'b0;
      invalid_o   <= 1'b0;
    end else begin
      done_o      <= product_valid;
      overflow_o  <= 1'b0;
      underflow_o <= 1'b0;
      invalid_o   <= 1'b0;
      if (product_valid) begin
        invalid_o <= class_at_product.invalid;
        if (class_at_product.nan) result_o <= CANONICAL_QNAN;
        else if (class_at_product.inf) result_o <= {class_at_product.sign, EXPONENT_ALL_ONES, {MANTISSA_WIDTH{1'b0}}};
        else if (class_at_product.zero) result_o <= {class_at_product.sign, {(DATA_WIDTH - 1) {1'b0}}};
        else if (exponent_overflow) begin
          result_o   <= {class_at_product.sign, EXPONENT_ALL_ONES, {MANTISSA_WIDTH{1'b0}}};
          overflow_o <= 1'b1;
        end else if (exponent_underflow) begin
          result_o    <= {class_at_product.sign, {(DATA_WIDTH - 1) {1'b0}}};
          underflow_o <= 1'b1;
        end else if (result_exponent == EXPONENT_ALL_ONES) begin
          result_o   <= {class_at_product.sign, EXPONENT_ALL_ONES, {MANTISSA_WIDTH{1'b0}}};
          overflow_o <= 1'b1;
        end else result_o <= {class_at_product.sign, result_exponent, result_mantissa};
      end
    end
  end

endmodule
