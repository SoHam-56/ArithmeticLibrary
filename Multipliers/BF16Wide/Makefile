SHELL := /bin/bash
# bf16WideMultiplier: verilator (its direct reference bench: SoftFloat's exact fp32 product through DPI, bit for bit, flags), lint (-Wall, must be clean: 0 warnings, 0 errors). make -C Fmt equiv proves its words and done
# cycles equal to fpMulWiden (8, 7).
PRJ_DIR = $(shell pwd)
ARIL    = $(PRJ_DIR)/../..
COMMON  = $(ARIL)/Common
TB_DIR  = $(PRJ_DIR)/testbenches
SF      = $(ARIL)/Adders/FP32/testbenches/berkeley-softfloat-3
SF_INC  = $(SF)/source/include
SF_LIB  = $(SF)/build/Linux-x86_64-GCC/softfloat.a
PLUSARGS ?=
$(shell mkdir -p $(PRJ_DIR)/Verilator)  # Verilator makes --Mdir but not its parent
DESIGN  = $(PRJ_DIR)/src/bf16WideMultiplier.sv
FLAGS   = --binary --timing --assert --sv +define+FMT_BF16 -I$(COMMON)/testbenches -I$(TB_DIR) \
          --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT --Wno-INITIALDLY -j $(shell nproc) --build-jobs 0 $(EXTRA_FLAGS)

verilator: $(SF_LIB)
	verilator $(FLAGS) --top-module TB_bf16WideMultiplier --Mdir $(PRJ_DIR)/Verilator/sf $(COMMON)/src/sienna_fmt_pkg.sv $(DESIGN) \
	  $(TB_DIR)/TB_bf16WideMultiplier.sv $(COMMON)/testbenches/fp_ref.cpp \
	  -CFLAGS "-I$(SF_INC) -I$(COMMON)/testbenches" -LDFLAGS "$(SF_LIB)" -o sim
	cd $(PRJ_DIR)/Verilator/sf && ./sim $(PLUSARGS)

lint:
	bash $(COMMON)/lint.sh "lint bf16WideMultiplier" -Wall -Wno-fatal -DSYNTHESIS --top-module bf16WideMultiplier $(DESIGN)

$(SF_LIB):
	$(MAKE) -j$(shell nproc) -C $(SF)/build/Linux-x86_64-GCC

.PHONY: verilator lint
