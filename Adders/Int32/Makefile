SHELL := /bin/bash
# int32Adder: verilator (its direct reference bench: the C reference of int_ref_core.h through DPI, wrap corners, carry chains and random pairs), mutant (a planted fault its bench must fail), lint (-Wall, must be clean: 0 warnings,
# 0 errors). make -C Fmt equiv checks its words and done cycles against intAdder #(32) on corners and 10^8 random pairs.
PRJ_DIR = $(shell pwd)
ARIL    = $(PRJ_DIR)/../..
COMMON  = $(ARIL)/Common
TB_DIR  = $(PRJ_DIR)/testbenches
PLUSARGS ?=
$(shell mkdir -p $(PRJ_DIR)/Verilator)  # Verilator makes --Mdir but not its parent
UNIT_SRC ?= $(PRJ_DIR)/src/int32Adder.sv  # the mutant target points it at a faulted copy
BENCH_DIR ?= $(PRJ_DIR)/Verilator/ref
DESIGN  = $(UNIT_SRC)
FLAGS   = --binary --timing --assert --sv +define+FMT_INT8 -I$(COMMON)/testbenches -I$(TB_DIR) \
          --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT --Wno-INITIALDLY -j $(shell nproc) --build-jobs 0 $(EXTRA_FLAGS)

verilator:
	verilator $(FLAGS) --top-module TB_int32Adder --Mdir $(BENCH_DIR) $(COMMON)/src/sienna_fmt_pkg.sv $(DESIGN) \
	  $(TB_DIR)/TB_int32Adder.sv $(COMMON)/testbenches/int_ref.cpp -CFLAGS "-I$(COMMON)/testbenches" -o sim
	cd $(BENCH_DIR) && ./sim $(PLUSARGS)

# the planted fault of testbenches/mutant.sed against this bench: passes only when the bench fails
UNIT_MAKE = $(MAKE)  # a recipe line naming $(MAKE) would run under make -n
mutant:
	@bash $(COMMON)/unit_mutant.sh carry_cut_at_16 $(PRJ_DIR)/src/int32Adder.sv $(TB_DIR)/mutant.sed $(UNIT_MAKE) -s --no-print-directory verilator

lint:
	bash $(COMMON)/lint.sh "lint int32Adder" -Wall -Wno-fatal -DSYNTHESIS --top-module int32Adder $(DESIGN)

.PHONY: mutant verilator lint
