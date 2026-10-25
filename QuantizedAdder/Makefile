SHELL := /bin/bash
# int8QuantizedAdder: verilator (C reference through DPI: every (q1, q2) under the corner sets, then RANDOM rows; then the true function on the real ratios), shift_bad (a_shift_range fires), lint.
PRJ_DIR  = $(shell pwd)
ARIL     = $(PRJ_DIR)/..
COMMON   = $(ARIL)/Common
TB_DIR   = $(PRJ_DIR)/testbenches
PLUSARGS ?=
RANDOM   ?= 1000000
PYTHON   ?= python3
$(shell mkdir -p $(PRJ_DIR)/Verilator)  # Verilator makes --Mdir but not its parent
V        = $(PRJ_DIR)/Verilator
DESIGN   = $(COMMON)/src/sienna_fmt_pkg.sv $(PRJ_DIR)/src/int8QuantizedAdder.sv
FLAGS    = --binary --timing --assert --sv +define+FMT_INT8 -I$(TB_DIR) --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT --Wno-INITIALDLY -j $(shell nproc) --build-jobs 0 $(EXTRA_FLAGS)
GEN      = $(PYTHON) $(TB_DIR)/gen_quantized_adder_vectors.py
CHECK    = $(PYTHON) $(TB_DIR)/check_quantized_adder.py
BUILD    = verilator $(FLAGS) --top-module TB_int8QuantizedAdder --Mdir $(V)/ref $(DESIGN) $(TB_DIR)/TB_int8QuantizedAdder.sv \
           $(COMMON)/testbenches/int_ref.cpp -CFLAGS "-I$(COMMON)/testbenches" -o sim
# A simulation (1: command, 2: its log) fails the target unless it exits 0, prints RESULT: PASSED and prints no %Error or failed assertion (a simulator may carry on after $error); [f] and [E] keep make's echo of this line from matching, here and in regress.py's firing scan.
SIM      = set -o pipefail; $(1) | tee $(2) && command grep -q '^RESULT: PASSED' $(2) && ! command grep -qE '^(\[[0-9]+\] )?%[E]rror|Assertion [f]ailed' $(2) || { echo "TB_int8QuantizedAdder: the simulation failed, printed an error or a failed assertion, or printed no RESULT: PASSED ($(2))"; exit 1; }

verilator:
	$(GEN) $(V)/vec.txt --random $(RANDOM)
	$(BUILD)
	$(call SIM,$(V)/ref/sim +CONSTS=$(V)/vec.txt.consts +VEC=$(V)/vec.txt +DUMP=$(V)/dump.txt $(PLUSARGS),$(V)/sim_vec.log)
	$(CHECK) $(V)/dump.txt --vectors $(V)/vec.txt

# One row with shift MAX_SHIFT + 1: a_shift_range must fire.
shift_bad:
	@printf '0a 0a 00 00 80000000 80000000 2a 00 80 7f\n' > $(V)/vec_bad.txt
	@$(BUILD) > $(V)/build_bad.log 2>&1 || { cat $(V)/build_bad.log; echo NOT-FIRED; exit 1; }
	@$(V)/ref/sim +VEC=$(V)/vec_bad.txt > $(V)/sim_bad.txt 2>&1; cat $(V)/sim_bad.txt; \
	  if command grep -q "int8QuantizedAdder: shift 42 above 41" $(V)/sim_bad.txt; then echo FIRED; \
	  else echo NOT-FIRED; exit 1; fi

lint:
	bash $(COMMON)/lint.sh "lint int8QuantizedAdder" -Wall -Wno-fatal -DSYNTHESIS --top-module int8QuantizedAdder $(PRJ_DIR)/src/int8QuantizedAdder.sv
	bash $(COMMON)/lint.sh "lint int8QuantizedAdder (assertions)" -Wall -Wno-fatal --top-module int8QuantizedAdder $(PRJ_DIR)/src/int8QuantizedAdder.sv

.PHONY: verilator shift_bad lint
