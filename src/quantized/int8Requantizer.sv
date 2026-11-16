`timescale 1ns / 100ps

// Affine int8 requantize: y = clamp(sat10(floor((acc * mult + 2^(shift - 1)) / 2^shift)) + zp, act_min, act_max), 9 stages: the product
// takes three on intMulPipe (one row per mantissa bit, the carry-save tree registered halfway, one add), since the 32 x 24 product in one
// cycle, and then in two halves, was the int8 build's worst path; the rounding add, the shift and the 10-bit saturation take one each (the
// 57-bit add into the barrel shift, then the shift into the saturate, were the next); the clamp compares and the add of zp run side by side
// on one stage, and the last stage only selects (the compare into the select into the add was 1.17 ns at 45 nm).
module int8Requantizer (
    input  logic               clk_i,
    input  logic               rstn_i,
    input  logic               valid_i,
    input  logic signed [31:0] acc_i,      // int32 accumulator of output channel c
    input  logic        [23:0] mult_i,     // unsigned mantissa of the scale S_c = mult * 2^-shift
    input  logic        [5:0]  shift_i,    // right shift, at most MAX_SHIFT
    input  logic signed [7:0]  zp_i,       // output zero point
    input  logic signed [7:0]  act_min_i,  // clamp: the int8 range or a fused activation's window
    input  logic signed [7:0]  act_max_i,
    output logic        [7:0]  result_o,
    output logic               done_o
);
  localparam int MANTISSA_WIDTH = 24;
  localparam int PRODUCT_WIDTH = 32 + MANTISSA_WIDTH;  // acc * mult, exact
  localparam int ROUNDED_WIDTH = PRODUCT_WIDTH + 1;  // plus the rounding constant, below 2^(MAX_SHIFT - 1)
  localparam logic signed [9:0] SAT_MAX = 10'sd511;  // 10 bits hold every value an int8 zp and clamp can tell apart
  localparam logic signed [9:0] SAT_MIN = -10'sd512;
  localparam int MUL_STAGES = 3;

  logic s1_v, p_v, s3a_v, s3b_v, s3_v, s4_v;
  logic [MUL_STAGES-1:0] pv;  // the product's stages
  logic signed [31:0] s1_acc;
  logic [MANTISSA_WIDTH-1:0] s1_mult;
  logic [5:0] s1_shift;
  logic signed [7:0] s1_zp, s1_lo, s1_hi, s3a_zp, s3a_lo, s3a_hi, s3b_zp, s3b_lo, s3b_hi, s3_zp, s3_lo, s3_hi;
  logic [5:0] s3a_shift;
  logic signed [ROUNDED_WIDTH-1:0] s3a_sum;  // the product plus half
  logic signed [ROUNDED_WIDTH-1:0] s3b_r;  // the rounded product shifted, before the saturation
  logic signed [8:0] s3_lo_m, s3_hi_m;  // the clamp bounds less zp: r is compared against them, then zp is added
  logic [ROUNDED_WIDTH-1:0] s1_half;  // 2^(shift - 1), 0 at shift 0
  // Beside the product: the shift, its half, zp and the clamp.
  logic [5:0] d_shift[MUL_STAGES];
  logic [ROUNDED_WIDTH-1:0] d_half[MUL_STAGES];
  logic signed [7:0] d_zp[MUL_STAGES], d_lo[MUL_STAGES], d_hi[MUL_STAGES];
  logic signed [PRODUCT_WIDTH:0] s2_wide;  // the product with one more sign bit
  logic signed [PRODUCT_WIDTH-1:0] s2_prod;
  logic signed [9:0] s3_r;  // the rounded, shifted product saturated to 10 bits
  logic s4_lt, s4_gt;  // r below act_min - zp, above act_max - zp
  logic [7:0] s4_sum, s4_lo, s4_hi;  // r + zp, act_min, act_max: the three results the last stage selects between
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_wide;  // the product's extra sign bit
  /* verilator lint_on UNUSEDSIGNAL */

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      s1_v   <= 1'b0;
      pv     <= '0;
      s3a_v  <= 1'b0;
      s3b_v  <= 1'b0;
      s3_v   <= 1'b0;
      s4_v   <= 1'b0;
      done_o <= 1'b0;
    end else begin
      s1_v   <= valid_i;
      pv     <= {pv[MUL_STAGES-2:0], s1_v};
      s3a_v  <= p_v;
      s3b_v  <= s3a_v;
      s3_v   <= s3b_v;
      s4_v   <= s3_v;
      done_o <= s4_v;
    end
  end

  // Stage 1: the operands, and the rounding constant decoded from the shift.
  always_ff @(posedge clk_i)
    if (valid_i) begin
      s1_acc   <= acc_i;
      s1_mult  <= mult_i;
      s1_shift <= shift_i;
      s1_half  <= (shift_i == 6'd0) ? '0 : (ROUNDED_WIDTH'(1) << (shift_i - 6'd1));
      s1_zp    <= zp_i;
      s1_lo    <= act_min_i;
      s1_hi    <= act_max_i;
    end

  // Stage 2: the signed accumulator times the unsigned mantissa (a zero bit above it), exact in PRODUCT_WIDTH bits.
  intMulPipe #(.AW(32), .BW(MANTISSA_WIDTH + 1), .STAGES(MUL_STAGES)) MUL (
      .clk_i(clk_i), .rstn_i(rstn_i), .valid_i(s1_v), .a_i(s1_acc), .b_i({1'b0, s1_mult}), .result_o(s2_wide), .done_o(p_v));
  assign s2_prod = s2_wide[PRODUCT_WIDTH-1:0];
  always_ff @(posedge clk_i) begin
    if (s1_v) begin
      d_shift[0] <= s1_shift;
      d_half[0]  <= s1_half;
      d_zp[0]    <= s1_zp;
      d_lo[0]    <= s1_lo;
      d_hi[0]    <= s1_hi;
    end
    for (int i = 1; i < MUL_STAGES; i++)
      if (pv[i-1]) begin
        d_shift[i] <= d_shift[i-1];
        d_half[i]  <= d_half[i-1];
        d_zp[i]    <= d_zp[i-1];
        d_lo[i]    <= d_lo[i-1];
        d_hi[i]    <= d_hi[i-1];
      end
  end

  // Stage 3a: round half up: the product plus half, exact.
  always_ff @(posedge clk_i)
    if (p_v) begin
      s3a_sum   <= $signed({s2_prod[PRODUCT_WIDTH-1], s2_prod}) + $signed(d_half[MUL_STAGES-1]);
      s3a_shift <= d_shift[MUL_STAGES-1];
      s3a_zp    <= d_zp[MUL_STAGES-1];
      s3a_lo    <= d_lo[MUL_STAGES-1];
      s3a_hi    <= d_hi[MUL_STAGES-1];
    end

  // Stage 3b: arithmetic right shift (floor).
  always_ff @(posedge clk_i)
    if (s3a_v) begin
      s3b_r  <= s3a_sum >>> s3a_shift;
      s3b_zp <= s3a_zp;
      s3b_lo <= s3a_lo;
      s3b_hi <= s3a_hi;
    end

  // Stage 3c: saturate to 10 bits; the clamp bounds less zp, so the next stage compares as it adds.
  always_ff @(posedge clk_i)
    if (s3b_v) begin
      if (s3b_r > ROUNDED_WIDTH'(SAT_MAX)) s3_r <= SAT_MAX;
      else if (s3b_r < ROUNDED_WIDTH'(SAT_MIN)) s3_r <= SAT_MIN;
      else s3_r <= s3b_r[9:0];
      s3_zp   <= s3b_zp;
      s3_lo   <= s3b_lo;
      s3_hi   <= s3b_hi;
      s3_lo_m <= 9'(s3b_lo) - 9'(s3b_zp);
      s3_hi_m <= 9'(s3b_hi) - 9'(s3b_zp);
    end

  // Stage 4: the clamp compares beside the add of zp: y = r + zp clamped to [act_min, act_max] is act_min where r < act_min - zp, act_max
  // where r > act_max - zp, else r + zp (the same integers as adding first: no term exceeds 10 bits, and every case fits int8).
  always_ff @(posedge clk_i)
    if (s3_v) begin
      s4_lt  <= s3_r < 10'(s3_lo_m);
      s4_gt  <= s3_r > 10'(s3_hi_m);
      s4_sum <= 8'(10'(s3_r) + 10'(s3_zp));
      s4_lo  <= s3_lo;
      s4_hi  <= s3_hi;
    end

  // Stage 5: the select, act_max first as the clamp's second test overrode its first.
  always_ff @(posedge clk_i)
    if (s4_v) result_o <= s4_gt ? s4_hi : (s4_lt ? s4_lo : s4_sum);

`ifndef SYNTHESIS
  localparam int MAX_SHIFT = MANTISSA_WIDTH + 31;  // the encoder's largest shift (scales down to 2^-32)
  // Checked on the stage-1 registers while s1_v marks a real beat; rstn_i stays since s1_v powers up random before the first reset edge.
  logic s1_bad;  // stage 1 took a beat whose shift exceeds MAX_SHIFT; only valid_i loads it, since a bubble's words are don't-cares
  logic [5:0] s1_bad_shift;  // that beat's shift, for the message
  always_ff @(posedge clk_i)
    if (valid_i) begin
      s1_bad       <= shift_i > 6'(MAX_SHIFT);
      s1_bad_shift <= shift_i;
    end
  a_shift_range: assert property (@(posedge clk_i) disable iff (!rstn_i) s1_v |-> !s1_bad)
    else $error("int8Requantizer: shift %0d above %0d", s1_bad_shift, MAX_SHIFT);
`endif
  assign unused_wide = s2_wide[PRODUCT_WIDTH];
endmodule
