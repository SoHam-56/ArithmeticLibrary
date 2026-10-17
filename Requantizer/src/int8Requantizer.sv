`timescale 1ns / 100ps

// Affine int8 requantize: y = clamp(sat10(floor((acc * mult + 2^(shift - 1)) / 2^shift)) + zp, act_min, act_max), 4 stages.
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

  logic s1_v, s2_v, s3_v;
  logic signed [31:0] s1_acc;
  logic [MANTISSA_WIDTH-1:0] s1_mult;
  logic [5:0] s1_shift, s2_shift;
  logic signed [7:0] s1_zp, s1_lo, s1_hi, s2_zp, s2_lo, s2_hi, s3_zp, s3_lo, s3_hi;
  logic [ROUNDED_WIDTH-1:0] s1_half, s2_half;  // 2^(shift - 1), 0 at shift 0
  logic signed [PRODUCT_WIDTH-1:0] s2_prod;
  logic signed [9:0] s3_r;  // the rounded, shifted product saturated to 10 bits

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      s1_v   <= 1'b0;
      s2_v   <= 1'b0;
      s3_v   <= 1'b0;
      done_o <= 1'b0;
    end else begin
      s1_v   <= valid_i;
      s2_v   <= s1_v;
      s3_v   <= s2_v;
      done_o <= s3_v;
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

  // Stage 2: the signed-by-unsigned product, exact in PRODUCT_WIDTH bits.
  always_ff @(posedge clk_i)
    if (s1_v) begin
      s2_prod  <= $signed({{MANTISSA_WIDTH{s1_acc[31]}}, s1_acc}) * $signed({32'd0, s1_mult});
      s2_shift <= s1_shift;
      s2_half  <= s1_half;
      s2_zp    <= s1_zp;
      s2_lo    <= s1_lo;
      s2_hi    <= s1_hi;
    end

  // Stage 3: round half up (floor of the product plus half), arithmetic right shift, saturate to 10 bits.
  always_ff @(posedge clk_i)
    if (s2_v) begin
      automatic logic signed [ROUNDED_WIDTH-1:0] r = ($signed({s2_prod[PRODUCT_WIDTH-1], s2_prod}) + $signed(s2_half)) >>> s2_shift;
      if (r > ROUNDED_WIDTH'(SAT_MAX)) s3_r <= SAT_MAX;
      else if (r < ROUNDED_WIDTH'(SAT_MIN)) s3_r <= SAT_MIN;
      else s3_r <= r[9:0];
      s3_zp <= s2_zp;
      s3_lo <= s2_lo;
      s3_hi <= s2_hi;
    end

  // Stage 4: + zp on 11 bits, then max with act_min and min with act_max.
  always_ff @(posedge clk_i)
    if (s3_v) begin
      automatic logic signed [10:0] y = 11'(s3_r) + 11'(s3_zp);
      if (y < 11'(s3_lo)) y = 11'(s3_lo);
      if (y > 11'(s3_hi)) y = 11'(s3_hi);
      result_o <= y[7:0];
    end

`ifndef SYNTHESIS
  localparam int MAX_SHIFT = MANTISSA_WIDTH + 31;  // the encoder's largest shift (scales down to 2^-32)
  logic s1_bad;  // stage 1 took a beat whose shift exceeds MAX_SHIFT; only valid_i loads it, since a bubble's words are don't-cares
  logic [5:0] s1_bad_shift;  // that beat's shift, for the message
  always_ff @(posedge clk_i)
    if (valid_i) begin
      s1_bad       <= shift_i > 6'(MAX_SHIFT);
      s1_bad_shift <= shift_i;
    end
  // Checked on the stage-1 registers while s1_v marks a real beat; rstn_i stays since s1_v powers up random before the first reset edge.
  a_shift_range: assert property (@(posedge clk_i) disable iff (!rstn_i) s1_v |-> !s1_bad)
    else $error("int8Requantizer: shift %0d above %0d", s1_bad_shift, MAX_SHIFT);
`endif

endmodule
