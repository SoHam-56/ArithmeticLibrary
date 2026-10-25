# ties_round_down: ties round down instead of to even (make fp32ToBf16-mutant must see its bench FAIL)
s/ + 32'((fp32_i >> DROPPED_MANTISSA_BITS) \& 32'd1)//
