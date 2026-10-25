# a_unsigned: a is zero-extended (make -C Multipliers/Int16 mutant must see its bench FAIL)
s/result_o <= (2 \* DATA_WIDTH)'(a_i) \*/result_o <= (2 * DATA_WIDTH)'($unsigned(a_i)) */
