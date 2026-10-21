`timescale 1ns / 100ps

// Equivalence tops: a per-format unit and the generic unit it replaces, side by side on the same inputs (results and done compared by eq_fmt.cpp).
module eq_bf16_mul (input logic clk_i, rstn_i, valid_i, input logic [15:0] a_i, b_i, output logic [15:0] result_new, result_generic, output logic done_new, done_generic);
  /* verilator lint_off PINCONNECTEMPTY */
  bf16Multiplier NEW (.clk_i, .rstn_i, .valid_i, .a_i(a_i), .b_i(b_i), .result_o(result_new), .done_o(done_new), .overflow_o(), .underflow_o(), .invalid_o());
  fpMultiplier #(.EXP_W(8), .MAN_W(7)) GEN (.clk_i, .rstn_i, .valid_i, .A(a_i), .B(b_i), .result_o(result_generic), .done_o(done_generic), .overflow_o(),
      .underflow_o(), .invalid_o());
  /* verilator lint_on PINCONNECTEMPTY */
endmodule

module eq_bf16_add (input logic clk_i, rstn_i, valid_i, input logic [15:0] a_i, b_i, output logic [15:0] result_new, result_generic, output logic done_new, done_generic);
  /* verilator lint_off PINCONNECTEMPTY */
  bf16Adder NEW (.clk_i, .rstn_i, .valid_i, .a_i(a_i), .b_i(b_i), .result_o(result_new), .done_o(done_new), .overflow_o(), .underflow_o(), .invalid_o());
  fpAdder #(.EXP_W(8), .MAN_W(7)) GEN (.clk_i, .rstn_i, .valid_i, .A(a_i), .B(b_i), .result_o(result_generic), .done_o(done_generic), .overflow_o(),
      .underflow_o(), .invalid_o());
  /* verilator lint_on PINCONNECTEMPTY */
endmodule

module eq_bf16_wide (input logic clk_i, rstn_i, valid_i, input logic [15:0] a_i, b_i, output logic [31:0] result_new, result_generic, output logic done_new, done_generic);
  /* verilator lint_off PINCONNECTEMPTY */
  bf16WideMultiplier NEW (.clk_i, .rstn_i, .valid_i, .a_i(a_i), .b_i(b_i), .result_o(result_new), .done_o(done_new), .overflow_o(), .underflow_o(), .invalid_o());
  fpMulWiden #(.EXP_W(8), .MAN_W(7)) GEN (.clk_i, .rstn_i, .valid_i, .A(a_i), .B(b_i), .result_o(result_generic), .done_o(done_generic), .overflow_o(),
      .underflow_o(), .invalid_o());
  /* verilator lint_on PINCONNECTEMPTY */
endmodule

module eq_bf16_narrow (input logic [31:0] x_i, output logic [15:0] result_new, result_generic);
  fp32ToBf16 NEW (.fp32_i(x_i), .bf16_o(result_new));
  fpNarrow #(.EXP_W(8), .MAN_W(7)) GEN (.x_i, .y_o(result_generic));
endmodule

// the copy gate, reversed: Soham's fp32 units against the generic units at (8, 23)
module eq_fp32_mul (input logic clk_i, rstn_i, valid_i, input logic [31:0] a_i, b_i, output logic [31:0] result_new, result_generic, output logic done_new, done_generic);
  /* verilator lint_off PINCONNECTEMPTY */
  fp32Multiplier NEW (.clk_i, .rstn_i, .valid_i, .A(a_i), .B(b_i), .result_o(result_new), .done_o(done_new), .overflow_o(), .underflow_o(), .invalid_o());
  fpMultiplier #(.EXP_W(8), .MAN_W(23)) GEN (.clk_i, .rstn_i, .valid_i, .A(a_i), .B(b_i), .result_o(result_generic), .done_o(done_generic), .overflow_o(),
      .underflow_o(), .invalid_o());
  /* verilator lint_on PINCONNECTEMPTY */
endmodule

module eq_fp32_add (input logic clk_i, rstn_i, valid_i, input logic [31:0] a_i, b_i, output logic [31:0] result_new, result_generic, output logic done_new, done_generic);
  /* verilator lint_off PINCONNECTEMPTY */
  fp32Adder NEW (.clk_i, .rstn_i, .valid_i, .A(a_i), .B(b_i), .result_o(result_new), .done_o(done_new), .overflow_o(), .underflow_o(), .invalid_o());
  fpAdder #(.EXP_W(8), .MAN_W(23)) GEN (.clk_i, .rstn_i, .valid_i, .A(a_i), .B(b_i), .result_o(result_generic), .done_o(done_generic), .overflow_o(),
      .underflow_o(), .invalid_o());
  /* verilator lint_on PINCONNECTEMPTY */
endmodule

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
