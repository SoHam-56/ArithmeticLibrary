`timescale 1ns / 100ps

// Float adder for EXP_W exponent and MAN_W mantissa bits: fp32Adder's algorithm, ports, flags and special values at any width.
// Aligns with three extra low bits, collapses shifts of MAN_W+3 or more into a single 1, normalizes by leading zeros, truncates.
// Subnormal inputs read as zero, underflow flushes to a signed zero, NaN is the canonical quiet NaN. valid_i at t, done_o at t+5.
// At (8, 23) it matches fp32Adder bit for bit, except that overflow_o stays low when a cancellation underflows (plan D-1).
module fpAdder #(
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
    output reg          overflow_o,
    output reg          underflow_o,
    output reg          invalid_o
);
  localparam int SIG_W = MAN_W + 1;
  localparam int GW = SIG_W + 3;  // aligned significand with three extra low bits
  localparam int SW = GW + 1;  // sum with its carry
  localparam int LW = $clog2(SW + 1);
  localparam int NW = EXP_W + 1;  // normalized exponent with a sign bit
  localparam int EMAX = (1 << EXP_W) - 1;
  localparam logic [EXP_W-1:0] ONES = '1;
  localparam logic [W-1:0] QNAN = {1'b0, ONES, 1'b1, {(MAN_W - 1) {1'b0}}};

  typedef struct packed {
    logic             inv;
    logic             nan;
    logic             inf;
    logic             zero;
    logic             bypass;  // exactly one operand is zero: the other passes through
    logic             sign;
    logic [EXP_W-1:0] exp;
    logic             sub;
  } meta_t;

  // Leading zeros of the sum; SW when it is zero.
  function automatic logic [LW-1:0] lzc(input logic [SW-1:0] x);
    lzc = LW'(SW);
    for (int i = 0; i < SW; i++) if (x[i]) lzc = LW'(SW - 1 - i);
  endfunction

  // Stage 1: unpack, classify, order the operands by magnitude.
  logic s1_v;
  logic [EXP_W-1:0] s1_diff;
  logic [SIG_W-1:0] s1_big, s1_small;
  meta_t s1_m;

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      s1_v     <= 1'b0;
      s1_diff  <= '0;
      s1_big   <= '0;
      s1_small <= '0;
      s1_m     <= '0;
    end else begin
      s1_v <= valid_i;
      if (valid_i) begin
        automatic logic [EXP_W-1:0] ea = A[W-2:MAN_W], eb = B[W-2:MAN_W];
        automatic logic za = (ea == '0), zb = (eb == '0);
        automatic logic [MAN_W-1:0] ma = za ? '0 : A[MAN_W-1:0], mb = zb ? '0 : B[MAN_W-1:0];
        automatic logic ia = (ea == ONES) && (A[MAN_W-1:0] == '0), ib = (eb == ONES) && (B[MAN_W-1:0] == '0);
        automatic logic na = (ea == ONES) && (A[MAN_W-1:0] != '0), nb = (eb == ONES) && (B[MAN_W-1:0] != '0);
        automatic logic snan = (na && !A[MAN_W-1]) || (nb && !B[MAN_W-1]);
        automatic logic inf_inf = ia && ib && (A[W-1] != B[W-1]);
        automatic logic a_ge = {ea, ma} >= {eb, mb};
        s1_m.inv    <= inf_inf || snan;
        s1_m.nan    <= na || nb || inf_inf;
        s1_m.inf    <= ia || ib;
        s1_m.zero   <= za && zb;
        s1_m.bypass <= za ^ zb;
        s1_m.sub    <= A[W-1] ^ B[W-1];
        s1_m.exp    <= a_ge ? ea : eb;
        s1_m.sign   <= a_ge ? A[W-1] : B[W-1];
        s1_big      <= a_ge ? {!za, ma} : {!zb, mb};
        s1_small    <= a_ge ? {!zb, mb} : {!za, ma};
        s1_diff     <= a_ge ? ea - eb : eb - ea;
      end
    end
  end

  // Stage 2: align the smaller significand.
  logic s2_v;
  logic [GW-1:0] s2_big, s2_small;
  meta_t s2_m;
  always_ff @(posedge clk_i or negedge rstn_i)
    if (!rstn_i) s2_v <= 1'b0;
    else s2_v <= s1_v;
  always_ff @(posedge clk_i)
    if (s1_v) begin
      s2_m   <= s1_m;
      s2_big <= {s1_big, 3'b000};
      if (s1_m.bypass) s2_small <= '0;
      else if (s1_diff >= EXP_W'(SIG_W + 2)) s2_small <= GW'(1);
      else s2_small <= {s1_small, 3'b000} >> s1_diff;
    end

  // Stage 3: add or subtract.
  logic s3_v;
  logic [SW-1:0] s3_sum;
  meta_t s3_m;
  always_ff @(posedge clk_i or negedge rstn_i)
    if (!rstn_i) s3_v <= 1'b0;
    else s3_v <= s2_v;
  always_ff @(posedge clk_i)
    if (s2_v) begin
      s3_m   <= s2_m;
      s3_sum <= s2_m.sub ? {1'b0, s2_big} - {1'b0, s2_small} : {1'b0, s2_big} + {1'b0, s2_small};
    end

  // Stage 4: count leading zeros.
  logic s4_v;
  logic [SW-1:0] s4_sum;
  logic [LW-1:0] s4_lz;
  meta_t s4_m;
  always_ff @(posedge clk_i or negedge rstn_i)
    if (!rstn_i) s4_v <= 1'b0;
    else s4_v <= s3_v;
  always_ff @(posedge clk_i)
    if (s3_v) begin
      s4_sum <= s3_sum;
      s4_m   <= s3_m;
      s4_lz  <= lzc(s3_sum);
      if (s3_sum == '0) s4_m.zero <= 1'b1;
    end

  // Normalize, in fp32Adder's order of cases.
  logic [SW-1:0] norm_man;
  logic [NW-1:0] norm_exp;
  always_comb begin
    norm_man = s4_sum;
    norm_exp = NW'(s4_m.exp);
    if (!s4_m.bypass) begin
      if (s4_sum[SW-1]) begin
        norm_man = s4_sum >> 1;
        norm_exp = NW'(s4_m.exp) + NW'(1);
      end else if (s4_lz == LW'(1)) norm_man = s4_sum;
      else if (s4_m.zero) begin
        norm_man = '0;
        norm_exp = '0;
      end else if (s4_lz > LW'(1)) begin
        norm_man = s4_sum << (s4_lz - LW'(1));
        norm_exp = NW'(s4_m.exp) - NW'(s4_lz - LW'(1));
      end
    end
  end

  logic neg, nonpos;
  assign neg    = norm_exp[NW-1];
  assign nonpos = neg || (norm_exp == '0);

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      result_o    <= '0;
      done_o      <= 1'b0;
      overflow_o  <= 1'b0;
      underflow_o <= 1'b0;
      invalid_o   <= 1'b0;
    end else begin
      done_o      <= s4_v;
      overflow_o  <= 1'b0;
      underflow_o <= 1'b0;
      invalid_o   <= 1'b0;
      if (s4_v) begin
        invalid_o  <= s4_m.inv;
        overflow_o <= !neg && (norm_exp >= NW'(EMAX)) && !s4_m.inf && !s4_m.nan;
        if (s4_m.nan) result_o <= QNAN;
        else if (s4_m.inf) result_o <= {s4_m.sign, ONES, {MAN_W{1'b0}}};
        else if (s4_m.zero) result_o <= {s4_m.sign, {(W - 1) {1'b0}}};
        else if (nonpos && !s4_m.bypass) begin
          result_o    <= {s4_m.sign, {(W - 1) {1'b0}}};
          underflow_o <= 1'b1;
        end else if (norm_exp >= NW'(EMAX)) result_o <= {s4_m.sign, ONES, {MAN_W{1'b0}}};
        else result_o <= {s4_m.sign, norm_exp[EXP_W-1:0], norm_man[GW-2-:MAN_W]};
      end
    end
  end

endmodule
