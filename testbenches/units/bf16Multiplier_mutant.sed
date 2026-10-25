# sign_of_a_only: the product's sign is a's alone (make bf16Multiplier-mutant must see its bench FAIL)
s/        s1_class.sign <= a_i\[DATA_WIDTH-1\] ^ b_i\[DATA_WIDTH-1\];/        s1_class.sign <= a_i[DATA_WIDTH-1];/
