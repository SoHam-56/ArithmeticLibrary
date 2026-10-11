`timescale 1ns / 100ps

// TFLite's int8 ADD (reference integer_ops/add.h), bit-exact, DOUBLE or SINGLE rounding: (q - zp) << 20 per input, scaled, summed, rescaled, + zpo, clamped; 6 stages.
module tfliteAdd #(
    parameter string ROUNDING = sienna_fmt_pkg::REQ_ROUNDING  // G0b's variant; the DV overrides it to run both
) (
    input  logic               clk_i,
    input  logic               rstn_i,
    input  logic               valid_i,
    input  logic        [7:0]  q1_i,   // input 1's code
    input  logic        [7:0]  q2_i,   // input 2's code
    input  logic signed [7:0]  zp1_i,  // the inputs' zero points
    input  logic signed [7:0]  zp2_i,
    input  logic signed [31:0] m1_i,   // Q0.31 multipliers from QuantizeMultiplierSmallerThanOneExp
    input  logic signed [31:0] m2_i,
    input  logic signed [31:0] mo_i,
    input  logic signed [7:0]  s1_i,   // their shifts, each in [-31, 0]
    input  logic signed [7:0]  s2_i,
    input  logic signed [7:0]  so_i,
    input  logic signed [7:0]  zpo_i,  // output zero point
    input  logic signed [7:0]  min_i,  // the fused activation's clamp
    input  logic signed [7:0]  max_i,
    output logic        [7:0]  result_o,
    output logic               done_o
);
  localparam bit SINGLE = (ROUNDING == "SINGLE");

  if ((ROUNDING != "SINGLE") && (ROUNDING != "DOUBLE")) begin : G_BAD_ROUNDING
    $fatal(1, "tfliteAdd: unsupported ROUNDING %s, use SINGLE or DOUBLE", ROUNDING);
  end

  // gemmlowp RoundingDivideByPOT: x / 2^e to nearest, ties away from zero; e in [0, 31].
  function automatic logic signed [31:0] rdbpot(input logic signed [31:0] x, input logic [4:0] e);
    logic [31:0] mask, thr;
    mask = (32'd1 << e) - 32'd1;
    thr  = (mask >> 1) + 32'(x[31]);
    return (x >>> e) + (((32'(x) & mask) > thr) ? 32'sd1 : 32'sd0);
  endfunction

  logic v1, v2, v3, v4, v5;
  logic signed [40:0] s1_p1, s1_p2;  // DOUBLE: SRDHM(d << 20, m), below 2^28; SINGLE: d * m
  logic [5:0] s1_e1, s1_e2, s1_eo, s2_eo, s3_eo, s4_eo;  // right shifts: -s (DOUBLE), 11 - s and 31 - so (SINGLE)
  logic signed [31:0] s1_mo, s2_mo, s3_mo;
  logic signed [7:0] s1_zpo, s1_lo, s1_hi, s2_zpo, s2_lo, s2_hi, s3_zpo, s3_lo, s3_hi, s4_zpo, s4_lo, s4_hi, s5_zpo, s5_lo, s5_hi;
  logic signed [31:0] s2_a1, s2_a2;  // the scaled inputs, below 2^28
  logic signed [29:0] s3_sum;  // their sum, below 2^29
  logic signed [61:0] s4_p;  // DOUBLE: SRDHM(sum, mo) in the low 32 bits; SINGLE: sum * mo
  logic signed [31:0] s5_r;  // the rescaled sum, before + zpo

  always_ff @(posedge clk_i or negedge rstn_i)
    if (!rstn_i) {v1, v2, v3, v4, v5, done_o} <= '0;
    else {v1, v2, v3, v4, v5, done_o} <= {valid_i, v1, v2, v3, v4, v5};

  // Stage 1: d = q - zp and the 9 x 32 product; DOUBLE rounds it as SRDHM(d << 20, m) = (d m + 2^10) >>> 11 (the 2^20 cancels).
  always_ff @(posedge clk_i)
    if (valid_i) begin
      automatic logic signed [8:0] d1 = $signed({q1_i[7], q1_i}) - $signed({zp1_i[7], zp1_i});
      automatic logic signed [8:0] d2 = $signed({q2_i[7], q2_i}) - $signed({zp2_i[7], zp2_i});
      automatic logic signed [40:0] p1 = d1 * m1_i;
      automatic logic signed [40:0] p2 = d2 * m2_i;
      s1_p1  <= SINGLE ? p1 : ((p1 + 41'sd1024) >>> 11);
      s1_p2  <= SINGLE ? p2 : ((p2 + 41'sd1024) >>> 11);
      s1_e1  <= SINGLE ? 6'(8'sd11 - s1_i) : 6'(-s1_i);
      s1_e2  <= SINGLE ? 6'(8'sd11 - s2_i) : 6'(-s2_i);
      s1_eo  <= SINGLE ? 6'(8'sd31 - so_i) : 6'(-so_i);
      s1_mo  <= mo_i;
      s1_zpo <= zpo_i;
      s1_lo  <= min_i;
      s1_hi  <= max_i;
    end

  // Stage 2: each product's rounding right shift: RoundingDivideByPOT by -s (DOUBLE), (p + 2^(e - 1)) >>> e with e = 11 - s (SINGLE).
  always_ff @(posedge clk_i)
    if (v1) begin
      if (SINGLE) begin
        automatic logic signed [43:0] r1 = ($signed({{3{s1_p1[40]}}, s1_p1}) + (44'sd1 <<< (s1_e1 - 6'd1))) >>> s1_e1;
        automatic logic signed [43:0] r2 = ($signed({{3{s1_p2[40]}}, s1_p2}) + (44'sd1 <<< (s1_e2 - 6'd1))) >>> s1_e2;
        s2_a1 <= r1[31:0];
        s2_a2 <= r2[31:0];
      end else begin
        s2_a1 <= rdbpot(s1_p1[31:0], s1_e1[4:0]);
        s2_a2 <= rdbpot(s1_p2[31:0], s1_e2[4:0]);
      end
      s2_eo  <= s1_eo;
      s2_mo  <= s1_mo;
      s2_zpo <= s1_zpo;
      s2_lo  <= s1_lo;
      s2_hi  <= s1_hi;
    end

  // Stage 3: the sum, below 2^29 in magnitude, so 30 bits.
  always_ff @(posedge clk_i)
    if (v2) begin
      s3_sum <= 30'(s2_a1 + s2_a2);
      s3_eo  <= s2_eo;
      s3_mo  <= s2_mo;
      s3_zpo <= s2_zpo;
      s3_lo  <= s2_lo;
      s3_hi  <= s2_hi;
    end

  // Stage 4: the 30 x 32 product; DOUBLE takes SRDHM(sum, mo) = (sum mo + 2^30) >>> 31 (sum is never INT32_MIN, so no saturation).
  always_ff @(posedge clk_i)
    if (v3) begin
      automatic logic signed [61:0] p = s3_sum * s3_mo;
      s4_p   <= SINGLE ? p : ((p + 62'sd1073741824) >>> 31);
      s4_eo  <= s3_eo;
      s4_zpo <= s3_zpo;
      s4_lo  <= s3_lo;
      s4_hi  <= s3_hi;
    end

  // Stage 5: RoundingDivideByPOT by -so (DOUBLE), or (p + 2^(e - 1)) >>> e with e = 31 - so, then int32 (SINGLE).
  always_ff @(posedge clk_i)
    if (v4) begin
      if (SINGLE) begin
        automatic logic signed [63:0] r = ($signed({{2{s4_p[61]}}, s4_p}) + (64'sd1 <<< (s4_eo - 6'd1))) >>> s4_eo;
        s5_r <= r[31:0];
      end else s5_r <= rdbpot(s4_p[31:0], s4_eo[4:0]);
      s5_zpo <= s4_zpo;
      s5_lo  <= s4_lo;
      s5_hi  <= s4_hi;
    end

  // Stage 6: + zpo in int32, then max with min and min with max, TFLite's order.
  always_ff @(posedge clk_i)
    if (v5) begin
      automatic logic signed [31:0] y = s5_r + 32'(s5_zpo);
      if (y < 32'(s5_lo)) y = 32'(s5_lo);
      if (y > 32'(s5_hi)) y = 32'(s5_hi);
      result_o <= y[7:0];
    end

`ifndef SYNTHESIS
  logic s1_bad;  // stage 1 took a beat whose shifts lie outside [-31, 0]; only valid_i loads it, since a bubble's constants are don't-cares
  logic signed [7:0] s1_sh1, s1_sh2, s1_sho;  // that beat's shifts, for the message
  always_ff @(posedge clk_i)
    if (valid_i) begin
      s1_bad <= !((s1_i >= -8'sd31) && (s1_i <= 8'sd0) && (s2_i >= -8'sd31) && (s2_i <= 8'sd0) && (so_i >= -8'sd31) && (so_i <= 8'sd0));
      {s1_sh1, s1_sh2, s1_sho} <= {s1_i, s2_i, so_i};
    end
  // Checked on the stage-1 registers while v1 marks a real beat; rstn_i stays since v1 powers up random before the first reset edge (rs1_g1b_riseeds).
  always @(posedge clk_i)
    if (rstn_i && v1)
      assert (!s1_bad)
      else $error("tfliteAdd: shifts %0d, %0d, %0d outside [-31, 0]", s1_sh1, s1_sh2, s1_sho);
`endif

endmodule
