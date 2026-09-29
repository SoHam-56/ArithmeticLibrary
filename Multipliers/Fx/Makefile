SHELL := /bin/bash
# fxMac: verilator (C reference through DPI), check (against ipu.py), sweep (exhaustive slice, ipu.py digest), vivado_tb, vectors, lint.
PRJ_DIR = $(shell pwd)
ARIL    = $(PRJ_DIR)/../..
COMMON  = $(ARIL)/Common
TB_DIR  = $(PRJ_DIR)/testbenches
PLUSARGS ?=
$(shell mkdir -p $(PRJ_DIR)/Verilator)  # Verilator makes --Mdir but not its parent
RTL     = $(PRJ_DIR)/src/fxMac.sv
DESIGN  = $(COMMON)/src/sienna_fmt_pkg.sv $(RTL)
FLAGS   = --binary --timing --assert --sv -I$(COMMON)/testbenches -I$(TB_DIR) \
          --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT --Wno-INITIALDLY $(EXTRA_FLAGS)

build:
	verilator $(FLAGS) --top-module TB_fxMac --Mdir $(PRJ_DIR)/Verilator/ref $(DESIGN) \
	  $(TB_DIR)/TB_fxMac.sv $(COMMON)/testbenches/int_ref.cpp -CFLAGS "-I$(COMMON)/testbenches" -o sim

verilator: build
	cd $(PRJ_DIR)/Verilator/ref && ./sim $(PLUSARGS)

check: build
	cd $(PRJ_DIR)/Verilator/ref && ./sim +DUMP=fx_q4_11.txt $(PLUSARGS)
	python3 $(COMMON)/models/check_ipu.py $(PRJ_DIR)/Verilator/ref/fx_q4_11.txt --unit fx

sweep: build
	cd $(PRJ_DIR)/Verilator/ref && ./sim $(PLUSARGS) +DIGEST=fx_digest.txt
	python3 $(COMMON)/models/check_ipu.py $(PRJ_DIR)/Verilator/ref/fx_digest.txt --digest

vivado_tb:
	verilator $(FLAGS) --top-module TB_fxMacVIVADO --Mdir $(PRJ_DIR)/Verilator/viv $(DESIGN) \
	  $(TB_DIR)/TB_fxMacVIVADO.sv -o sim
	cd $(TB_DIR) && $(PRJ_DIR)/Verilator/viv/sim

vectors:
	$(COMMON)/testbenches/generate_int_vectors.sh

lint:
	verilator --lint-only -Wall -Wno-fatal -DSYNTHESIS --top-module fxMac $(RTL)

.PHONY: build verilator check sweep vivado_tb vectors lint
