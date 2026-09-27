`timescale 1ns / 100ps

// Multiplies two narrow floats (EXP_W exponent bits, MAN_W mantissa bits) into an fp32 result.
// The product of two significands of MAN_W+1 bits fits fp32's 24, so for MAN_W <= 10 (bf16, fp16) it is exact.
// Same ports, flags and special-value handling as fp32Multiplier: subnormal inputs read as zero, underflow
// flushes to a signed zero, overflow gives infinity, any NaN gives 7FC00000. valid_i at t, done_o at t+3.
module fpMulWiden #(
    parameter int EXP_W = 8,  // bf16: 8 and 7; fp16: 5 and 10
    parameter int MAN_W = 7,
    parameter int W     = 1 + EXP_W + MAN_W
) (
    input wire         clk_i,
    input wire         rstn_i,
    input wire         valid_i,
    input wire [W-1:0] A,
    input wire [W-1:0] B,

    output reg [31:0] result_o,
    output reg        done_o,

    output reg overflow_o,   // finite inputs, infinite result
    output reg underflow_o,  // result flushed to zero
    output reg invalid_o     // 0 * Inf, or a signaling NaN input
);
  localparam int SIG_W = MAN_W + 1;
  localparam int PW = 2 * SIG_W;  // significand product width
  localparam int BIAS = (1 << (EXP_W - 1)) - 1;
  localparam logic [EXP_W-1:0] EXP_ONES = '1;

  initial if (PW > 22 || EXP_W > 8) $error("fpMulWiden: EXP_W=%0d MAN_W=%0d does not fit an exact fp32 product", EXP_W, MAN_W);

  // ── Stage 1: classify the inputs and add the exponents, rebased to fp32's bias ──
  logic s1_v, s1_sign, s1_nan, s1_inf, s1_zero, s1_invalid;
  logic signed [11:0] s1_exp;  // fp32-biased exponent of the product before normalization
  logic [SIG_W-1:0] s1_sa, s1_sb;

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      s1_v <= 1'b0;
      {s1_sign, s1_nan, s1_inf, s1_zero, s1_invalid} <= '0;
      s1_exp <= '0;
      s1_sa <= '0;
      s1_sb <= '0;
    end else begin
      s1_v <= valid_i;
      if (valid_i) begin
        automatic logic [EXP_W-1:0] ea = A[W-2:MAN_W], eb = B[W-2:MAN_W];
        automatic logic zero_a = (ea == '0), zero_b = (eb == '0);
        automatic logic inf_a = (ea == EXP_ONES) && (A[MAN_W-1:0] == '0), inf_b = (eb == EXP_ONES) && (B[MAN_W-1:0] == '0);
        automatic logic nan_a = (ea == EXP_ONES) && (A[MAN_W-1:0] != '0), nan_b = (eb == EXP_ONES) && (B[MAN_W-1:0] != '0);
        automatic logic snan = (nan_a && !A[MAN_W-1]) || (nan_b && !B[MAN_W-1]);
        automatic logic inv = (zero_a && inf_b) || (inf_a && zero_b);
        s1_sign    <= A[W-1] ^ B[W-1];
        s1_nan     <= nan_a || nan_b || inv;
        s1_invalid <= inv || snan;
        s1_inf     <= inf_a || inf_b;
        s1_zero    <= zero_a || zero_b;
        s1_exp     <= $signed({4'b0, ea}) + $signed({4'b0, eb}) - 12'(2 * BIAS) + 12'sd127;
        s1_sa      <= {1'b1, A[MAN_W-1:0]};
        s1_sb      <= {1'b1, B[MAN_W-1:0]};
      end
    end
  end

  // ── Stage 2: significand product ──
  logic s2_v, s2_sign, s2_nan, s2_inf, s2_zero, s2_invalid;
  logic signed [11:0] s2_exp;
  logic [PW-1:0] s2_p;

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      s2_v <= 1'b0;
      {s2_sign, s2_nan, s2_inf, s2_zero, s2_invalid} <= '0;
      s2_exp <= '0;
      s2_p <= '0;
    end else begin
      s2_v <= s1_v;
      if (s1_v) begin
        {s2_sign, s2_nan, s2_inf, s2_zero, s2_invalid} <= {s1_sign, s1_nan, s1_inf, s1_zero, s1_invalid};
        s2_exp <= s1_exp;
        s2_p   <= PW'(s1_sa) * PW'(s1_sb);
      end
    end
  end

  // ── Stage 3: normalize (product in [1, 4)), place in fp32, handle range ──
  logic signed [11:0] n_exp;
  logic [22:0] n_man;
  always_comb begin
    n_exp = s2_exp + (s2_p[PW-1] ? 12'sd1 : 12'sd0);
    n_man = s2_p[PW-1] ? 23'({s2_p[PW-2:0], {(24 - PW){1'b0}}}) : 23'({s2_p[PW-3:0], {(25 - PW){1'b0}}});
  end

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      result_o    <= '0;
      done_o      <= 1'b0;
      overflow_o  <= 1'b0;
      underflow_o <= 1'b0;
      invalid_o   <= 1'b0;
    end else begin
      done_o      <= s2_v;
      overflow_o  <= 1'b0;
      underflow_o <= 1'b0;
      invalid_o   <= 1'b0;
      if (s2_v) begin
        invalid_o <= s2_invalid;
        if (s2_nan) result_o <= 32'h7FC00000;
        else if (s2_inf) result_o <= {s2_sign, 8'hFF, 23'd0};
        else if (s2_zero) result_o <= {s2_sign, 31'd0};
        else if (n_exp >= 12'sd255) begin
          result_o   <= {s2_sign, 8'hFF, 23'd0};
          overflow_o <= 1'b1;
        end else if (n_exp <= 12'sd0) begin
          result_o    <= {s2_sign, 31'd0};
          underflow_o <= 1'b1;
        end else result_o <= {s2_sign, 8'(n_exp), n_man};
      end
    end
  end

endmodule
