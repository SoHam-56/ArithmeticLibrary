# carry_exponent_kept: a carrying sum keeps its exponent, so it is halved (make bf16Adder-mutant must see its bench FAIL)
s/        normalized_exponent = NORMALIZED_EXPONENT_WIDTH'(s4_class.big_exponent) + NORMALIZED_EXPONENT_WIDTH'(1);/        normalized_exponent = NORMALIZED_EXPONENT_WIDTH'(s4_class.big_exponent);/
