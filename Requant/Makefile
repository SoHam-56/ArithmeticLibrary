SHELL := /bin/bash
# tfliteRequant: verilator (corners + RANDOM vectors from ipu.requant, one ROUNDING), both, vivado_tb (committed vectors), vectors, lint.
PRJ_DIR  = $(shell pwd)
TB_DIR   = $(PRJ_DIR)/testbenches
PLUSARGS ?=
ROUNDING ?= DOUBLE
RANDOM   ?= 1000000
$(shell mkdir -p $(PRJ_DIR)/Verilator)  # Verilator makes --Mdir but not its parent
RLOW     = $(shell echo $(ROUNDING) | tr A-Z a-z)
DESIGN   = $(PRJ_DIR)/src/tfliteRequant.sv
PKG      = $(PRJ_DIR)/../Common/src/sienna_fmt_pkg.sv
FLAGS    = --binary --timing --assert --sv -I$(TB_DIR) --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT --Wno-INITIALDLY $(EXTRA_FLAGS)
GEN      = python3 $(TB_DIR)/gen_requant_vectors.py

verilator:
	$(GEN) $(PRJ_DIR)/Verilator/vec_$(RLOW).txt --rounding $(ROUNDING) --random $(RANDOM)
	verilator $(FLAGS) -GROUNDING='"$(ROUNDING)"' --top-module TB_tfliteRequant --Mdir $(PRJ_DIR)/Verilator/$(RLOW) \
	  $(PKG) $(DESIGN) $(TB_DIR)/TB_tfliteRequant.sv -o sim
	$(PRJ_DIR)/Verilator/$(RLOW)/sim +VEC=$(PRJ_DIR)/Verilator/vec_$(RLOW).txt $(PLUSARGS)

both:
	$(MAKE) verilator ROUNDING=DOUBLE
	$(MAKE) verilator ROUNDING=SINGLE

vivado_tb:
	for r in DOUBLE SINGLE; do l=$$(echo $$r | tr A-Z a-z); \
	  verilator $(FLAGS) -GROUNDING="\"$$r\"" --top-module TB_tfliteRequant --Mdir $(PRJ_DIR)/Verilator/viv_$$l \
	    $(PKG) $(DESIGN) $(TB_DIR)/TB_tfliteRequant.sv -o sim || exit 1; \
	  (cd $(TB_DIR) && $(PRJ_DIR)/Verilator/viv_$$l/sim $(PLUSARGS)) || exit 1; done

vectors:
	$(GEN) $(TB_DIR)/vectors_double.mem --rounding DOUBLE --random 10000
	$(GEN) $(TB_DIR)/vectors_single.mem --rounding SINGLE --random 10000

lint:
	for r in DOUBLE SINGLE; do \
	  verilator --lint-only -Wall -Wno-fatal -DSYNTHESIS --top-module tfliteRequant -GROUNDING="\"$$r\"" $(PKG) $(DESIGN) || exit 1; done

lint_bad:
	verilator --lint-only -Wno-fatal -Werror-USERFATAL --top-module tfliteRequant -GROUNDING='"NEAREST"' $(PKG) $(DESIGN) \
	  > $(PRJ_DIR)/Verilator/lint_bad.txt 2>&1; rc=$$?; cat $(PRJ_DIR)/Verilator/lint_bad.txt; \
	  if grep -q "tfliteRequant: unsupported ROUNDING" $(PRJ_DIR)/Verilator/lint_bad.txt && [ $$rc -ne 0 ]; then echo REJECTED; \
	  else echo NOT-REJECTED; echo "RESULT: FAILED"; exit 1; fi

.PHONY: verilator both vivado_tb vectors lint lint_bad
