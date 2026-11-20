`timescale 1ns / 100ps

module R4Booth #(
    parameter N = 12
) (
    input logic clk_i,
    input logic rstn_i,
    input logic valid_i,
    input logic [N-1:0] multiplicand,
    input logic [N-1:0] multiplier,

    output logic valid_o,
    output logic [(2*N)-1:0] product
);

  localparam NUM_PP = (N / 2) + 1;

  // Stage 1: the partial products, one per Booth triplet of the multiplier.
  logic [2*N-1:0] pp_reg[0:NUM_PP-1];
  logic valid_s1;
  // Signed helper signals
  logic signed [2*N-1:0] s_multiplicand;
  logic signed [2*N-1:0] s_multiplicand_x2;
  logic signed [2*N-1:0] s_multiplicand_neg;
  logic signed [2*N-1:0] s_multiplicand_x2_neg;
  logic [2:0] triplet;
  logic signed [2*N-1:0] pp_comb;
  logic [N+2:0] multiplier_padded;
  // Stage 2: the partial products' sum, a carry-save tree to two rows and one add (the chained adds were the fp32 lane's 0.947 ns at 0.8,
  // POST's booth_high pp_reg -> product). Every row is taken mod 2^(2N), as the chained sum was, so the product is the same.
  logic [(2*N)-1:0] adder_tree_comb;

  // ---------------------------------------------------------
  // Pipeline Stage 1: Partial Product Generation
  // ---------------------------------------------------------
  // Sign extension
  assign s_multiplicand        = $signed({{(N) {1'b0}}, multiplicand});
  assign s_multiplicand_x2     = s_multiplicand << 1;
  assign s_multiplicand_neg    = -s_multiplicand;
  assign s_multiplicand_x2_neg = -s_multiplicand_x2;
  assign multiplier_padded     = {2'b00, multiplier, 1'b0};

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      valid_s1 <= 0;
      for (int k = 0; k < NUM_PP; k++) pp_reg[k] <= '0;
    end else begin
      valid_s1 <= valid_i;

      for (int i = 0; i < NUM_PP; i++) begin
        triplet = multiplier_padded[(2*i)+:3];

        case (triplet)
          3'b000:  pp_comb = '0;
          3'b001:  pp_comb = s_multiplicand;
          3'b010:  pp_comb = s_multiplicand;
          3'b011:  pp_comb = s_multiplicand_x2;
          3'b100:  pp_comb = s_multiplicand_x2_neg;
          3'b101:  pp_comb = s_multiplicand_neg;
          3'b110:  pp_comb = s_multiplicand_neg;
          3'b111:  pp_comb = '0;
          default: pp_comb = '0;
        endcase

        // Register the shifted Partial Product
        pp_reg[i] <= pp_comb << (2 * i);
      end
    end
  end

  // ---------------------------------------------------------
  // Pipeline Stage 2: Summation (Adder Tree)
  // ---------------------------------------------------------
  // rows_after(lv): rows left after lv carry-save levels; LEVELS: the levels that leave two (constants, as in intMulPipe: a run-time row count
  // inside always_comb simulated wrongly in xsim 2025.2, sim_differences.log).
  function automatic int rows_after(input int lv);
    int n;
    n = NUM_PP;
    for (int i = 0; i < lv; i++) n = 2 * (n / 3) + n % 3;
    return n;
  endfunction
  function automatic int levels_of();  // rows_after's loop written out: DC will not evaluate a function call in a constant function (ELAB-425)
    int l, n;
    l = 0;
    n = NUM_PP;
    for (int i = 0; i < 16; i++) if (n > 2) begin
      n = 2 * (n / 3) + n % 3;
      l = i + 1;
    end
    return l;
  endfunction
  localparam int LEVELS = levels_of();
  localparam int LAST = rows_after(LEVELS);  // 2, or 1 when there is a single row
  // One carry-save level of n rows: every three become a sum row and a carry row, the rest pass on.
  function automatic void csa_level(input int n, input logic [2*N-1:0] r[NUM_PP], output logic [2*N-1:0] t[NUM_PP]);
    for (int k = 0; k < NUM_PP; k++) t[k] = '0;
    for (int g = 0; g < n / 3; g++) begin
      t[2*g]   = r[3*g] ^ r[3*g+1] ^ r[3*g+2];
      t[2*g+1] = ((r[3*g] & r[3*g+1]) | (r[3*g] & r[3*g+2]) | (r[3*g+1] & r[3*g+2])) << 1;
    end
    for (int g = 3 * (n / 3); g < n; g++) t[2*(n/3)+g-3*(n/3)] = r[g];
  endfunction
  always_comb begin
    automatic logic [2*N-1:0] r[NUM_PP];
    automatic logic [2*N-1:0] t[NUM_PP];
    for (int k = 0; k < NUM_PP; k++) r[k] = pp_reg[k];
    for (int lv = 0; lv < LEVELS; lv++) begin
      csa_level(rows_after(lv), r, t);
      for (int k = 0; k < NUM_PP; k++) r[k] = t[k];
    end
    adder_tree_comb = (LAST > 1) ? r[0] + r[1] : r[0];
  end

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      product <= '0;
      valid_o <= 0;
    end else begin
      product <= adder_tree_comb;
      valid_o <= valid_s1;
    end
  end

endmodule
