SHELL := /bin/bash
# fpMultiplier: eq (fp32Multiplier at 8/23), verilator (SoftFloat, bf16), check (bf16 against fpu.py), vivado_tb, vectors.
PRJ_DIR = $(shell pwd)
ARIL    = $(PRJ_DIR)/../..
COMMON  = $(ARIL)/Common
TB_DIR  = $(PRJ_DIR)/testbenches
SF      = $(ARIL)/Adders/FP32/testbenches/berkeley-softfloat-3
SF_INC  = $(SF)/source/include
SF_LIB  = $(SF)/build/Linux-x86_64-GCC/softfloat.a
PLUSARGS ?=
$(shell mkdir -p $(PRJ_DIR)/Verilator)  # Verilator makes --Mdir but not its parent
DESIGN  = $(COMMON)/src/sienna_fmt_pkg.sv $(ARIL)/Multipliers/Radix4Booth/src/R4Booth.sv \
          $(ARIL)/Multipliers/Karatsuba/src/karatsubaUnsigned.sv $(PRJ_DIR)/src/fpMultiplier.sv
FLAGS   = --binary --timing --assert --sv -I$(COMMON)/testbenches -I$(TB_DIR) \
          --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT --Wno-INITIALDLY $(EXTRA_FLAGS)
BF16    = -GEXP_W=8 -GMAN_W=7

eq:
	verilator $(FLAGS) --top-module TB_fpMultiplierEq --Mdir $(PRJ_DIR)/Verilator/eq $(DESIGN) \
	  $(ARIL)/Multipliers/FP32/src/fp32Multiplier.sv $(TB_DIR)/TB_fpMultiplierEq.sv -o sim
	$(PRJ_DIR)/Verilator/eq/sim $(PLUSARGS)

verilator: $(SF_LIB)
	verilator $(FLAGS) $(BF16) --top-module TB_fpMultiplier --Mdir $(PRJ_DIR)/Verilator/sf $(DESIGN) \
	  $(TB_DIR)/TB_fpMultiplier.sv $(COMMON)/testbenches/fp_ref.cpp \
	  -CFLAGS "-I$(SF_INC) -I$(COMMON)/testbenches" -LDFLAGS "$(SF_LIB)" -o sim
	cd $(PRJ_DIR)/Verilator/sf && ./sim $(PLUSARGS)

check: verilator
	cd $(PRJ_DIR)/Verilator/sf && ./sim +DUMP=mul_bf16.txt
	python3 $(COMMON)/models/check_fpu.py $(PRJ_DIR)/Verilator/sf/mul_bf16.txt --unit mul --format bf16

vivado_tb:
	verilator $(FLAGS) $(BF16) --top-module TB_fpMultiplierVIVADO --Mdir $(PRJ_DIR)/Verilator/viv $(DESIGN) \
	  $(TB_DIR)/TB_fpMultiplierVIVADO.sv -o sim
	cd $(TB_DIR) && $(PRJ_DIR)/Verilator/viv/sim

vectors: $(SF_LIB)
	$(COMMON)/testbenches/generate_vectors.sh

lint:
	for f in "-GEXP_W=8 -GMAN_W=7" "-GEXP_W=8 -GMAN_W=23"; do \
	  verilator --lint-only -Wall -Wno-fatal -DSYNTHESIS --top-module fpMultiplier $$f $(DESIGN) || exit 1; done

$(SF_LIB):
	$(MAKE) -C $(SF)/build/Linux-x86_64-GCC

.PHONY: eq verilator check vivado_tb vectors lint
