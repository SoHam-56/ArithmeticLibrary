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

  // Stage 1: the classes, the exponent sum, the partial products through their first compressor level.
  logic s1_valid, s1_sign, s1_nan, s1_inf, s1_zero, s1_invalid;
  logic [EXPONENT_WIDTH:0] s1_exp_sum;  // exponent_a + exponent_b; the rebias to fp32's is stage 2's (one 12-bit three-term add in stage 1 was N16 T2's b_q -> s1_exp)
  logic [PRODUCT_WIDTH-1:0] s1_pp[6];  // the significand product's partial products after their first compressor level (8 -> 6 rows)
  // Stage 2: the significand product.
  logic s2_valid, s2_sign, s2_nan, s2_inf, s2_zero, s2_invalid;
  logic signed [11:0] s2_exp;
  logic [PRODUCT_WIDTH-1:0] s2_significand_product;  // s2_product_s + s2_product_c, added in stage 3
  logic [PRODUCT_WIDTH-1:0] s2_product_s, s2_product_c;  // the product in carry-save form (the 8x8 multiply in stage 2 was the bf16 PE's 1.02-1.03 ns;
                                                          // the partial products and the whole tree in stage 2 were N16 T4's 0.967, s1_significand_b -> s2_product_s)
  // Stage 3: the significand product's add, registered with the class and exponent (the add, its top bit into the normalization and the
  // special cases in one stage were the bf16 meshes' 0.87-0.98 ns at 0.8, s2_product -> result_o).
  logic s3_valid, s3_sign, s3_nan, s3_inf, s3_zero, s3_invalid;
  logic signed [11:0] s3_exp;
  logic [PRODUCT_WIDTH-1:0] s3_significand_product;
  // The stage 3 add as a carry select: the low half, and the high half for either carry, side by side (one 16-bit add was N8 T2 / T4's 0.931).
  localparam int HALF = PRODUCT_WIDTH / 2;
  logic [HALF:0] add_lo;  // with its carry out
  logic [PRODUCT_WIDTH-HALF-1:0] add_hi0, add_hi1;
  // Stage 4: the normalized exponent and mantissa; the exponent and its range checks for a product below 2 (0) and from 2 (1), from s3_exp alone.
  logic signed [11:0] exp_g[2];
  logic ovf_g[2], unf_g[2];
  logic [7:0] normalized_exponent;  // the exponent field; exp_g's range checks cover the rest
  logic [22:0] normalized_mantissa;

  // a * b for 8-bit a and b in carry-save form, in two parts: pp_level1 the partial products through the first compressor level (8 -> 6
  // rows, stage 1), product_cs the rest (6 -> 2, stage 2); sum + carry == a * b mod 2^16.
  function automatic logic [6*PRODUCT_WIDTH-1:0] pp_level1(input logic [SIGNIFICAND_WIDTH-1:0] a, input logic [SIGNIFICAND_WIDTH-1:0] b);
    logic [PRODUCT_WIDTH-1:0] l0[8], l1[6];
    for (int i = 0; i < 8; i++) l0[i] = b[i] ? (PRODUCT_WIDTH'(a) << i) : '0;
    for (int i = 0; i < 2; i++) begin  // 8 -> 6: six through two compressors, two passed on
      l1[2*i]   = l0[3*i] ^ l0[3*i+1] ^ l0[3*i+2];
      l1[2*i+1] = ((l0[3*i] & l0[3*i+1]) | (l0[3*i] & l0[3*i+2]) | (l0[3*i+1] & l0[3*i+2])) << 1;
    end
    l1[4] = l0[6];
    l1[5] = l0[7];
    return {l1[5], l1[4], l1[3], l1[2], l1[1], l1[0]};
  endfunction
  function automatic logic [2*PRODUCT_WIDTH-1:0] product_cs(input logic [PRODUCT_WIDTH-1:0] l1[6]);
    logic [PRODUCT_WIDTH-1:0] l2[4], l3[3];
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
      s1_exp_sum <= {1'b0, exponent_a} + {1'b0, exponent_b};
      {s1_pp[5], s1_pp[4], s1_pp[3], s1_pp[2], s1_pp[1], s1_pp[0]} <= pp_level1({1'b1, a_q[MANTISSA_WIDTH-1:0]}, {1'b1, b_q[MANTISSA_WIDTH-1:0]});
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
      s2_exp <= $signed({3'b0, s1_exp_sum}) - 12'(2 * EXPONENT_BIAS) + 12'sd127;  // the product's fp32-biased exponent before normalization
      {s2_product_s, s2_product_c} <= product_cs(s1_pp);
    end
  end

  // ── Stage 3: the significand product's add ──
  assign add_lo  = {1'b0, s2_product_s[HALF-1:0]} + {1'b0, s2_product_c[HALF-1:0]};
  assign add_hi0 = s2_product_s[PRODUCT_WIDTH-1:HALF] + s2_product_c[PRODUCT_WIDTH-1:HALF];
  assign add_hi1 = s2_product_s[PRODUCT_WIDTH-1:HALF] + s2_product_c[PRODUCT_WIDTH-1:HALF] + 1'b1;
  assign s2_significand_product = {add_lo[HALF] ? add_hi1 : add_hi0, add_lo[HALF-1:0]};  // == s2_product_s + s2_product_c
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
