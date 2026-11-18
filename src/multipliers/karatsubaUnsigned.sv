`timescale 1ns / 100ps

module karatsubaUnsigned #(
    parameter WIDTH = 24
) (
    input logic clk_i,
    input logic rstn_i,

    input logic valid_i,
    input logic [WIDTH-1:0] multiplicand_i,
    input logic [WIDTH-1:0] multiplier_i,

    output logic valid_o,
    output logic [(2*WIDTH)-1:0] product_o
);

  localparam HALF_WIDTH = WIDTH / 2;
  localparam MID_WIDTH = HALF_WIDTH + 1;
  localparam int LO_W = HALF_WIDTH / 2;  // the half sums split here: a short low add, and the high add for either carry

  // Stage 1: the halves, delayed beside the middle term's sums.
  logic [HALF_WIDTH-1:0] A_high_d, A_low_d, B_high_d, B_low_d;
  logic [MID_WIDTH-1:0] sum_A, sum_B;
  logic s1_valid;
  // Stages 2 and 3: the three Booth products.
  logic [WIDTH-1:0] P_low_raw, P_high_raw;
  logic [WIDTH+1:0] P_middle_raw;
  logic mult_valid_out;
  logic unused_valid_1, unused_valid_2;
  // Stage 4: P_middle - P_high - P_low in carry-save form, mm_s + mm_c + 1 (the subtract P_middle - P_high alone was bf16's 1.17 ns ripple).
  logic [WIDTH+1:0] mm_s, mm_c;
  logic [WIDTH-1:0] P_low_d1, P_high_d1;
  logic s4_valid;
  // Stage 5: the middle term and the shifted high part.
  logic [WIDTH+1:0] middle_term_final;
  logic [(2*WIDTH)-1:0] P_high_shifted;
  logic [WIDTH-1:0] P_low_d2;
  logic s5_valid;

  // high + low as a carry select: no carry chain longer than half a half (the 12-bit add was a 1.13 ns ripple in the bf16 lane's tail multiplier)
  function automatic logic [MID_WIDTH-1:0] half_sum(input logic [HALF_WIDTH-1:0] h, input logic [HALF_WIDTH-1:0] l);
    logic [LO_W:0] lo;
    logic [HALF_WIDTH-LO_W:0] hi0, hi1;
    lo  = {1'b0, h[LO_W-1:0]} + {1'b0, l[LO_W-1:0]};
    hi0 = {1'b0, h[HALF_WIDTH-1:LO_W]} + {1'b0, l[HALF_WIDTH-1:LO_W]};
    hi1 = {1'b0, h[HALF_WIDTH-1:LO_W]} + {1'b0, l[HALF_WIDTH-1:LO_W]} + 1'b1;
    return {lo[LO_W] ? hi1 : hi0, lo[LO_W-1:0]};
  endfunction

  // =========================================================================
  // Stage 1: Pre-Computation & Alignment
  // =========================================================================
  // The middle term needs an adder (AH + AL). This takes 1 cycle.
  // We must delay the inputs for the High/Low multipliers by 1 cycle
  // so they stay synchronized with the middle term.
  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      A_high_d <= '0;
      A_low_d <= '0;
      B_high_d <= '0;
      B_low_d <= '0;
      sum_A    <= '0;
      sum_B   <= '0;
      s1_valid <= '0;
    end else begin
      // Pass valid bit forward
      s1_valid <= valid_i;

      // Path 1: Middle Term Pre-calculation (Adder)
      sum_A <= half_sum(multiplicand_i[WIDTH-1:HALF_WIDTH], multiplicand_i[HALF_WIDTH-1:0]);
      sum_B <= half_sum(multiplier_i[WIDTH-1:HALF_WIDTH], multiplier_i[HALF_WIDTH-1:0]);

      // Path 2: High/Low Terms (Delay only)
      // We register these simply to match the latency of the 'sum_A/sum_B' adders.
      A_high_d <= multiplicand_i[WIDTH-1:HALF_WIDTH];
      A_low_d <= multiplicand_i[HALF_WIDTH-1:0];
      B_high_d <= multiplier_i[WIDTH-1:HALF_WIDTH];
      B_low_d <= multiplier_i[HALF_WIDTH-1:0];
    end
  end

  // =========================================================================
  // Stage 2 & 3: Parallel Multiplication
  // =========================================================================
  // All 3 multipliers start here. They have fixed internal latency (PIPELINE_DEPTH).

  // Low Part
  R4Booth #(HALF_WIDTH) booth_low (
      .clk_i(clk_i),
      .rstn_i(rstn_i),
      .valid_i(s1_valid),
      .multiplicand(A_low_d),
      .multiplier(B_low_d),
      .valid_o(unused_valid_1),
      .product(P_low_raw)
  );

  // High Part
  R4Booth #(HALF_WIDTH) booth_high (
      .clk_i(clk_i),
      .rstn_i(rstn_i),
      .valid_i(s1_valid),
      .multiplicand(A_high_d),
      .multiplier(B_high_d),
      .valid_o(unused_valid_2),
      .product(P_high_raw)
  );

  // Middle Part
  R4Booth #(MID_WIDTH) booth_mid (
      .clk_i(clk_i),
      .rstn_i(rstn_i),
      .valid_i(s1_valid),
      .multiplicand(sum_A),
      .multiplier(sum_B),
      .valid_o(mult_valid_out),
      .product(P_middle_raw)
  );

  // =========================================================================
  // Stage 4: Post-Processing - Subtraction
  // =========================================================================
  // Karatsuba Formula: Middle_Term = P_middle - P_high - P_low
  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      mm_s <= '0;
      mm_c <= '0;
      P_low_d1 <= '0;
      P_high_d1 <= '0;
      s4_valid <= '0;
    end else begin
      s4_valid <= mult_valid_out;

      // Subtraction Step 1: P_middle + ~P_high + ~P_low + 2, one 3:2 level; one +1 rides in the carry word's free bit 0, the other in stage 5
      mm_s <= P_middle_raw ^ ~(WIDTH+2)'(P_high_raw) ^ ~(WIDTH+2)'(P_low_raw);
      mm_c <= {(P_middle_raw[WIDTH:0] & ~(WIDTH+1)'(P_high_raw)) | (P_middle_raw[WIDTH:0] & ~(WIDTH+1)'(P_low_raw)) |
               (~(WIDTH+1)'(P_high_raw) & ~(WIDTH+1)'(P_low_raw)), 1'b1};

      // Pipeline balancing: Delay P_low and P_high to match subtraction latency
      P_low_d1 <= P_low_raw;
      P_high_d1 <= P_high_raw;
    end
  end

  // =========================================================================
  // Stage 5: Post-Processing - Final Middle Term & Shifting
  // =========================================================================
  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      middle_term_final <= '0;
      P_high_shifted <= '0;
      P_low_d2 <= '0;
      s5_valid <= '0;
    end else begin
      s5_valid <= s4_valid;

      // Subtraction Step 2: the carry-save word's one add
      middle_term_final <= mm_s + mm_c + 1'b1;

      // Shift P_high by WIDTH (concatenation is free, but we register it)
      P_high_shifted <= {P_high_d1, {WIDTH{1'b0}}};

      // Delay P_low again
      P_low_d2 <= P_low_d1;
    end
  end

  // =========================================================================
  // Stage 6: Final Adder
  // =========================================================================
  // Result = (P_high << WIDTH) + (Middle << HALF_WIDTH) + P_low
  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      product_o <= '0;
      valid_o   <= '0;
    end else begin
      valid_o   <= s5_valid;

      // The middle term is shifted by HALF_WIDTH
      product_o <= P_high_shifted + (middle_term_final << HALF_WIDTH) + P_low_d2;
    end
  end

endmodule
