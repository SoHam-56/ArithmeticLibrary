SHELL := /bin/bash
# int8Requantizer: verilator (C reference through DPI on every row, then the true function on each row's real scale), shift_bad (a_shift_range fires), lint.
PRJ_DIR  = $(shell pwd)
ARIL     = $(PRJ_DIR)/..
COMMON   = $(ARIL)/Common
TB_DIR   = $(PRJ_DIR)/testbenches
PLUSARGS ?=
RANDOM   ?= 1000000
PYTHON   ?= python3
$(shell mkdir -p $(PRJ_DIR)/Verilator)  # Verilator makes --Mdir but not its parent
include $(COMMON)/sim.mk
V        = $(call sim_dir,$(PRJ_DIR))
$(shell mkdir -p $(V))
DESIGN   = $(COMMON)/src/sienna_fmt_pkg.sv $(PRJ_DIR)/src/int8Requantizer.sv
FLAGS    = --binary --timing --assert --sv +define+FMT_INT8 -I$(TB_DIR) --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT --Wno-INITIALDLY -j $(shell nproc) --build-jobs 0 $(EXTRA_FLAGS)
GEN      = $(PYTHON) $(TB_DIR)/gen_requantizer_vectors.py
CHECK    = $(PYTHON) $(TB_DIR)/check_requantizer.py
BUILD    = verilator $(FLAGS) --top-module TB_int8Requantizer --Mdir $(V)/ref $(DESIGN) $(TB_DIR)/TB_int8Requantizer.sv \
           $(COMMON)/testbenches/int_ref.cpp -CFLAGS "-I$(COMMON)/testbenches" -o sim
ifeq ($(SIM),vcs)
BUILD    = $(call vcs_build,TB_int8Requantizer,$(V)/ref,$(DESIGN) $(TB_DIR)/TB_int8Requantizer.sv $(COMMON)/testbenches/int_ref.cpp,+define+FMT_INT8 +incdir+$(TB_DIR) -CFLAGS "-I$(COMMON)/testbenches")
endif
# A simulation (1: command, 2: its log) fails the target unless it exits 0, prints RESULT: PASSED and prints no %Error or failed assertion (a simulator may carry on after $error); [f] and [E] keep make's echo of this line from matching, here and in regress.py's firing scan.
RUN_CHECKED = set -o pipefail; $(1) | tee $(2) && command grep -q '^RESULT: PASSED' $(2) && ! command grep -qE '^(\[[0-9]+\] )?%[E]rror|Assertion [f]ailed|^([E]rror|[F]atal): "|^[E]rror-\[' $(2) || { echo "TB_int8Requantizer: the simulation failed, printed an error or a failed assertion, or printed no RESULT: PASSED ($(2))"; exit 1; }

# make vcs is make verilator on VCS (sim.mk: a vcs goal sets SIM=vcs)
verilator vcs:
	$(GEN) $(V)/vec.txt --random $(RANDOM)
	$(BUILD)
	$(call RUN_CHECKED,$(V)/ref/sim $(SIM_RUN) +VEC=$(V)/vec.txt +DUMP=$(V)/dump.txt $(PLUSARGS),$(V)/sim_vec.log)
	$(CHECK) $(V)/dump.txt --vectors $(V)/vec.txt

# One row with shift MAX_SHIFT + 1: a_shift_range must fire, and only it.
shift_bad:
	@printf '00000064 800000 38 00 80 7f\n' > $(V)/vec_bad.txt
	@$(BUILD) > $(V)/build_bad.log 2>&1 || { cat $(V)/build_bad.log; echo NOT-FIRED; exit 1; }
	@$(V)/ref/sim $(SIM_RUN) +VEC=$(V)/vec_bad.txt > $(V)/sim_bad.txt 2>&1; cat $(V)/sim_bad.txt; \
	  if command grep -q "int8Requantizer: shift 56 above 55" $(V)/sim_bad.txt; then echo FIRED; \
	  else echo NOT-FIRED; exit 1; fi

lint:
ifeq ($(SIM),vcs)
	$(call vcs_lint,int8Requantizer,int8Requantizer,$(PRJ_DIR)/src/int8Requantizer.sv,+define+SYNTHESIS)
	$(call vcs_lint,int8Requantizer (assertions),int8Requantizer,$(PRJ_DIR)/src/int8Requantizer.sv,)
else
	bash $(COMMON)/lint.sh "lint int8Requantizer" -Wall -Wno-fatal -DSYNTHESIS --top-module int8Requantizer $(PRJ_DIR)/src/int8Requantizer.sv
	bash $(COMMON)/lint.sh "lint int8Requantizer (assertions)" -Wall -Wno-fatal --top-module int8Requantizer $(PRJ_DIR)/src/int8Requantizer.sv
endif

.PHONY: verilator vcs shift_bad lint
