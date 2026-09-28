`timescale 1ns / 100ps

// Number formats a SIENNA build may use and the latencies of their AriL units; generate blocks reject any format not listed.
package sienna_fmt_pkg;

  // fp32: 8 exponent bits, 23 mantissa bits.
  function automatic bit is_fp32(input int exp_w, input int man_w);
    return (exp_w == 8) && (man_w == 23);
  endfunction

  // fp32 (fp32Multiplier, fp32Adder) and bf16 (fpMultiplier, fpAdder); nothing else is verified.
  function automatic bit supported(input int exp_w, input int man_w);
    return (exp_w == 8) && ((man_w == 23) || (man_w == 7));
  endfunction

  // valid_i to done_o: Karatsuba product (fp32Multiplier, fpMultiplier above 12 significand bits) 8, one-stage product 3.
  function automatic int mul_lat(input int exp_w, input int man_w);
    return (man_w + 1 > 12) ? 8 : 3;
  endfunction

  // valid_i to done_o: fp32Adder and fpAdder, 5 at every width.
  function automatic int add_lat(input int exp_w, input int man_w);
    return 5;
  endfunction

  // A finite fp32 constant in a format with 8 exponent bits, rounded to nearest even, right-aligned.
  function automatic logic [31:0] from_fp32(input logic [31:0] x, input int man_w);
    automatic int sh = 23 - man_w;
    if (sh == 0) return x;
    return (x + ((32'd1 << (sh - 1)) - 32'd1) + ((x >> sh) & 32'd1)) >> sh;
  endfunction

endpackage
