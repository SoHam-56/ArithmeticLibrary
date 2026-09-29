SHELL := /bin/bash
# intMultiplier: verilator (C reference through DPI, every int8 pair), check (against ipu.py), verilator16 / check16 (W = 16), vivado_tb, vectors, lint.
PRJ_DIR = $(shell pwd)
ARIL    = $(PRJ_DIR)/../..
COMMON  = $(ARIL)/Common
TB_DIR  = $(PRJ_DIR)/testbenches
PLUSARGS ?=
$(shell mkdir -p $(PRJ_DIR)/Verilator)  # Verilator makes --Mdir but not its parent
RTL     = $(PRJ_DIR)/src/intMultiplier.sv
DESIGN  = $(COMMON)/src/sienna_fmt_pkg.sv $(RTL)
FLAGS   = --binary --timing --assert --sv -I$(COMMON)/testbenches -I$(TB_DIR) \
          --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT --Wno-INITIALDLY $(EXTRA_FLAGS)

build:
	verilator $(FLAGS) --top-module TB_intMultiplier --Mdir $(PRJ_DIR)/Verilator/ref $(DESIGN) \
	  $(TB_DIR)/TB_intMultiplier.sv $(COMMON)/testbenches/int_ref.cpp -CFLAGS "-I$(COMMON)/testbenches" -o sim

verilator: build
	cd $(PRJ_DIR)/Verilator/ref && ./sim $(PLUSARGS)

check: build
	cd $(PRJ_DIR)/Verilator/ref && ./sim +DUMP=mul_int8.txt $(PLUSARGS)
	python3 $(COMMON)/models/check_ipu.py $(PRJ_DIR)/Verilator/ref/mul_int8.txt --unit mul --exhaustive

build16:
	verilator $(FLAGS) -GW=16 --top-module TB_intMultiplier --Mdir $(PRJ_DIR)/Verilator/ref16 $(DESIGN) \
	  $(TB_DIR)/TB_intMultiplier.sv $(COMMON)/testbenches/int_ref.cpp -CFLAGS "-I$(COMMON)/testbenches" -o sim

verilator16: build16
	cd $(PRJ_DIR)/Verilator/ref16 && ./sim $(PLUSARGS)

check16: build16
	cd $(PRJ_DIR)/Verilator/ref16 && ./sim +DUMP=mul_int16.txt $(PLUSARGS)
	python3 $(COMMON)/models/check_ipu.py $(PRJ_DIR)/Verilator/ref16/mul_int16.txt --unit mul16

vivado_tb:
	verilator $(FLAGS) --top-module TB_intMultiplierVIVADO --Mdir $(PRJ_DIR)/Verilator/viv $(DESIGN) \
	  $(TB_DIR)/TB_intMultiplierVIVADO.sv -o sim
	cd $(TB_DIR) && $(PRJ_DIR)/Verilator/viv/sim

vectors:
	$(COMMON)/testbenches/generate_int_vectors.sh

lint:
	for w in 8 16; do verilator --lint-only -Wall -Wno-fatal -DSYNTHESIS --top-module intMultiplier -GW=$$w $(RTL) || exit 1; done

.PHONY: build verilator check build16 verilator16 check16 vivado_tb vectors lint
