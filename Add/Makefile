SHELL := /bin/bash
# tfliteAdd: verilator (corners, discriminators + RANDOM vectors from ipu.tflite_add, one ROUNDING), exhaustive (every (q1, q2) at the corner sets, checked by check_add.py), oracle (G0b's models, ORACLE=dir), both, vivado_tb (committed vectors), vectors, selftest, lint, lint_bad.
PRJ_DIR  = $(shell pwd)
TB_DIR   = $(PRJ_DIR)/testbenches
PLUSARGS ?=
ROUNDING ?= DOUBLE
RANDOM   ?= 1000000
VIV_RANDOM = 10000
ORACLE   ?=
PYTHON   ?= python3
$(shell mkdir -p $(PRJ_DIR)/Verilator)  # Verilator makes --Mdir but not its parent
RLOW     = $(shell echo $(ROUNDING) | tr A-Z a-z)
V        = $(PRJ_DIR)/Verilator
DESIGN   = $(PRJ_DIR)/src/tfliteAdd.sv
PKG      = $(PRJ_DIR)/../Common/src/sienna_fmt_pkg.sv
COMMON   = $(PRJ_DIR)/../Common
FLAGS    = --binary --timing --assert --sv -I$(TB_DIR) --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT --Wno-INITIALDLY -j $(shell nproc) --build-jobs 0 $(EXTRA_FLAGS)
GEN      = $(PYTHON) $(TB_DIR)/gen_add_vectors.py
CHECK    = $(PYTHON) $(TB_DIR)/check_add.py
BUILD    = verilator $(FLAGS) -GROUNDING='"$(ROUNDING)"' --top-module TB_tfliteAdd --Mdir $(V)/$(RLOW) $(PKG) $(DESIGN) $(TB_DIR)/TB_tfliteAdd.sv -o sim
# A simulation (1: command, 2: its log) fails the target unless it exits 0, prints RESULT: PASSED and prints no %Error or failed assertion (a simulator may carry on after $error); [f] and [E] keep make's echo of this line from matching, here and in regress.py's firing scan.
SIM      = set -o pipefail; $(1) | tee $(2) && command grep -q '^RESULT: PASSED' $(2) && ! command grep -qE '^(\[[0-9]+\] )?%[E]rror|Assertion [f]ailed' $(2) || { echo "TB_tfliteAdd: the simulation failed, printed an error or a failed assertion, or printed no RESULT: PASSED ($(2))"; exit 1; }

verilator:
	$(GEN) $(V)/vec_$(RLOW).txt --rounding $(ROUNDING) --random $(RANDOM)
	$(BUILD)
	$(call SIM,$(V)/$(RLOW)/sim +VEC=$(V)/vec_$(RLOW).txt +N=$$($(GEN) --count --random $(RANDOM)) $(PLUSARGS),$(V)/sim_vec_$(RLOW).log)

exhaustive:
	$(GEN) $(V)/consts_corners.txt --consts corners
	$(BUILD)
	$(call SIM,$(V)/$(RLOW)/sim +CONSTS=$(V)/consts_corners.txt +DUMP=$(V)/dump_corners_$(RLOW).txt +N=$$($(GEN) --count --consts corners) $(PLUSARGS),$(V)/sim_corners_$(RLOW).log)
	$(CHECK) $(V)/dump_corners_$(RLOW).txt --consts $(V)/consts_corners.txt --rounding $(ROUNDING)

oracle:
	@[ -n "$(ORACLE)" ] || { echo "make oracle needs ORACLE=<G0b output directory>"; echo "RESULT: FAILED"; exit 1; }
	$(GEN) $(V)/consts_oracle.txt --consts oracle --oracle $(ORACLE)
	$(BUILD)
	$(call SIM,$(V)/$(RLOW)/sim +CONSTS=$(V)/consts_oracle.txt +DUMP=$(V)/dump_oracle_$(RLOW).txt +N=$$($(GEN) --count --consts oracle --oracle $(ORACLE)) $(PLUSARGS),$(V)/sim_oracle_$(RLOW).log)
	$(CHECK) $(V)/dump_oracle_$(RLOW).txt --consts $(V)/consts_oracle.txt --rounding $(ROUNDING) --oracle $(ORACLE)

both:
	$(MAKE) verilator ROUNDING=DOUBLE
	$(MAKE) verilator ROUNDING=SINGLE
	$(MAKE) exhaustive ROUNDING=DOUBLE
	$(MAKE) exhaustive ROUNDING=SINGLE

vivado_tb:
	for r in DOUBLE SINGLE; do l=$$(echo $$r | tr A-Z a-z); \
	  verilator $(FLAGS) -GROUNDING="\"$$r\"" --top-module TB_tfliteAdd --Mdir $(V)/viv_$$l $(PKG) $(DESIGN) $(TB_DIR)/TB_tfliteAdd.sv -o sim || exit 1; \
	  ($(call SIM,cd $(TB_DIR) && $(V)/viv_$$l/sim +N=$$($(GEN) --count --random $(VIV_RANDOM)) $(PLUSARGS),$(V)/sim_viv_$$l.log)) || exit 1; done

vectors:
	$(GEN) $(TB_DIR)/vectors_double.mem --rounding DOUBLE --random $(VIV_RANDOM)
	$(GEN) $(TB_DIR)/vectors_single.mem --rounding SINGLE --random $(VIV_RANDOM)

selftest:
	$(CHECK) --selftest
	$(PYTHON) $(TB_DIR)/add_oracle.py --selftest

lint:
	bash $(COMMON)/lint.sh "lint tfliteAdd ROUNDING=DOUBLE" -Wall -Wno-fatal -DSYNTHESIS --top-module tfliteAdd -GROUNDING='"DOUBLE"' $(PKG) $(DESIGN)
	bash $(COMMON)/lint.sh "lint tfliteAdd ROUNDING=SINGLE" -Wall -Wno-fatal -DSYNTHESIS --top-module tfliteAdd -GROUNDING='"SINGLE"' $(PKG) $(DESIGN)

lint_bad:
	@verilator --lint-only -Wno-fatal -Werror-USERFATAL --top-module tfliteAdd -GROUNDING='"NEAREST"' $(PKG) $(DESIGN) \
	  > $(V)/lint_bad.txt 2>&1; rc=$$?; cat $(V)/lint_bad.txt; \
	  if command grep -q "tfliteAdd: unsupported ROUNDING" $(V)/lint_bad.txt && [ $$rc -ne 0 ]; then echo REJECTED; \
	  else echo NOT-REJECTED; echo "RESULT: FAILED"; exit 1; fi

.PHONY: verilator exhaustive oracle both vivado_tb vectors selftest lint lint_bad
