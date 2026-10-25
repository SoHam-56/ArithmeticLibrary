# int8_result_width_16: int8's RESULT_DATA_WIDTH 16, not 32 (make common-pkg_mutant must see TB_sienna_fmt_map FAIL)
s/  localparam int RESULT_DATA_WIDTH = 32;  \/\/ mesh result word: int32, requantized at the lane feed/  localparam int RESULT_DATA_WIDTH = 16;  \/\/ mesh result word: int32, requantized at the lane feed/
