`timescale 1ns / 100ps

// bf16 x bf16 -> fp32, the exact product: fpMulWiden's algorithm with the format fixed at 8 exponent and 7 mantissa bits.
// Subnormal inputs read as zero, underflow flushes to a signed zero, overflow gives infinity, any NaN gives 7FC00000.
// valid_i at t, done_o at t+3. Only the valid chain is reset (D-8); the flags are zero in every cycle without done_o.
module bf16WideMultiplier #(
    localparam int EXPONENT_WIDTH = 8,
    localparam int MANTISSA_WIDTH = 7,
    localparam int DATA_WIDTH = 16
) (
    input wire         clk_i,
    input wire         rstn_i,
    input wire         valid_i,
    input wire [DATA_WIDTH-1:0] a_i,
    input wire [DATA_WIDTH-1:0] b_i,

    output reg [31:0] result_o,
    output reg        done_o,

    output reg overflow_o,   // finite inputs, infinite result
    output reg underflow_o,  // result flushed to zero
    output reg invalid_o     // 0 * Inf, or a signaling NaN input
);
  localparam int SIGNIFICAND_WIDTH = MANTISSA_WIDTH + 1;
  localparam int PRODUCT_WIDTH = 2 * SIGNIFICAND_WIDTH;  // significand product width
  localparam int EXPONENT_BIAS = (1 << (EXPONENT_WIDTH - 1)) - 1;
  localparam logic [EXPONENT_WIDTH-1:0] EXPONENT_ALL_ONES = '1;

`ifndef SYNTHESIS  // parameter checks; synthesis tools ignore or reject initial blocks
  initial if (PRODUCT_WIDTH > 22 || EXPONENT_WIDTH > 8) $error("bf16WideMultiplier: EXPONENT_WIDTH=%0d MANTISSA_WIDTH=%0d does not fit an exact fp32 product", EXPONENT_WIDTH, MANTISSA_WIDTH);
`endif

  // ── Stage 1: classify the inputs and add the exponents, rebased to fp32's bias ──
  logic s1_valid, s1_sign, s1_nan, s1_inf, s1_zero, s1_invalid;
  logic signed [11:0] s1_exp;  // fp32-biased exponent of the product before normalization
  logic [SIGNIFICAND_WIDTH-1:0] s1_significand_a, s1_significand_b;

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) s1_valid <= 1'b0;
    else s1_valid <= valid_i;
  end

  always_ff @(posedge clk_i) begin
    if (valid_i) begin
      automatic logic [EXPONENT_WIDTH-1:0] exponent_a = a_i[DATA_WIDTH-2:MANTISSA_WIDTH], exponent_b = b_i[DATA_WIDTH-2:MANTISSA_WIDTH];
      automatic logic zero_a = (exponent_a == '0), zero_b = (exponent_b == '0);
      automatic logic inf_a = (exponent_a == EXPONENT_ALL_ONES) && (a_i[MANTISSA_WIDTH-1:0] == '0), inf_b = (exponent_b == EXPONENT_ALL_ONES) && (b_i[MANTISSA_WIDTH-1:0] == '0);
      automatic logic nan_a = (exponent_a == EXPONENT_ALL_ONES) && (a_i[MANTISSA_WIDTH-1:0] != '0), nan_b = (exponent_b == EXPONENT_ALL_ONES) && (b_i[MANTISSA_WIDTH-1:0] != '0);
      automatic logic signaling_nan_in = (nan_a && !a_i[MANTISSA_WIDTH-1]) || (nan_b && !b_i[MANTISSA_WIDTH-1]);
      automatic logic invalid = (zero_a && inf_b) || (inf_a && zero_b);
      s1_sign    <= a_i[DATA_WIDTH-1] ^ b_i[DATA_WIDTH-1];
      s1_nan     <= nan_a || nan_b || invalid;
      s1_invalid <= invalid || signaling_nan_in;
      s1_inf     <= inf_a || inf_b;
      s1_zero    <= zero_a || zero_b;
      s1_exp     <= $signed({4'b0, exponent_a}) + $signed({4'b0, exponent_b}) - 12'(2 * EXPONENT_BIAS) + 12'sd127;
      s1_significand_a      <= {1'b1, a_i[MANTISSA_WIDTH-1:0]};
      s1_significand_b      <= {1'b1, b_i[MANTISSA_WIDTH-1:0]};
    end
  end

  // ── Stage 2: significand product ──
  logic s2_valid, s2_sign, s2_nan, s2_inf, s2_zero, s2_invalid;
  logic signed [11:0] s2_exp;
  logic [PRODUCT_WIDTH-1:0] s2_significand_product;

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) s2_valid <= 1'b0;
    else s2_valid <= s1_valid;
  end

  always_ff @(posedge clk_i) begin
    if (s1_valid) begin
      {s2_sign, s2_nan, s2_inf, s2_zero, s2_invalid} <= {s1_sign, s1_nan, s1_inf, s1_zero, s1_invalid};
      s2_exp <= s1_exp;
      s2_significand_product   <= PRODUCT_WIDTH'(s1_significand_a) * PRODUCT_WIDTH'(s1_significand_b);
    end
  end

  // ── Stage 3: normalize (product in [1, 4)), place in fp32, handle range ──
  logic signed [11:0] normalized_exponent;
  logic [22:0] normalized_mantissa;
  always_comb begin
    normalized_exponent = s2_exp + (s2_significand_product[PRODUCT_WIDTH-1] ? 12'sd1 : 12'sd0);
    normalized_mantissa = s2_significand_product[PRODUCT_WIDTH-1] ? 23'({s2_significand_product[PRODUCT_WIDTH-2:0], {(24 - PRODUCT_WIDTH){1'b0}}}) : 23'({s2_significand_product[PRODUCT_WIDTH-3:0], {(25 - PRODUCT_WIDTH){1'b0}}});
  end

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) done_o <= 1'b0;
    else done_o <= s2_valid;
  end

  always_ff @(posedge clk_i) begin
    overflow_o  <= 1'b0;
    underflow_o <= 1'b0;
    invalid_o   <= 1'b0;
    if (s2_valid) begin
      invalid_o <= s2_invalid;
      if (s2_nan) result_o <= 32'h7FC00000;
      else if (s2_inf) result_o <= {s2_sign, 8'hFF, 23'd0};
      else if (s2_zero) result_o <= {s2_sign, 31'd0};
      else if (normalized_exponent >= 12'sd255) begin
        result_o   <= {s2_sign, 8'hFF, 23'd0};
        overflow_o <= 1'b1;
      end else if (normalized_exponent <= 12'sd0) begin
        result_o    <= {s2_sign, 31'd0};
        underflow_o <= 1'b1;
      end else result_o <= {s2_sign, 8'(normalized_exponent), normalized_mantissa};
    end
  end

endmodule
