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

  // ---------------------------------------------------------
  // Pipeline Stage 1: Partial Product Generation
  // ---------------------------------------------------------
  logic [2*N-1:0] pp_reg[0:NUM_PP-1];
  logic valid_s1;

  // Signed helper signals
  logic signed [2*N-1:0] s_multiplicand;
  logic signed [2*N-1:0] s_multiplicand_x2;
  logic signed [2*N-1:0] s_multiplicand_neg;
  logic signed [2*N-1:0] s_multiplicand_x2_neg;

  // Sign extension
  assign s_multiplicand        = $signed({{(N) {1'b0}}, multiplicand});
  assign s_multiplicand_x2     = s_multiplicand << 1;
  assign s_multiplicand_neg    = -s_multiplicand;
  assign s_multiplicand_x2_neg = -s_multiplicand_x2;

  logic [2:0] triplet;
  logic signed [2*N-1:0] pp_comb;
  logic [N+2:0] multiplier_padded;

  assign multiplier_padded = {2'b00, multiplier, 1'b0};

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
  logic [(2*N)-1:0] sum_final;
  logic valid_s2;

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      sum_final <= '0;
      valid_s2  <= 0;
    end else begin
      valid_s2  <= valid_s1;

      // Sum all partial products
      sum_final <= '0;
      for (int k = 0; k < NUM_PP; k++) begin
        if (k == 0) sum_final <= pp_reg[k];
        else sum_final <= sum_final + pp_reg[k];
      end
    end
  end


  logic [(2*N)-1:0] adder_tree_comb;
  always_comb begin
    adder_tree_comb = '0;
    for (int k = 0; k < NUM_PP; k++) begin
      adder_tree_comb = adder_tree_comb + pp_reg[k];
    end
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
