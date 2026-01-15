`timescale 1ns / 100ps

module karatsubaSigned #(
    parameter WIDTH = 24
) (
    input logic                    clk_i,
    input logic                    rstn_i,
    input logic                    valid_i,
    input logic signed [WIDTH-1:0] a_i,      // Signed Input
    input logic signed [WIDTH-1:0] b_i,      // Signed Input

    output logic valid_o,
    output logic signed [(2*WIDTH)-1:0] product_o  // Signed Output
);

  // Calculate Absolute Values (1 cycle latency)
  logic signed [WIDTH-1:0] abs_a, abs_b;
  logic sign_a, sign_b;
  logic valid_s1;

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      abs_a <= '0;
      abs_b <= '0;
      sign_a <= 0;
      sign_b <= 0;
      valid_s1 <= 0;
    end else begin
      valid_s1 <= valid_i;

      // If input is negative, invert it; otherwise keep it.
      // Note: We handle the edge case of Min_Int slightly imperfectly here 
      sign_a <= a_i[WIDTH-1];
      sign_b <= b_i[WIDTH-1];

      abs_a <= (a_i[WIDTH-1]) ? -a_i : a_i;
      abs_b <= (b_i[WIDTH-1]) ? -b_i : b_i;
    end
  end

  logic unsigned_valid_o;
  logic [(2*WIDTH)-1:0] unsigned_product;

  karatsubaUnsigned #(WIDTH) u_core (
      .clk_i(clk_i),
      .rstn_i(rstn_i),
      .valid_i(valid_s1),
      .multiplicand_i(abs_a),
      .multiplier_i(abs_b),
      .valid_o(unsigned_valid_o),
      .product_o(unsigned_product)
  );

  // Delay the Sign Bit to match Core Latency
  localparam CORE_LATENCY = 6;
  logic [CORE_LATENCY-1:0] sign_delay_line;

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      sign_delay_line <= '0;
    end else begin
      // Shift register: XOR the signs (Negative if only one input is negative)
      sign_delay_line <= {sign_delay_line[CORE_LATENCY-2:0], (sign_a ^ sign_b)};
    end
  end

  logic final_sign_bit;
  assign final_sign_bit = sign_delay_line[CORE_LATENCY-1];

  // 4. Final Output Adjustment
  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      product_o <= '0;
      valid_o   <= 0;
    end else begin
      valid_o <= unsigned_valid_o;

      // If the final sign should be negative, negate the unsigned product
      if (final_sign_bit) product_o <= -($signed(unsigned_product));
      else product_o <= $signed(unsigned_product);
    end
  end

endmodule
