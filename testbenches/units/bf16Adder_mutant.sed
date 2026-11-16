# carry_exponent_kept: a carrying sum keeps its exponent, so it is halved (make bf16Adder-mutant must see its bench FAIL)
s/        normalized_exponent = s4_exponent_plus_one;/        normalized_exponent = NORMALIZED_EXPONENT_WIDTH'(s4_class.big_exponent);/
