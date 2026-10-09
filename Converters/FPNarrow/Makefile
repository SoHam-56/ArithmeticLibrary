SHELL := /bin/bash
# fpNarrow: check (bf16: corners, tie sweep, RANDOM LFSR values against fpu.narrow), check32 (fp32 identity), lint, bad_format (G_BAD_FORMAT fires), all.
PRJ_DIR = $(shell pwd)
ARIL    = $(PRJ_DIR)/../..
COMMON  = $(ARIL)/Common
TB_DIR  = $(PRJ_DIR)/testbenches
RANDOM ?= 1000000
$(shell mkdir -p $(PRJ_DIR)/Verilator)  # Verilator makes --Mdir but not its parent
DESIGN  = $(PRJ_DIR)/src/fpNarrow.sv
FLAGS   = --binary --timing --assert --sv -I$(TB_DIR) --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT --Wno-INITIALDLY $(EXTRA_FLAGS)
V       = $(PRJ_DIR)/Verilator

all: check check32 lint bad_format

# one format: build, dump, the TB's corner verdict, then every dumped value against fpu.narrow
define run_fmt
	verilator $(FLAGS) -GMAN_W=$(2) -GRANDOM=$(RANDOM) --top-module TB_fpNarrow --Mdir $(V)/$(1) $(DESIGN) $(TB_DIR)/TB_fpNarrow.sv -o sim
	cd $(V)/$(1) && ./sim +DUMP=narrow_$(1).txt | tee run.log
	command grep -q "^RESULT: PASSED" $(V)/$(1)/run.log
	python3 $(COMMON)/models/check_fpu.py $(V)/$(1)/narrow_$(1).txt --unit narrow --format $(1)
endef

check:
	$(call run_fmt,bf16,7)

check32:
	$(call run_fmt,fp32,23)

lint:
	@w=0; e=0; for m in 7 23; do \
	  verilator --lint-only -Wall -Wno-fatal -DSYNTHESIS --top-module fpNarrow -GMAN_W=$$m $(DESIGN) > $(V)/lint_$$m.log 2>&1; \
	  w=$$((w + $$(command grep -c '^%Warning' $(V)/lint_$$m.log))); e=$$((e + $$(command grep -c '^%Error' $(V)/lint_$$m.log))); \
	done; echo "fpNarrow lint (MAN_W 7, 23): $$w warnings, $$e errors"; cat $(V)/lint_*.log; [ $$e -eq 0 ]

# EXP_W 5 (fp16) must stop the build at G_BAD_FORMAT
bad_format:
	@rm -rf $(V)/bad; \
	if verilator $(FLAGS) -GEXP_W=5 -GMAN_W=10 --top-module TB_fpNarrow --Mdir $(V)/bad $(DESIGN) $(TB_DIR)/TB_fpNarrow.sv -o sim \
	  > $(V)/bad.build.log 2>&1; then echo "bad_format FAIL: EXP_W=5 built"; exit 1; fi; \
	line=$$(command grep -m1 -F "fpNarrow: EXP_W=5 MAN_W=10" $(V)/bad.build.log); \
	[ -n "$$line" ] && echo "bad_format OK: G_BAD_FORMAT fired: $$line" || { echo "bad_format FAIL: no G_BAD_FORMAT message"; cat $(V)/bad.build.log; exit 1; }

.PHONY: all check check32 lint bad_format
