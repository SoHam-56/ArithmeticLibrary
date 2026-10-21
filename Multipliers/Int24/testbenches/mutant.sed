# product_47_bits: the product keeps 47 bits, sign-extended: only -2^23 x -2^23 = 2^46 changes (make -C Multipliers/Int24 mutant must see its bench FAIL)
s/result_o <= (2 \* DATA_WIDTH)'(a_i) \* (2 \* DATA_WIDTH)'(b_i);/result_o <= (2 * DATA_WIDTH)'($signed(47'((2 * DATA_WIDTH)'(a_i) * (2 * DATA_WIDTH)'(b_i))));/
