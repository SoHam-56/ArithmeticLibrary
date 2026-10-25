`timescale 1ns / 100ps

// Affine int8 ADD: y = clamp(sat10(floor(((q1 - zp1) m1 + (q2 - zp2) m2 + 2^(shift - 1)) / 2^shift)) + zpo, act_min, act_max), 6 stages.
module int8QuantizedAdder (
    input  logic               clk_i,
    input  logic               rstn_i,
    input  logic               valid_i,
    input  logic        [7:0]  q1_i,       // input 1's code
    input  logic        [7:0]  q2_i,       // input 2's code
    input  logic signed [7:0]  zp1_i,      // the inputs' zero points
    input  logic signed [7:0]  zp2_i,
    input  logic        [31:0] m1_i,       // unsigned mantissas of s1 / s_out and s2 / s_out on one shared shift
    input  logic        [31:0] m2_i,
    input  logic        [5:0]  shift_i,    // the shared right shift, at most MAX_SHIFT
    input  logic signed [7:0]  zpo_i,      // output zero point
    input  logic signed [7:0]  act_min_i,  // the fused activation's clamp
    input  logic signed [7:0]  act_max_i,
    output logic        [7:0]  result_o,
    output logic               done_o
);
  localparam int MANTISSA_WIDTH = 32;
  localparam int PRODUCT_WIDTH = 9 + MANTISSA_WIDTH;  // (q - zp) m, exact
  localparam int SUM_WIDTH = PRODUCT_WIDTH + 1;
  localparam int ROUNDED_WIDTH = SUM_WIDTH + 1;  // plus the rounding constant, below 2^(MAX_SHIFT - 1)
  localparam logic signed [9:0] SAT_MAX = 10'sd511;  // 10 bits hold every value an int8 zpo and clamp can tell apart
  localparam logic signed [9:0] SAT_MIN = -10'sd512;

  logic v1, v2, v3, v4, v5;
  logic signed [8:0] s1_d1, s1_d2;  // q - zp, in [-255, 255]
  logic [MANTISSA_WIDTH-1:0] s1_m1, s1_m2;
  logic [5:0] s1_shift, s2_shift, s3_shift, s4_shift;
  logic [ROUNDED_WIDTH-1:0] s1_half, s2_half, s3_half;  // 2^(shift - 1), 0 at shift 0
  logic signed [7:0] s1_zpo, s1_lo, s1_hi, s2_zpo, s2_lo, s2_hi, s3_zpo, s3_lo, s3_hi, s4_zpo, s4_lo, s4_hi, s5_zpo, s5_lo, s5_hi;
  logic signed [PRODUCT_WIDTH-1:0] s2_p1, s2_p2;
  logic signed [SUM_WIDTH-1:0] s3_sum;
  logic signed [ROUNDED_WIDTH-1:0] s4_rnd;
  logic signed [9:0] s5_r;  // the rounded, shifted sum saturated to 10 bits

  always_ff @(posedge clk_i or negedge rstn_i)
    if (!rstn_i) {v1, v2, v3, v4, v5, done_o} <= '0;
    else {v1, v2, v3, v4, v5, done_o} <= {valid_i, v1, v2, v3, v4, v5};

  // Stage 1: d = q - zp per input, and the rounding constant decoded from the shift.
  always_ff @(posedge clk_i)
    if (valid_i) begin
      s1_d1    <= $signed({q1_i[7], q1_i}) - $signed({zp1_i[7], zp1_i});
      s1_d2    <= $signed({q2_i[7], q2_i}) - $signed({zp2_i[7], zp2_i});
      s1_m1    <= m1_i;
      s1_m2    <= m2_i;
      s1_shift <= shift_i;
      s1_half  <= (shift_i == 6'd0) ? '0 : (ROUNDED_WIDTH'(1) << (shift_i - 6'd1));
      s1_zpo   <= zpo_i;
      s1_lo    <= act_min_i;
      s1_hi    <= act_max_i;
    end

  // Stage 2: the two 9 x 32 signed-by-unsigned products, exact.
  always_ff @(posedge clk_i)
    if (v1) begin
      s2_p1    <= $signed({{MANTISSA_WIDTH{s1_d1[8]}}, s1_d1}) * $signed({9'd0, s1_m1});
      s2_p2    <= $signed({{MANTISSA_WIDTH{s1_d2[8]}}, s1_d2}) * $signed({9'd0, s1_m2});
      s2_shift <= s1_shift;
      s2_half  <= s1_half;
      s2_zpo   <= s1_zpo;
      s2_lo    <= s1_lo;
      s2_hi    <= s1_hi;
    end

  // Stage 3: their sum, exact.
  always_ff @(posedge clk_i)
    if (v2) begin
      s3_sum   <= SUM_WIDTH'(s2_p1) + SUM_WIDTH'(s2_p2);
      s3_shift <= s2_shift;
      s3_half  <= s2_half;
      s3_zpo   <= s2_zpo;
      s3_lo    <= s2_lo;
      s3_hi    <= s2_hi;
    end

  // Stage 4: plus half, for round half up.
  always_ff @(posedge clk_i)
    if (v3) begin
      s4_rnd   <= ROUNDED_WIDTH'(s3_sum) + $signed(s3_half);
      s4_shift <= s3_shift;
      s4_zpo   <= s3_zpo;
      s4_lo    <= s3_lo;
      s4_hi    <= s3_hi;
    end

  // Stage 5: arithmetic right shift (floor), saturated to 10 bits.
  always_ff @(posedge clk_i)
    if (v4) begin
      automatic logic signed [ROUNDED_WIDTH-1:0] r = s4_rnd >>> s4_shift;
      if (r > ROUNDED_WIDTH'(SAT_MAX)) s5_r <= SAT_MAX;
      else if (r < ROUNDED_WIDTH'(SAT_MIN)) s5_r <= SAT_MIN;
      else s5_r <= r[9:0];
      s5_zpo <= s4_zpo;
      s5_lo  <= s4_lo;
      s5_hi  <= s4_hi;
    end

  // Stage 6: + zpo on 11 bits, then max with act_min and min with act_max.
  always_ff @(posedge clk_i)
    if (v5) begin
      automatic logic signed [10:0] y = 11'(s5_r) + 11'(s5_zpo);
      if (y < 11'(s5_lo)) y = 11'(s5_lo);
      if (y > 11'(s5_hi)) y = 11'(s5_hi);
      result_o <= y[7:0];
    end

`ifndef SYNTHESIS
  localparam int MAX_SHIFT = MANTISSA_WIDTH + 9;  // the encoder's largest shift (ratios down to 2^-10)
  logic s1_bad;  // stage 1 took a beat whose shift exceeds MAX_SHIFT; only valid_i loads it, since a bubble's words are don't-cares
  logic [5:0] s1_bad_shift;  // that beat's shift, for the message
  always_ff @(posedge clk_i)
    if (valid_i) begin
      s1_bad       <= shift_i > 6'(MAX_SHIFT);
      s1_bad_shift <= shift_i;
    end
  // Checked on the stage-1 registers while v1 marks a real beat; rstn_i stays since v1 powers up random before the first reset edge.
  a_shift_range: assert property (@(posedge clk_i) disable iff (!rstn_i) v1 |-> !s1_bad)
    else $error("int8QuantizedAdder: shift %0d above %0d", s1_bad_shift, MAX_SHIFT);
`endif

endmodule
