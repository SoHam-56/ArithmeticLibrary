`timescale 1ns / 100ps

// TFLite's int8 requantize, bit-exact (DOUBLE: SRDHM then RoundingDivideByPOT; SINGLE: TFLITE_SINGLE_ROUNDING), 4 stages.
module tfliteRequant #(
    parameter string ROUNDING = sienna_fmt_pkg::REQ_ROUNDING  // G0's variant; the DV overrides it to run both
) (
    input  logic               clk_i,
    input  logic               rstn_i,
    input  logic               valid_i,
    input  logic signed [31:0] acc_i,      // int32 accumulator of output channel c
    input  logic signed [31:0] mult_i,     // Q0.31 multiplier M_c, TFLite's int32_t
    input  logic signed [7:0]  shift_i,    // shift_c: positive shifts left, negative right
    input  logic signed [7:0]  zp_i,       // output zero point
    input  logic signed [7:0]  act_min_i,  // clamp: the int8 range, ReLU or ReLU6
    input  logic signed [7:0]  act_max_i,
    output logic        [7:0]  result_o,
    output logic               done_o
);
  localparam bit SINGLE = (ROUNDING == "SINGLE");
  localparam logic signed [31:0] INT_MIN = 32'sh8000_0000;
  localparam logic signed [31:0] INT_MAX = 32'sh7FFF_FFFF;

  if ((ROUNDING != "SINGLE") && (ROUNDING != "DOUBLE")) begin : G_BAD_ROUNDING
    $fatal(1, "tfliteRequant: unsupported ROUNDING %s, use SINGLE or DOUBLE", ROUNDING);
  end

  logic s1_v, s2_v, s3_v;
  logic signed [31:0] s1_x, s1_m;  // DOUBLE: acc * 2^left wrapped to 32 bits; SINGLE: acc
  logic [5:0] s1_sh, s2_sh;  // DOUBLE: right shift 0..31; SINGLE: 31 - shift, 1..62
  logic signed [7:0] s1_zp, s1_lo, s1_hi, s2_zp, s2_lo, s2_hi, s3_zp, s3_lo, s3_hi;
  logic signed [63:0] s2_p;  // DOUBLE: SaturatingRoundingDoublingHighMul (fits 32 bits); SINGLE: acc * mult
  logic signed [31:0] s3_q;  // the rounded right shift, before + zp

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

  // Stage 1: DOUBLE applies TFLite's int32 x * (1 << left_shift); SINGLE forms the total right shift.
  always_ff @(posedge clk_i)
    if (valid_i) begin
      s1_m  <= mult_i;
      s1_zp <= zp_i;
      s1_lo <= act_min_i;
      s1_hi <= act_max_i;
      if (SINGLE) begin
        s1_x  <= acc_i;
        s1_sh <= 6'(8'sd31 - shift_i);
      end else if (shift_i > 8'sd0) begin
        s1_x  <= acc_i <<< shift_i[4:0];
        s1_sh <= 6'd0;
      end else begin
        s1_x  <= acc_i;
        s1_sh <= 6'(-shift_i);
      end
    end

  // Stage 2: the 32 x 32 product; DOUBLE's floor((a*b + 2^30) / 2^31) equals gemmlowp's nudge and truncating divide.
  always_ff @(posedge clk_i)
    if (s1_v) begin
      automatic logic signed [63:0] ab = $signed({{32{s1_x[31]}}, s1_x}) * $signed({{32{s1_m[31]}}, s1_m});
      s2_zp <= s1_zp;
      s2_lo <= s1_lo;
      s2_hi <= s1_hi;
      s2_sh <= s1_sh;
      if (SINGLE) s2_p <= ab;
      else if ((s1_x == INT_MIN) && (s1_m == INT_MIN)) s2_p <= 64'(INT_MAX);  // the one product that overflows saturates
      else s2_p <= (ab + 64'sd1073741824) >>> 31;
    end

  // Stage 3: the rounding right shift alone; + zp and the clamps follow a stage later, for logic depth.
  always_ff @(posedge clk_i)
    if (s2_v) begin
      automatic logic signed [31:0] q;
      if (SINGLE) begin
        automatic logic signed [63:0] r = (s2_p + (64'sd1 <<< (s2_sh - 6'd1))) >>> s2_sh;
        q = r[31:0];  // static_cast<int32_t>: the low 32 bits
      end else begin
        automatic logic signed [31:0] x = s2_p[31:0];
        automatic logic [31:0] mask = (32'd1 << s2_sh) - 32'd1;
        automatic logic [31:0] thr = (mask >> 1) + 32'(x[31]);
        q = (x >>> s2_sh) + (((32'(x) & mask) > thr) ? 32'sd1 : 32'sd0);  // RoundingDivideByPOT: ties away from zero
      end
      s3_q  <= q;
      s3_zp <= s2_zp;
      s3_lo <= s2_lo;
      s3_hi <= s2_hi;
    end

  // Stage 4: + zp in int32, then max with act_min and min with act_max, TFLite's order.
  always_ff @(posedge clk_i)
    if (s3_v) begin
      automatic logic signed [31:0] y;
      y = s3_q + 32'(s3_zp);
      if (y < 32'(s3_lo)) y = 32'(s3_lo);
      if (y > 32'(s3_hi)) y = 32'(s3_hi);
      result_o <= y[7:0];
    end

`ifndef SYNTHESIS
  always @(posedge clk_i)
    if (rstn_i && valid_i)
      assert ((shift_i >= -31) && (shift_i <= 30))
      else $error("tfliteRequant: shift %0d outside [-31, 30]", shift_i);
`endif

endmodule
