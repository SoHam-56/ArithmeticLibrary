`timescale 1ns / 100ps

// Number formats a SIENNA build may use and the latencies of their AriL units; generate blocks reject any format not listed.
package sienna_fmt_pkg;

  // fp32: 8 exponent bits, 23 mantissa bits.
  function automatic bit is_fp32(input int exp_w, input int man_w);
    return (exp_w == 8) && (man_w == 23);
  endfunction

  // Integer formats have no exponent: int8 is EXP_W = 0, MAN_W = 7, width 1 + 0 + 7.
  function automatic bit is_int(input int exp_w);
    return exp_w == 0;
  endfunction

  // fp32 (fp32Multiplier, fp32Adder), bf16 (fpMultiplier, fpAdder) and int8 (intMultiplier, intAdder); nothing else is verified.
  function automatic bit supported(input int exp_w, input int man_w);
    return ((exp_w == 8) && ((man_w == 23) || (man_w == 7))) || ((exp_w == 0) && (man_w == 7));
  endfunction

  // Width of partial sums, the reducer, the bias and the mesh result: int32 for int8, the format itself for floats.
  function automatic int acc_w(input int exp_w, input int man_w);
    return is_int(exp_w) ? 32 : 1 + exp_w + man_w;
  endfunction

  // valid_i to done_o: intMultiplier 1; Karatsuba product (fp32Multiplier, fpMultiplier above 12 significand bits) 8, else 3.
  function automatic int mul_lat(input int exp_w, input int man_w);
    if (is_int(exp_w)) return 1;
    return (man_w + 1 > 12) ? 8 : 3;
  endfunction

  // valid_i to done_o: intAdder 1; fp32Adder and fpAdder 5 at every width.
  function automatic int add_lat(input int exp_w, input int man_w);
    return is_int(exp_w) ? 1 : 5;
  endfunction

  // valid_i to done_o of fxMac, the int8 GPNAE lane's Q4.11 multiply-add.
  function automatic int fx_lat();
    return 2;
  endfunction

  // valid_i to done_o of tfliteRequant, TFLite's int8 requantize.
  function automatic int req_lat();
    return 3;
  endfunction

  // The rounding of TFLite's reference kernels, pinned at G0: SIENNA's testbenches/tflite_int8/rounding.txt.
  localparam string REQ_ROUNDING = "DOUBLE";

  // A finite fp32 constant in a format with 8 exponent bits, rounded to nearest even, right-aligned.
  function automatic logic [31:0] from_fp32(input logic [31:0] x, input int man_w);
    automatic int sh = 23 - man_w;
    if (sh == 0) return x;
    return (x + ((32'd1 << (sh - 1)) - 32'd1) + ((x >> sh) & 32'd1)) >> sh;
  endfunction

endpackage
