SHELL := /bin/bash
# bf16Multiplier: verilator (its direct reference bench: SoftFloat through DPI, 2 ulp, flags), mutant (a planted fault its bench must fail), lint (-Wall, must be clean: 0 warnings, 0 errors). make -C Fmt equiv proves its words and done
# cycles equal to fpMultiplier (8, 7).
PRJ_DIR = $(shell pwd)
ARIL    = $(PRJ_DIR)/../..
COMMON  = $(ARIL)/Common
TB_DIR  = $(PRJ_DIR)/testbenches
SF      = $(ARIL)/Adders/FP32/testbenches/berkeley-softfloat-3
SF_INC  = $(SF)/source/include
SF_LIB  = $(SF)/build/Linux-x86_64-GCC/softfloat.a
PLUSARGS ?=
$(shell mkdir -p $(PRJ_DIR)/Verilator)  # Verilator makes --Mdir but not its parent
UNIT_SRC ?= $(PRJ_DIR)/src/bf16Multiplier.sv  # the mutant target points it at a faulted copy
BENCH_DIR ?= $(PRJ_DIR)/Verilator/sf
DESIGN  = $(ARIL)/Multipliers/Radix4Booth/src/R4Booth.sv $(ARIL)/Multipliers/Karatsuba/src/karatsubaUnsigned.sv $(UNIT_SRC)
FLAGS   = --binary --timing --assert --sv +define+FMT_BF16 -I$(COMMON)/testbenches -I$(TB_DIR) \
          --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT --Wno-INITIALDLY -j $(shell nproc) --build-jobs 0 $(EXTRA_FLAGS)

verilator: $(SF_LIB)
	verilator $(FLAGS) --top-module TB_bf16Multiplier --Mdir $(BENCH_DIR) $(COMMON)/src/sienna_fmt_pkg.sv $(DESIGN) \
	  $(TB_DIR)/TB_bf16Multiplier.sv $(COMMON)/testbenches/fp_ref.cpp \
	  -CFLAGS "-I$(SF_INC) -I$(COMMON)/testbenches" -LDFLAGS "$(SF_LIB)" -o sim
	cd $(BENCH_DIR) && ./sim $(PLUSARGS)

# the planted fault of testbenches/mutant.sed against this bench: passes only when the bench fails
UNIT_MAKE = $(MAKE)  # a recipe line naming $(MAKE) would run under make -n
mutant:
	@bash $(COMMON)/unit_mutant.sh sign_of_a_only $(PRJ_DIR)/src/bf16Multiplier.sv $(TB_DIR)/mutant.sed $(UNIT_MAKE) -s --no-print-directory verilator

lint:
	bash $(COMMON)/lint.sh "lint bf16Multiplier" -Wall -Wno-fatal -DSYNTHESIS --top-module bf16Multiplier $(DESIGN)

$(SF_LIB):
	$(MAKE) -j$(shell nproc) -C $(SF)/build/Linux-x86_64-GCC

.PHONY: mutant verilator lint
