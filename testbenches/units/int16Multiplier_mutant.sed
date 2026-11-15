# b_sign_flipped: b's sign bit inverted on the way in (make int16Multiplier-mutant must see its bench FAIL)
s/\.b_i(b_i)/.b_i(b_i ^ 16'sh8000)/
