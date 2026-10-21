# b_unsigned: b is zero-extended (make -C Multipliers/Int8 mutant must see its bench FAIL)
s/(2 \* DATA_WIDTH)'(b_i);/(2 * DATA_WIDTH)'($unsigned(b_i));/
