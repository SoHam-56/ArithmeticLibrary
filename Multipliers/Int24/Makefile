SHELL := /bin/bash
# int24Multiplier: verilator (its direct reference bench: the C reference of int_ref_core.h through DPI, corners and random pairs), mutant (a planted fault its bench must fail), lint (-Wall, must be clean: 0 warnings,
# 0 errors). make -C Fmt equiv checks its words and done cycles against intMultiplier #(24) on corners and 10^8 random pairs.
PRJ_DIR = $(shell pwd)
ARIL    = $(PRJ_DIR)/../..
COMMON  = $(ARIL)/Common
TB_DIR  = $(PRJ_DIR)/testbenches
PLUSARGS ?=
$(shell mkdir -p $(PRJ_DIR)/Verilator)  # Verilator makes --Mdir but not its parent
UNIT_SRC ?= $(PRJ_DIR)/src/int24Multiplier.sv  # the mutant target points it at a faulted copy
include $(COMMON)/sim.mk
BENCH_DIR ?= $(PRJ_DIR)/$(if $(filter vcs,$(SIM)),VCS,Verilator)/ref
DESIGN  = $(UNIT_SRC)
FLAGS   = --binary --timing --assert --sv +define+FMT_INT8 -I$(COMMON)/testbenches -I$(TB_DIR) \
          --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT --Wno-INITIALDLY -j $(shell nproc) --build-jobs 0 $(EXTRA_FLAGS)

verilator:
	verilator $(FLAGS) --top-module TB_int24Multiplier --Mdir $(BENCH_DIR) $(COMMON)/src/sienna_fmt_pkg.sv $(DESIGN) \
	  $(TB_DIR)/TB_int24Multiplier.sv $(COMMON)/testbenches/int_ref.cpp -CFLAGS "-I$(COMMON)/testbenches" -o sim
	cd $(BENCH_DIR) && ./sim $(PLUSARGS)

# the same bench on VCS (make vcs, or SIM=vcs through make regression): the DPI reference compiled in
vcs:
	$(call vcs_build,TB_int24Multiplier,$(BENCH_DIR),$(COMMON)/src/sienna_fmt_pkg.sv $(DESIGN) $(TB_DIR)/TB_int24Multiplier.sv $(COMMON)/testbenches/int_ref.cpp,+define+FMT_INT8 +incdir+$(COMMON)/testbenches +incdir+$(TB_DIR) -CFLAGS "-I$(COMMON)/testbenches")
	cd $(BENCH_DIR) && ./sim $(VCS_RUN) $(PLUSARGS)

# the planted fault of testbenches/mutant.sed against this bench: passes only when the bench fails
UNIT_MAKE = $(MAKE)  # a recipe line naming $(MAKE) would run under make -n
mutant:
	@bash $(COMMON)/unit_mutant.sh product_47_bits $(PRJ_DIR)/src/int24Multiplier.sv $(TB_DIR)/mutant.sed $(UNIT_MAKE) -s --no-print-directory $(if $(filter vcs,$(SIM)),vcs,verilator) SIM=$(SIM)

lint:
ifeq ($(SIM),vcs)
	$(call vcs_lint,int24Multiplier,int24Multiplier,$(DESIGN),+define+SYNTHESIS +define+FMT_INT8)
else
	bash $(COMMON)/lint.sh "lint int24Multiplier" -Wall -Wno-fatal -DSYNTHESIS --top-module int24Multiplier $(DESIGN)
endif

.PHONY: mutant verilator vcs lint
