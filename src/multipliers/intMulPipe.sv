`timescale 1ns / 100ps

// A pipelined two's-complement multiplier: one partial-product row per bit of b_i, a carry-save tree that leaves two rows, then one
// carry-propagate add. STAGES 2 registers the two rows after the whole tree; STAGES 3 registers the tree halfway as well, for wide
// operands (rows above 16: the tree alone is 7 or more levels). Bit-exact with a_i * b_i; the caller puts the narrower operand on b_i.
// Every operand bit is a signed bit at its width: an unsigned operand is passed zero-extended by one bit.
module intMulPipe #(
    parameter int AW     = 16,  // a_i's width, signed
    parameter int BW     = 16,  // b_i's width, signed: the rows
    parameter int STAGES = 2    // 2 or 3 cycles from valid_i to done_o
) (
    input  logic                  clk_i,
    input  logic                  rstn_i,
    input  logic                  valid_i,
    input  logic signed [AW-1:0]  a_i,
    input  logic signed [BW-1:0]  b_i,
    output logic signed [AW+BW-1:0] result_o,
    output logic                  done_o
);
  localparam int W = AW + BW;
  localparam int ROWS = BW;

  // rows_after(n, lv): rows left after lv carry-save levels; levels_of(n): levels that leave two.
  function automatic int rows_after(input int n, input int lv);
    for (int i = 0; i < lv; i++) n = 2 * (n / 3) + n % 3;
    return n;
  endfunction
  function automatic int levels_of(input int n);
    int l;
    l = 0;
    for (int i = 0; i < 64; i++) if (rows_after(n, i) > 2) l = i + 1;
    return l;
  endfunction
  localparam int LEVELS = levels_of(ROWS);
  localparam int L1 = (STAGES == 3) ? LEVELS / 2 : LEVELS;  // levels before the first register: the fewer half, as stage 1 also makes the rows (4 of 7 there was the int8 requantizer's 1.029 ns, POSTQ s1_mult -> MUL s1_q)
  localparam int MID = rows_after(ROWS, L1);  // rows registered there (2 at STAGES 2)

  // One carry-save level: every three rows become a sum row and a carry row, the rest pass. The level's row counts are constants.
  function automatic void csa_level(input int n, input logic [W-1:0] r[ROWS], output logic [W-1:0] t[ROWS]);
    for (int i = 0; i < ROWS; i++) t[i] = '0;
    for (int g = 0; g < n / 3; g++) begin
      t[2*g]   = r[3*g] ^ r[3*g+1] ^ r[3*g+2];
      t[2*g+1] = ((r[3*g] & r[3*g+1]) | (r[3*g] & r[3*g+2]) | (r[3*g+1] & r[3*g+2])) << 1;
    end
    for (int g = 3 * (n / 3); g < n; g++) t[2 * (n / 3) + g - 3 * (n / 3)] = r[g];
  endfunction

  // The rows: b_i[j] times a_i at weight 2^j, a_i sign-extended to W bits; the sign row is subtracted (its ones' complement here, plus one
  // in the final add), so two's-complement operands multiply exactly.
  logic [W-1:0] ax;
  logic [W-1:0] row[ROWS];
  // Stage 1: the tree's first L1 levels, registered (MID rows), and the sign row's extra one.
  logic [W-1:0] s1_c[ROWS];
  logic [W-1:0] s1_q[MID];
  logic         s1_neg;
  // The valid chain, and the two rows that reach the add with their extra one.
  logic [STAGES-1:0] v;
  logic [W-1:0] fs, fc;
  logic         fneg;

  if (STAGES != 2 && STAGES != 3) begin : G_BAD_STAGES
    $fatal(1, "intMulPipe: STAGES %0d, 2 or 3", STAGES);
  end
  if (AW < 2 || BW < 2) begin : G_BAD_WIDTH
    $fatal(1, "intMulPipe: AW %0d and BW %0d must be at least 2", AW, BW);
  end

  assign ax = W'(a_i);
  always_comb begin
    for (int j = 0; j < ROWS - 1; j++) row[j] = b_i[j] ? (ax << j) : '0;
    row[ROWS-1] = b_i[ROWS-1] ? ~(ax << (ROWS - 1)) : '0;
  end

  // Stage 1: L1 levels of the tree.
  always_comb begin
    automatic logic [W-1:0] r[ROWS];
    automatic logic [W-1:0] t[ROWS];
    for (int i = 0; i < ROWS; i++) r[i] = row[i];
    for (int lv = 0; lv < L1; lv++) begin
      csa_level(rows_after(ROWS, lv), r, t);
      for (int i = 0; i < ROWS; i++) r[i] = t[i];
    end
    for (int i = 0; i < ROWS; i++) s1_c[i] = (i < MID) ? r[i] : '0;
  end

  always_ff @(posedge clk_i or negedge rstn_i)
    if (!rstn_i) v <= '0;
    else v <= {v[STAGES-2:0], valid_i};
  assign done_o = v[STAGES-1];

  always_ff @(posedge clk_i)
    if (valid_i) begin
      for (int i = 0; i < MID; i++) s1_q[i] <= s1_c[i];
      s1_neg <= b_i[ROWS-1];
    end

  if (STAGES == 2) begin : G_TWO
    assign fs   = s1_q[0];
    assign fc   = s1_q[1];
    assign fneg = s1_neg;
  end else begin : G_THREE
    // Stage 2: the remaining levels, from MID rows to two.
    logic [W-1:0] s2_c[ROWS];
    logic [W-1:0] s2_q[2];
    logic         s2_neg;
    always_comb begin
      automatic logic [W-1:0] r[ROWS];
      automatic logic [W-1:0] t[ROWS];
      for (int i = 0; i < ROWS; i++) r[i] = (i < MID) ? s1_q[i] : '0;
      for (int lv = L1; lv < LEVELS; lv++) begin
        csa_level(rows_after(ROWS, lv), r, t);
        for (int i = 0; i < ROWS; i++) r[i] = t[i];
      end
      for (int i = 0; i < ROWS; i++) s2_c[i] = (i < 2) ? r[i] : '0;
    end
    always_ff @(posedge clk_i)
      if (v[0]) begin
        s2_q[0] <= s2_c[0];
        s2_q[1] <= s2_c[1];
        s2_neg  <= s1_neg;
      end
    assign fs   = s2_q[0];
    assign fc   = s2_q[1];
    assign fneg = s2_neg;
  end

  // Last stage: the carry-propagate add.
  always_ff @(posedge clk_i)
    if (v[STAGES-2]) result_o <= fs + fc + W'(fneg);

endmodule
