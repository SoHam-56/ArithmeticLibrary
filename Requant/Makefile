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
COMMON   = $(PRJ_DIR)/../Common
FLAGS    = --binary --timing --assert --sv -I$(TB_DIR) --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT --Wno-INITIALDLY -j $(shell nproc) --build-jobs 0 $(EXTRA_FLAGS)
GEN      = python3 $(TB_DIR)/gen_requant_vectors.py
V        = $(PRJ_DIR)/Verilator
# A simulation (1: command, 2: its log) fails the target unless it exits 0, prints RESULT: PASSED and prints no %Error or failed assertion (a simulator may carry on after $error); [f] and [E] keep make's echo of this line from matching, here and in regress.py's firing scan.
SIM      = set -o pipefail; $(1) | tee $(2) && command grep -q '^RESULT: PASSED' $(2) && ! command grep -qE '^(\[[0-9]+\] )?%[E]rror|Assertion [f]ailed' $(2) || { echo "TB_tfliteRequant: the simulation failed, printed an error or a failed assertion, or printed no RESULT: PASSED ($(2))"; exit 1; }

verilator:
	$(GEN) $(PRJ_DIR)/Verilator/vec_$(RLOW).txt --rounding $(ROUNDING) --random $(RANDOM)
	verilator $(FLAGS) -GROUNDING='"$(ROUNDING)"' --top-module TB_tfliteRequant --Mdir $(PRJ_DIR)/Verilator/$(RLOW) \
	  $(PKG) $(DESIGN) $(TB_DIR)/TB_tfliteRequant.sv -o sim
	$(call SIM,$(V)/$(RLOW)/sim +VEC=$(V)/vec_$(RLOW).txt $(PLUSARGS),$(V)/sim_vec_$(RLOW).log)

both:
	$(MAKE) verilator ROUNDING=DOUBLE
	$(MAKE) verilator ROUNDING=SINGLE

vivado_tb:
	for r in DOUBLE SINGLE; do l=$$(echo $$r | tr A-Z a-z); \
	  verilator $(FLAGS) -GROUNDING="\"$$r\"" --top-module TB_tfliteRequant --Mdir $(PRJ_DIR)/Verilator/viv_$$l \
	    $(PKG) $(DESIGN) $(TB_DIR)/TB_tfliteRequant.sv -o sim || exit 1; \
	  ($(call SIM,cd $(TB_DIR) && $(V)/viv_$$l/sim $(PLUSARGS),$(V)/sim_viv_$$l.log)) || exit 1; done

vectors:
	$(GEN) $(TB_DIR)/vectors_double.mem --rounding DOUBLE --random 10000
	$(GEN) $(TB_DIR)/vectors_single.mem --rounding SINGLE --random 10000

lint:
	bash $(COMMON)/lint.sh "lint tfliteRequant ROUNDING=DOUBLE" -Wall -Wno-fatal -DSYNTHESIS --top-module tfliteRequant -GROUNDING='"DOUBLE"' $(PKG) $(DESIGN)
	bash $(COMMON)/lint.sh "lint tfliteRequant ROUNDING=SINGLE" -Wall -Wno-fatal -DSYNTHESIS --top-module tfliteRequant -GROUNDING='"SINGLE"' $(PKG) $(DESIGN)

lint_bad:
	@verilator --lint-only -Wno-fatal -Werror-USERFATAL --top-module tfliteRequant -GROUNDING='"NEAREST"' $(PKG) $(DESIGN) \
	  > $(PRJ_DIR)/Verilator/lint_bad.txt 2>&1; rc=$$?; cat $(PRJ_DIR)/Verilator/lint_bad.txt; \
	  if grep -q "tfliteRequant: unsupported ROUNDING" $(PRJ_DIR)/Verilator/lint_bad.txt && [ $$rc -ne 0 ]; then echo REJECTED; \
	  else echo NOT-REJECTED; echo "RESULT: FAILED"; exit 1; fi

.PHONY: verilator both vivado_tb vectors lint lint_bad
