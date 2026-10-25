`timescale 1ns / 100ps

// Test-only tops for the parts of the library with no wrapper: the package functions fmt_greater_than and fmt_relu, and the units fp32ToBf16,
// int8Requantizer and int8QuantizedAdder at the build's define, with the port names TB_fmt and the sweep harness drive.
/* verilator lint_off DECLFILENAME */  // several test tops in one file
module fmt_fn_cmp
  import sienna_fmt_pkg::*;
(
    input  logic [DATA_WIDTH-1:0] a_i,
    input  logic [DATA_WIDTH-1:0] b_i,
    output logic              greater_o
);
  assign greater_o = fmt_greater_than(a_i, b_i);
endmodule

module fmt_fn_relu
  import sienna_fmt_pkg::*;
(
    input  logic [DATA_WIDTH-1:0] x_i,
    input  logic [DATA_WIDTH-1:0] zero_point_i,
    output logic [DATA_WIDTH-1:0] y_o
);
  assign y_o = fmt_relu(x_i, zero_point_i);
endmodule

`ifndef FMT_INT8
// the mesh reducer's narrow: fp32ToBf16 in bf16, the word passed through in fp32; not built in int8
module fmt_fn_narrow
  import sienna_fmt_pkg::*;
(
    input  logic [ACC_DATA_WIDTH-1:0] x_i,
    output logic [RESULT_DATA_WIDTH-1:0] y_o
);
`ifdef FMT_BF16
  fp32ToBf16 NARROW (.fp32_i(x_i), .bf16_o(y_o));
`else
  assign y_o = x_i;
`endif
endmodule

`endif

`ifdef FMT_INT8
// int8Requantizer on requant_params_t (int8 only)
module fmt_fn_requantize
  import sienna_fmt_pkg::*;
(
    input  logic                         clk_i,
    input  logic                         rstn_i,
    input  logic                         valid_i,
    input  logic [RESULT_DATA_WIDTH-1:0] x_i,
    input  requant_params_t              params_i,
    output logic [DATA_WIDTH-1:0]        y_o,
    output logic                         done_o
);
  int8Requantizer RQ (.clk_i(clk_i), .rstn_i(rstn_i), .valid_i(valid_i), .acc_i(x_i), .mult_i(params_i.mantissa), .shift_i(params_i.shift),
      .zp_i(params_i.zero_point), .act_min_i(params_i.act_min), .act_max_i(params_i.act_max), .result_o(y_o), .done_o(done_o));
endmodule

// int8QuantizedAdder on add_params_t (int8 only)
module fmt_fn_quantized_add
  import sienna_fmt_pkg::*;
(
    input  logic                  clk_i,
    input  logic                  rstn_i,
    input  logic                  valid_i,
    input  logic [DATA_WIDTH-1:0] a_i,
    input  logic [DATA_WIDTH-1:0] b_i,
    input  add_params_t           params_i,
    output logic [DATA_WIDTH-1:0] y_o,
    output logic                  done_o
);
  int8QuantizedAdder ADD (.clk_i(clk_i), .rstn_i(rstn_i), .valid_i(valid_i), .q1_i(a_i), .q2_i(b_i), .zp1_i(params_i.in1_zero_point),
      .zp2_i(params_i.in2_zero_point), .m1_i(params_i.in1_mantissa), .m2_i(params_i.in2_mantissa), .shift_i(params_i.shift),
      .zpo_i(params_i.out_zero_point), .act_min_i(params_i.act_min), .act_max_i(params_i.act_max), .result_o(y_o), .done_o(done_o));
endmodule
`endif
