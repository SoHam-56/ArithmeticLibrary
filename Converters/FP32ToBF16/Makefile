SHELL := /bin/bash
# fp32ToBf16: check (its direct reference bench, round to nearest even on corners, every tie class and RANDOM values, then the dump against
# fpu.narrow), lint (-Wall, must be clean: 0 warnings, 0 errors). make -C Fmt equiv proved its words equal to fpNarrow (8, 7) on every fp32 word before fpNarrow left the library (acefcbc).
PRJ_DIR = $(shell pwd)
ARIL    = $(PRJ_DIR)/../..
COMMON  = $(ARIL)/Common
TB_DIR  = $(PRJ_DIR)/testbenches
RANDOM ?= 1000000
$(shell mkdir -p $(PRJ_DIR)/Verilator)  # Verilator makes --Mdir but not its parent
DESIGN  = $(UNIT_SRC)
FLAGS   = --binary --timing --assert --sv -I$(TB_DIR) --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT --Wno-INITIALDLY -j $(shell nproc) --build-jobs 0 $(EXTRA_FLAGS)
include $(COMMON)/sim.mk
V       = $(call sim_dir,$(PRJ_DIR))
UNIT_SRC ?= $(PRJ_DIR)/src/fp32ToBf16.sv  # the mutant target points it at a faulted copy
BENCH_DIR ?= $(V)/ref

check:
ifeq ($(SIM),vcs)
	$(call vcs_build,TB_fp32ToBf16,$(BENCH_DIR),$(DESIGN) $(TB_DIR)/TB_fp32ToBf16.sv,-pvalue+TB_fp32ToBf16.RANDOM=$(RANDOM) +incdir+$(TB_DIR))
else
	verilator $(FLAGS) -GRANDOM=$(RANDOM) --top-module TB_fp32ToBf16 --Mdir $(BENCH_DIR) $(DESIGN) $(TB_DIR)/TB_fp32ToBf16.sv -o sim
endif
	cd $(BENCH_DIR) && ./sim +DUMP=narrow_bf16.txt $(SIM_RUN) | tee run.log
	command grep -q "^RESULT: PASSED" $(BENCH_DIR)/run.log
	python3 $(COMMON)/models/check_fpu.py $(BENCH_DIR)/narrow_bf16.txt --unit narrow --format bf16

# the planted fault of testbenches/mutant.sed against this bench: passes only when the bench fails
UNIT_MAKE = $(MAKE)  # a recipe line naming $(MAKE) would run under make -n
mutant:
	@bash $(COMMON)/unit_mutant.sh ties_round_down $(PRJ_DIR)/src/fp32ToBf16.sv $(TB_DIR)/mutant.sed $(UNIT_MAKE) -s --no-print-directory check SIM=$(SIM)

lint:
ifeq ($(SIM),vcs)
	$(call vcs_lint,fp32ToBf16,fp32ToBf16,$(DESIGN),+define+SYNTHESIS)
else
	bash $(COMMON)/lint.sh "lint fp32ToBf16" -Wall -Wno-fatal -DSYNTHESIS --top-module fp32ToBf16 $(DESIGN)
endif

.PHONY: mutant check lint
