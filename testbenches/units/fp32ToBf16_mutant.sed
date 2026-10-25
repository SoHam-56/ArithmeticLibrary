# ties_round_down: ties round down instead of to even (make -C Converters/FP32ToBF16 mutant must see its bench FAIL)
s/ + 32'((fp32_i >> DROPPED_MANTISSA_BITS) \& 32'd1)//
