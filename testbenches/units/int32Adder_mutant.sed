# carry_cut_at_16: the carry from bit 15 to 16 is lost (make int32Adder-mutant must see its bench FAIL)
s/result_o <= a_i + b_i;/result_o <= {a_i[31:16] + b_i[31:16], a_i[15:0] + b_i[15:0]};/
