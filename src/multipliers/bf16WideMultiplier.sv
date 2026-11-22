`timescale 1ns / 100ps

// bf16 x bf16 -> fp32, the exact product: fpMulWiden's algorithm with the format fixed at 8 exponent and 7 mantissa bits.
// Subnormal inputs read as zero, underflow flushes to a signed zero, overflow gives infinity, any NaN gives 7FC00000.
// valid_i at t, done_o at t+5: the operands are registered first (in the PE they also feed the next PE: a_o/b_o -> s1_exp). Only the valid chain is reset (D-8); the flags are zero in every cycle without done_o.
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

  // Stage 1: the classes, the product's fp32-biased exponent before normalization, the significands.
  logic s1_valid, s1_sign, s1_nan, s1_inf, s1_zero, s1_invalid;
  logic signed [11:0] s1_exp;
  logic [SIGNIFICAND_WIDTH-1:0] s1_significand_a, s1_significand_b;
  // Stage 2: the significand product.
  logic s2_valid, s2_sign, s2_nan, s2_inf, s2_zero, s2_invalid;
  logic signed [11:0] s2_exp;
  logic [PRODUCT_WIDTH-1:0] s2_significand_product;  // s2_product_s + s2_product_c, added in stage 3
  logic [PRODUCT_WIDTH-1:0] s2_product_s, s2_product_c;  // the product in carry-save form (the 8x8 multiply in stage 2 was the bf16 PE's 1.02-1.03 ns)
  // Stage 3: the significand product's add, registered with the class and exponent (the add, its top bit into the normalization and the
  // special cases in one stage were the bf16 meshes' 0.87-0.98 ns at 0.8, s2_product -> result_o).
  logic s3_valid, s3_sign, s3_nan, s3_inf, s3_zero, s3_invalid;
  logic signed [11:0] s3_exp;
  logic [PRODUCT_WIDTH-1:0] s3_significand_product;
  // Stage 4: the normalized exponent and mantissa; the exponent and its range checks for a product below 2 (0) and from 2 (1), from s3_exp alone.
  logic signed [11:0] exp_g[2];
  logic ovf_g[2], unf_g[2];
  logic [7:0] normalized_exponent;  // the exponent field; exp_g's range checks cover the rest
  logic [22:0] normalized_mantissa;

  // a * b for 8-bit a and b in carry-save form {sum, carry}: sum + carry == a * b mod 2^16.
  function automatic logic [2*PRODUCT_WIDTH-1:0] product_cs(input logic [SIGNIFICAND_WIDTH-1:0] a, input logic [SIGNIFICAND_WIDTH-1:0] b);
    logic [PRODUCT_WIDTH-1:0] l0[8], l1[6], l2[4], l3[3];
    for (int i = 0; i < 8; i++) l0[i] = b[i] ? (PRODUCT_WIDTH'(a) << i) : '0;
    for (int i = 0; i < 2; i++) begin  // 8 -> 6: six through two compressors, two passed on
      l1[2*i]   = l0[3*i] ^ l0[3*i+1] ^ l0[3*i+2];
      l1[2*i+1] = ((l0[3*i] & l0[3*i+1]) | (l0[3*i] & l0[3*i+2]) | (l0[3*i+1] & l0[3*i+2])) << 1;
    end
    l1[4] = l0[6];
    l1[5] = l0[7];
    for (int i = 0; i < 2; i++) begin  // 6 -> 4
      l2[2*i]   = l1[3*i] ^ l1[3*i+1] ^ l1[3*i+2];
      l2[2*i+1] = ((l1[3*i] & l1[3*i+1]) | (l1[3*i] & l1[3*i+2]) | (l1[3*i+1] & l1[3*i+2])) << 1;
    end
    l3[0] = l2[0] ^ l2[1] ^ l2[2];  // 4 -> 3
    l3[1] = ((l2[0] & l2[1]) | (l2[0] & l2[2]) | (l2[1] & l2[2])) << 1;
    l3[2] = l2[3];
    return {l3[0] ^ l3[1] ^ l3[2], ((l3[0] & l3[1]) | (l3[0] & l3[2]) | (l3[1] & l3[2])) << 1};  // 3 -> 2
  endfunction

`ifndef SYNTHESIS  // parameter checks; synthesis tools ignore or reject initial blocks
  initial if (PRODUCT_WIDTH > 22 || EXPONENT_WIDTH > 8) $error("bf16WideMultiplier: EXPONENT_WIDTH=%0d MANTISSA_WIDTH=%0d does not fit an exact fp32 product", EXPONENT_WIDTH, MANTISSA_WIDTH);
