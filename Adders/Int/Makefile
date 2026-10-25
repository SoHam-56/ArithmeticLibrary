SHELL := /bin/bash
# intAdder: verilator (C reference through DPI: wrap corners, carry chains, random), check (against ipu.py), lint.
PRJ_DIR = $(shell pwd)
ARIL    = $(PRJ_DIR)/../..
COMMON  = $(ARIL)/Common
TB_DIR  = $(PRJ_DIR)/testbenches
PLUSARGS ?=
$(shell mkdir -p $(PRJ_DIR)/Verilator)  # Verilator makes --Mdir but not its parent
RTL     = $(PRJ_DIR)/src/intAdder.sv
DESIGN  = $(COMMON)/src/sienna_fmt_pkg.sv $(RTL)
FLAGS   = --binary --timing --assert --sv -I$(COMMON)/testbenches -I$(TB_DIR) \
          --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT --Wno-INITIALDLY -j $(shell nproc) --build-jobs 0 $(EXTRA_FLAGS)

build:
	verilator $(FLAGS) --top-module TB_intAdder --Mdir $(PRJ_DIR)/Verilator/ref $(DESIGN) \
	  $(TB_DIR)/TB_intAdder.sv $(COMMON)/testbenches/int_ref.cpp -CFLAGS "-I$(COMMON)/testbenches" -o sim

verilator: build
	cd $(PRJ_DIR)/Verilator/ref && ./sim $(PLUSARGS)

check: build
	cd $(PRJ_DIR)/Verilator/ref && ./sim +DUMP=add_int32.txt $(PLUSARGS)
	python3 $(COMMON)/models/check_ipu.py $(PRJ_DIR)/Verilator/ref/add_int32.txt --unit add

lint:
	bash $(COMMON)/lint.sh "lint intAdder" -Wall -Wno-fatal -DSYNTHESIS --top-module intAdder $(RTL)

.PHONY: build verilator check lint
