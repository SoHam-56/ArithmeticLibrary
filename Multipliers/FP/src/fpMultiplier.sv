`timescale 1ns / 100ps

// Float multiplier for EXP_W exponent and MAN_W mantissa bits: fp32Multiplier's algorithm, ports, flags and special values at any width.
// Truncates (the top MAN_W bits of the product); subnormal inputs read as zero, underflow flushes to a signed zero, overflow gives
// infinity, any NaN gives the canonical quiet NaN. At (8, 23) it matches fp32Multiplier bit for bit.
// valid_i at t, done_o at t+8 above 12 significand bits (Karatsuba, as fp32Multiplier), else t+3 (one-stage product).
module fpMultiplier #(
    parameter int EXP_W = 8,
    parameter int MAN_W = 7,
    parameter int W     = 1 + EXP_W + MAN_W
) (
    input  wire         clk_i,
    input  wire         rstn_i,
    input  wire         valid_i,
    input  wire [W-1:0] A,
    input  wire [W-1:0] B,
    output reg  [W-1:0] result_o,
    output reg          done_o,
    output reg          overflow_o,   // finite inputs, infinite result
    output reg          underflow_o,  // result flushed to zero
    output reg          invalid_o     // 0 * Inf, or a signaling NaN input
);
  localparam int SIG_W = MAN_W + 1;
  localparam int PW = 2 * SIG_W;
  localparam int BIAS = (1 << (EXP_W - 1)) - 1;
  localparam int EMAX = (1 << EXP_W) - 1;
  localparam int XW = EXP_W + 2;  // exponent sum
  localparam bit KARATSUBA = (SIG_W > 12);
  localparam int PROD_LAT = KARATSUBA ? 6 : 1;  // karatsubaUnsigned: valid_i at t, valid_o at t+6
  localparam logic [EXP_W-1:0] ONES = '1;
  localparam logic [W-1:0] QNAN = {1'b0, ONES, 1'b1, {(MAN_W - 1) {1'b0}}};

  // Integer formats have their own units (intMultiplier, intAdder, fxMac): an int8 build must never fall through to this one.
  if (EXP_W < 2) begin : G_BAD_FORMAT
    $fatal(1, "fpMultiplier: EXP_W=%0d is an integer format, not a float one", EXP_W);
  end

  typedef struct packed {
    logic          nan;
    logic          inv;
    logic          inf;
    logic          zero;
    logic          sign;
    logic [XW-1:0] sum;
  } meta_t;

  // Stage 1: classify, add the exponents, register the significands.
  logic s1_v;
  meta_t s1_m;
  logic [SIG_W-1:0] s1_sa, s1_sb;

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      s1_v  <= 1'b0;
      s1_m  <= '0;
      s1_sa <= '0;
      s1_sb <= '0;
    end else begin
      s1_v <= valid_i;
      if (valid_i) begin
        automatic logic [EXP_W-1:0] ea = A[W-2:MAN_W], eb = B[W-2:MAN_W];
        automatic logic zero_a = (ea == '0), zero_b = (eb == '0);
        automatic logic inf_a = (ea == ONES) && (A[MAN_W-1:0] == '0), inf_b = (eb == ONES) && (B[MAN_W-1:0] == '0);
        automatic logic nan_a = (ea == ONES) && (A[MAN_W-1:0] != '0), nan_b = (eb == ONES) && (B[MAN_W-1:0] != '0);
        automatic logic snan = (nan_a && !A[MAN_W-1]) || (nan_b && !B[MAN_W-1]);
        automatic logic inv = (zero_a && inf_b) || (inf_a && zero_b);
        s1_m.nan  <= nan_a || nan_b || inv;
        s1_m.inv  <= inv || snan;
        s1_m.inf  <= inf_a || inf_b;
        s1_m.zero <= zero_a || zero_b;
        s1_m.sign <= A[W-1] ^ B[W-1];
        s1_m.sum  <= XW'(ea) + XW'(eb);
        s1_sa     <= {1'b1, A[MAN_W-1:0]};
        s1_sb     <= {1'b1, B[MAN_W-1:0]};
      end
    end
  end

  // Significand product: Karatsuba for wide significands, one registered multiply for narrow ones.
  logic          prod_v;
  logic [PW-1:0] prod;
  if (KARATSUBA) begin : G_KARATSUBA
    karatsubaUnsigned #(
        .WIDTH(SIG_W)
    ) u_mul (
        .clk_i         (clk_i),
        .rstn_i        (rstn_i),
        .valid_i       (s1_v),
        .multiplicand_i(s1_sa),
        .multiplier_i  (s1_sb),
        .valid_o       (prod_v),
        .product_o     (prod)
    );
  end else begin : G_DIRECT
    always_ff @(posedge clk_i or negedge rstn_i) begin
      if (!rstn_i) begin
        prod_v <= 1'b0;
        prod   <= '0;
      end else begin
        prod_v <= s1_v;
        if (s1_v) prod <= PW'(s1_sa) * PW'(s1_sb);
      end
    end
  end

  // The classification travels beside the product.
  meta_t m_d[PROD_LAT];
  always_ff @(posedge clk_i) begin
    m_d[0] <= s1_m;
    for (int i = 1; i < PROD_LAT; i++) m_d[i] <= m_d[i-1];
  end
  meta_t m;
  assign m = m_d[PROD_LAT-1];

  // Range from the exponent sum, as fp32Multiplier's bias stage; normalize a product in [2, 4) by one place.
  logic top, ov_sum, under;
  logic [EXP_W-1:0] fexp;
  logic [MAN_W-1:0] fman;
  always_comb begin
    top    = prod[PW-1];
    ov_sum = (m.sum >= XW'(EMAX + BIAS));
    under  = (m.sum < XW'(BIAS)) || ((m.sum == XW'(BIAS)) && !top);
    fexp   = EXP_W'(m.sum - XW'(BIAS)) + EXP_W'(top);
    fman   = top ? prod[PW-2-:MAN_W] : prod[PW-3-:MAN_W];
  end

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      result_o    <= '0;
      done_o      <= 1'b0;
      overflow_o  <= 1'b0;
      underflow_o <= 1'b0;
      invalid_o   <= 1'b0;
    end else begin
      done_o      <= prod_v;
      overflow_o  <= 1'b0;
      underflow_o <= 1'b0;
      invalid_o   <= 1'b0;
      if (prod_v) begin
        invalid_o <= m.inv;
        if (m.nan) result_o <= QNAN;
        else if (m.inf) result_o <= {m.sign, ONES, {MAN_W{1'b0}}};
        else if (m.zero) result_o <= {m.sign, {(W - 1) {1'b0}}};
        else if (ov_sum) begin
          result_o   <= {m.sign, ONES, {MAN_W{1'b0}}};
          overflow_o <= 1'b1;
        end else if (under) begin
          result_o    <= {m.sign, {(W - 1) {1'b0}}};
          underflow_o <= 1'b1;
        end else if (fexp == ONES) begin
          result_o   <= {m.sign, ONES, {MAN_W{1'b0}}};
          overflow_o <= 1'b1;
        end else result_o <= {m.sign, fexp, fman};
      end
    end
  end

endmodule