`endif

  // ── Stage 0: the operands registered ──
  logic                  s0_valid;
  logic [DATA_WIDTH-1:0] a_q, b_q;
  always_ff @(posedge clk_i or negedge rstn_i)
    if (!rstn_i) s0_valid <= 1'b0;
    else s0_valid <= valid_i;
  always_ff @(posedge clk_i)
    if (valid_i) {a_q, b_q} <= {a_i, b_i};  // no reset: read only with s0_valid

  // ── Stage 1: classify the inputs and add the exponents, rebased to fp32's bias ──
  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) s1_valid <= 1'b0;
    else s1_valid <= s0_valid;
  end

  always_ff @(posedge clk_i) begin
    if (s0_valid) begin
      automatic logic [EXPONENT_WIDTH-1:0] exponent_a = a_q[DATA_WIDTH-2:MANTISSA_WIDTH], exponent_b = b_q[DATA_WIDTH-2:MANTISSA_WIDTH];
      automatic logic zero_a = (exponent_a == '0), zero_b = (exponent_b == '0);
      automatic logic inf_a = (exponent_a == EXPONENT_ALL_ONES) && (a_q[MANTISSA_WIDTH-1:0] == '0), inf_b = (exponent_b == EXPONENT_ALL_ONES) && (b_q[MANTISSA_WIDTH-1:0] == '0);
      automatic logic nan_a = (exponent_a == EXPONENT_ALL_ONES) && (a_q[MANTISSA_WIDTH-1:0] != '0), nan_b = (exponent_b == EXPONENT_ALL_ONES) && (b_q[MANTISSA_WIDTH-1:0] != '0);
      automatic logic signaling_nan_in = (nan_a && !a_q[MANTISSA_WIDTH-1]) || (nan_b && !b_q[MANTISSA_WIDTH-1]);
      automatic logic invalid = (zero_a && inf_b) || (inf_a && zero_b);
      s1_sign    <= a_q[DATA_WIDTH-1] ^ b_q[DATA_WIDTH-1];
      s1_nan     <= nan_a || nan_b || invalid;
      s1_invalid <= invalid || signaling_nan_in;
      s1_inf     <= inf_a || inf_b;
      s1_zero    <= zero_a || zero_b;
      s1_exp     <= $signed({4'b0, exponent_a}) + $signed({4'b0, exponent_b}) - 12'(2 * EXPONENT_BIAS) + 12'sd127;
      s1_significand_a      <= {1'b1, a_q[MANTISSA_WIDTH-1:0]};
      s1_significand_b      <= {1'b1, b_q[MANTISSA_WIDTH-1:0]};
    end
  end

  // ── Stage 2: significand product ──
  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) s2_valid <= 1'b0;
    else s2_valid <= s1_valid;
  end

  always_ff @(posedge clk_i) begin
    if (s1_valid) begin
      {s2_sign, s2_nan, s2_inf, s2_zero, s2_invalid} <= {s1_sign, s1_nan, s1_inf, s1_zero, s1_invalid};
      s2_exp <= s1_exp;
      {s2_product_s, s2_product_c} <= product_cs(s1_significand_a, s1_significand_b);
    end
  end

  // ── Stage 3: the significand product's add ──
  assign s2_significand_product = s2_product_s + s2_product_c;
  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) s3_valid <= 1'b0;
    else s3_valid <= s2_valid;
  end
  always_ff @(posedge clk_i)
    if (s2_valid) begin
      {s3_sign, s3_nan, s3_inf, s3_zero, s3_invalid} <= {s2_sign, s2_nan, s2_inf, s2_zero, s2_invalid};
      s3_exp <= s2_exp;
      s3_significand_product <= s2_significand_product;
    end
  // ── Stage 4: normalize (product in [1, 4)), place in fp32, handle range ──
  always_comb
    for (int g = 0; g < 2; g++) begin
      exp_g[g] = s3_exp + 12'(g);
      ovf_g[g] = exp_g[g] >= 12'sd255;
      unf_g[g] = exp_g[g] <= 12'sd0;
    end
  always_comb begin
    normalized_exponent = 8'(exp_g[s3_significand_product[PRODUCT_WIDTH-1]]);
    normalized_mantissa = s3_significand_product[PRODUCT_WIDTH-1] ? 23'({s3_significand_product[PRODUCT_WIDTH-2:0], {(24 - PRODUCT_WIDTH){1'b0}}}) : 23'({s3_significand_product[PRODUCT_WIDTH-3:0], {(25 - PRODUCT_WIDTH){1'b0}}});
  end

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) done_o <= 1'b0;
    else done_o <= s3_valid;
  end

  always_ff @(posedge clk_i) begin
    overflow_o  <= 1'b0;
    underflow_o <= 1'b0;
    invalid_o   <= 1'b0;
    if (s3_valid) begin
      invalid_o <= s3_invalid;
      if (s3_nan) result_o <= 32'h7FC00000;
      else if (s3_inf) result_o <= {s3_sign, 8'hFF, 23'd0};
      else if (s3_zero) result_o <= {s3_sign, 31'd0};
      else if (ovf_g[s3_significand_product[PRODUCT_WIDTH-1]]) begin
        result_o   <= {s3_sign, 8'hFF, 23'd0};
        overflow_o <= 1'b1;
      end else if (unf_g[s3_significand_product[PRODUCT_WIDTH-1]]) begin
        result_o    <= {s3_sign, 31'd0};
        underflow_o <= 1'b1;
      end else result_o <= {s3_sign, 8'(normalized_exponent), normalized_mantissa};
    end
  end

endmodule
