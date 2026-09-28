SHELL := /bin/bash
# Common AriL checks: the format package, and the fp32 units dumped for the Python model.
PRJ_DIR = $(shell pwd)
ARIL    = $(PRJ_DIR)/..
TB_DIR  = $(PRJ_DIR)/testbenches
FLAGS   = --binary --timing --assert --sv -I$(TB_DIR) --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT --Wno-INITIALDLY $(EXTRA_FLAGS)
PLUSARGS ?=
$(shell mkdir -p $(PRJ_DIR)/Verilator)  # Verilator makes --Mdir but not its parent

pkg:
	verilator $(FLAGS) --top-module TB_sienna_fmt_pkg --Mdir $(PRJ_DIR)/Verilator/pkg $(PRJ_DIR)/src/sienna_fmt_pkg.sv $(TB_DIR)/TB_sienna_fmt_pkg.sv -o sim
	$(PRJ_DIR)/Verilator/pkg/sim

.PHONY: pkg
