SHELL := /bin/bash
# Common AriL checks: the format package, the fp32 units dumped for the Python model, the integer model ipu.py, and the credit link modules.
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

# Credit link: lint, then TB_credit_link built per (STAGES, MODE): modes 0 (STAGES 0, 1, 3) and 5 fire no assertion, modes 1-4 fire the named ones, 6-8 the named $fatal.
CREDIT_SRC  = $(PRJ_DIR)/src/credit_link_if.sv $(PRJ_DIR)/src/credit_counter.sv $(PRJ_DIR)/src/credit_reg.sv $(PRJ_DIR)/src/credit_link_checker.sv
CREDIT_CFGS = 0_0 1_0 3_0 0_1 0_2 0_3 0_4 0_5
CREDIT_RUNS = $(addprefix credit_run_,$(CREDIT_CFGS))
CREDIT_FATALS = $(addprefix credit_fatal_,6 7 8)
# expected assertions per mode; mode 4 must not trip the counter's own a_no_underflow
CREDIT_WANT_1 = a_no_underflow
CREDIT_WANT_2 = a_within_slots a_no_overflow
CREDIT_WANT_3 = a_all_back
CREDIT_WANT_4 = a_put_has_credit

credit: credit_lint $(CREDIT_RUNS) $(CREDIT_FATALS)

credit_lint:
	@w=0; e=0; for top in credit_counter credit_reg credit_link_checker; do \
	  verilator --lint-only -Wall -DSYNTHESIS --top-module $$top $(CREDIT_SRC) > $(PRJ_DIR)/Verilator/credit_lint_$$top.log 2>&1; \
	  w=$$((w + $$(command grep -c '^%Warning' $(PRJ_DIR)/Verilator/credit_lint_$$top.log))); \
	  e=$$((e + $$(command grep -c '^%Error' $(PRJ_DIR)/Verilator/credit_lint_$$top.log))); \
	done; \
	echo "credit lint: $$w warnings, $$e errors"; \
	[ $$w -eq 0 ] && [ $$e -eq 0 ] || { cat $(PRJ_DIR)/Verilator/credit_lint_*.log; exit 1; }

$(CREDIT_RUNS): credit_run_%:
	@s=$(word 1,$(subst _, ,$*)); m=$(word 2,$(subst _, ,$*)); d=$(PRJ_DIR)/Verilator/credit_s$${s}_m$${m}; rm -rf $$d; \
	verilator $(FLAGS) --top-module TB_credit_link -GSTAGES=$$s -GMODE=$$m --Mdir $$d $(CREDIT_SRC) $(TB_DIR)/TB_credit_link.sv -o sim > $$d.build.log 2>&1 \
	  || { echo "credit STAGES=$$s MODE=$$m: BUILD FAILED"; tail -20 $$d.build.log; exit 1; }; \
	$$d/sim +verilator+error+limit+100 > $$d.run.log 2>&1; \
	line=$$(command grep -m1 "^CREDIT_LINK STAGES=$$s MODE=$$m:" $$d.run.log); \
	res=$$(command grep -c "^RESULT: PASSED" $$d.run.log); \
	fails=$$(command grep -c "Assertion failed" $$d.run.log); \
	if [ $$m -eq 0 ] || [ $$m -eq 5 ]; then \
	  [ $$res -eq 1 ] && [ $$fails -eq 0 ] && echo "credit OK: $$line, 0 assertions fired" \
	    || { echo "credit FAIL: STAGES=$$s MODE=$$m: $$res PASSED lines, $$fails assertions fired"; tail -20 $$d.run.log; exit 1; }; \
	else \
	  want="$(CREDIT_WANT_$(word 2,$(subst _, ,$*)))"; ok=1; msg=""; \
	  for a in $$want; do n=$$(command grep -c "Assertion failed.*\.$$a:" $$d.run.log); msg="$$msg $$a x$$n"; [ $$n -ge 1 ] || ok=0; done; \
	  if [ $$m -eq 4 ]; then n=$$(command grep -c "Assertion failed.*\.a_no_underflow:" $$d.run.log); msg="$$msg a_no_underflow x$$n"; [ $$n -eq 0 ] || ok=0; fi; \
	  [ $$res -eq 1 ] && [ $$ok -eq 1 ] && echo "credit OK: $$line, fired:$$msg" \
	    || { echo "credit FAIL: STAGES=$$s MODE=$$m: $$res PASSED lines, fired:$$msg"; tail -20 $$d.run.log; exit 1; }; \
	fi

# expected $fatal per mode: 6 and 7 stop the build (elaboration), 8 stops the simulation at time 0
CREDIT_FATAL_6 = credit_counter: CRW
CREDIT_FATAL_7 = credit_counter: MAX 0 must be at least 1
CREDIT_FATAL_8 = credit_reg: DATA_W 31

$(CREDIT_FATALS): credit_fatal_%:
	@m=$*; d=$(PRJ_DIR)/Verilator/credit_fatal_m$$m; rm -rf $$d; want="$(CREDIT_FATAL_$*)"; \
	if verilator $(FLAGS) --top-module TB_credit_link -GMODE=$$m --Mdir $$d $(CREDIT_SRC) $(TB_DIR)/TB_credit_link.sv -o sim > $$d.build.log 2>&1; then \
	  $$d/sim > $$d.run.log 2>&1; log=$$d.run.log; else log=$$d.build.log; fi; \
	line=$$(command grep -m1 -F "$$want" $$log); \
	[ -n "$$line" ] && echo "credit OK: MODE=$$m fired: $$line" || { echo "credit FAIL: MODE=$$m: no '$$want'"; tail -20 $$log; exit 1; }

.PHONY: pkg dump32 ipu credit credit_lint $(CREDIT_RUNS) $(CREDIT_FATALS)
