`timescale 1ns / 100ps

// Equivalence tops: a per-width integer unit and the generic unit it replaces, side by side on the same inputs (results and done compared by eq_fmt.cpp).
// the per-width integer units against the generic units at that width
module eq_int8_mul (input logic clk_i, rstn_i, valid_i, input logic [7:0] a_i, b_i, output logic [15:0] result_new, result_generic, output logic done_new, done_generic);
  int8Multiplier NEW (.clk_i, .rstn_i, .valid_i, .a_i(a_i), .b_i(b_i), .result_o(result_new), .done_o(done_new));
  intMultiplier #(.W(8)) GEN (.clk_i, .rstn_i, .valid_i, .A(a_i), .B(b_i), .result_o(result_generic), .done_o(done_generic));
endmodule

module eq_int16_mul (input logic clk_i, rstn_i, valid_i, input logic [15:0] a_i, b_i, output logic [31:0] result_new, result_generic, output logic done_new, done_generic);
  int16Multiplier NEW (.clk_i, .rstn_i, .valid_i, .a_i(a_i), .b_i(b_i), .result_o(result_new), .done_o(done_new));
  intMultiplier #(.W(16)) GEN (.clk_i, .rstn_i, .valid_i, .A(a_i), .B(b_i), .result_o(result_generic), .done_o(done_generic));
endmodule

module eq_int24_mul (input logic clk_i, rstn_i, valid_i, input logic [23:0] a_i, b_i, output logic [47:0] result_new, result_generic, output logic done_new, done_generic);
  int24Multiplier NEW (.clk_i, .rstn_i, .valid_i, .a_i(a_i), .b_i(b_i), .result_o(result_new), .done_o(done_new));
  intMultiplier #(.W(24)) GEN (.clk_i, .rstn_i, .valid_i, .A(a_i), .B(b_i), .result_o(result_generic), .done_o(done_generic));
endmodule

module eq_int32_add (input logic clk_i, rstn_i, valid_i, input logic [31:0] a_i, b_i, output logic [31:0] result_new, result_generic, output logic done_new, done_generic);
  int32Adder NEW (.clk_i, .rstn_i, .valid_i, .a_i(a_i), .b_i(b_i), .result_o(result_new), .done_o(done_new));
  intAdder #(.W(32)) GEN (.clk_i, .rstn_i, .valid_i, .A(a_i), .B(b_i), .result_o(result_generic), .done_o(done_generic));
endmodule
