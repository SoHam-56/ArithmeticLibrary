SHELL := /bin/bash
# Common AriL checks: the format package, the fp32 units dumped for the Python model, and the integer model ipu.py.
PRJ_DIR = $(shell pwd)
ARIL    = $(PRJ_DIR)/..
TB_DIR  = $(PRJ_DIR)/testbenches
FLAGS   = --binary --timing --assert --sv -I$(TB_DIR) --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT --Wno-INITIALDLY $(EXTRA_FLAGS)
PLUSARGS ?=
$(shell mkdir -p $(PRJ_DIR)/Verilator)  # Verilator makes --Mdir but not its parent

pkg:
	verilator $(FLAGS) --top-module TB_sienna_fmt_pkg --Mdir $(PRJ_DIR)/Verilator/pkg $(PRJ_DIR)/src/sienna_fmt_pkg.sv $(TB_DIR)/TB_sienna_fmt_pkg.sv -o sim
	$(PRJ_DIR)/Verilator/pkg/sim

FP32_UNITS = $(ARIL)/Multipliers/Radix4Booth/src/R4Booth.sv $(ARIL)/Multipliers/Karatsuba/src/karatsubaUnsigned.sv \
             $(ARIL)/Multipliers/FP32/src/fp32Multiplier.sv $(ARIL)/Adders/FP32/src/LZC.sv $(ARIL)/Adders/FP32/src/fp32Adder.sv

dump32:
	verilator $(FLAGS) --top-module TB_fp32Dump --Mdir $(PRJ_DIR)/Verilator/dump32 $(FP32_UNITS) $(TB_DIR)/TB_fp32Dump.sv -o sim
	cd $(PRJ_DIR)/Verilator/dump32 && ./sim $(PLUSARGS)
	python3 $(PRJ_DIR)/models/check_fpu.py $(PRJ_DIR)/Verilator/dump32/mul32.txt --unit mul --format fp32
	python3 $(PRJ_DIR)/models/check_fpu.py $(PRJ_DIR)/Verilator/dump32/add32.txt --unit add --format fp32 --fp32-unit

ipu:
	python3 $(PRJ_DIR)/models/test_ipu.py

.PHONY: pkg dump32 ipu
