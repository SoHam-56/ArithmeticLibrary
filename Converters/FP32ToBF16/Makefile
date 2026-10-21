SHELL := /bin/bash
# fp32ToBf16: check (its direct reference bench, round to nearest even on corners, every tie class and RANDOM values, then the dump against
# fpu.narrow), lint (-Wall, must be clean: 0 warnings, 0 errors). make -C Fmt equiv proves its words equal to fpNarrow (8, 7) on every fp32 word.
PRJ_DIR = $(shell pwd)
ARIL    = $(PRJ_DIR)/../..
COMMON  = $(ARIL)/Common
TB_DIR  = $(PRJ_DIR)/testbenches
RANDOM ?= 1000000
$(shell mkdir -p $(PRJ_DIR)/Verilator)  # Verilator makes --Mdir but not its parent
DESIGN  = $(PRJ_DIR)/src/fp32ToBf16.sv
FLAGS   = --binary --timing --assert --sv -I$(TB_DIR) --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT --Wno-INITIALDLY -j $(shell nproc) --build-jobs 0 $(EXTRA_FLAGS)
V       = $(PRJ_DIR)/Verilator

check:
	verilator $(FLAGS) -GRANDOM=$(RANDOM) --top-module TB_fp32ToBf16 --Mdir $(V)/ref $(DESIGN) $(TB_DIR)/TB_fp32ToBf16.sv -o sim
	cd $(V)/ref && ./sim +DUMP=narrow_bf16.txt | tee run.log
	command grep -q "^RESULT: PASSED" $(V)/ref/run.log
	python3 $(COMMON)/models/check_fpu.py $(V)/ref/narrow_bf16.txt --unit narrow --format bf16

lint:
	bash $(COMMON)/lint.sh "lint fp32ToBf16" -Wall -Wno-fatal -DSYNTHESIS --top-module fp32ToBf16 $(DESIGN)

.PHONY: check lint
