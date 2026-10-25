# b_unsigned: b is zero-extended (make int8Multiplier-mutant must see its bench FAIL)
s/(2 \* DATA_WIDTH)'(b_i);/(2 * DATA_WIDTH)'($unsigned(b_i));/
