SHELL := /bin/bash
# Common AriL checks: the format package's define map per define, the fp32 units dumped for the Python model, the models fpu.py (narrow, widen) and ipu.py, the true-function gate truth.py, and the credit link modules.
PRJ_DIR = $(shell pwd)
ARIL    = $(PRJ_DIR)/..
TB_DIR  = $(PRJ_DIR)/testbenches
FLAGS   = --binary --timing --assert --sv -I$(TB_DIR) --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT --Wno-INITIALDLY -j $(shell nproc) --build-jobs 0 $(EXTRA_FLAGS)
PLUSARGS ?=
$(shell mkdir -p $(PRJ_DIR)/Verilator)  # Verilator makes --Mdir but not its parent
include $(PRJ_DIR)/sim.mk
# each simulator builds in its own tree
VDIR    = $(PRJ_DIR)/$(if $(filter vcs,$(SIM)),VCS,Verilator)

# the define map under each define (pkg_fp32 also with no define, which must be fp32): TB_sienna_fmt_map against the spec's table
UNIT_SRC ?= $(PRJ_DIR)/src/sienna_fmt_pkg.sv  # pkg_mutant points it at a faulted copy
define map_run
	verilator $(FLAGS) $(2) --top-module TB_sienna_fmt_map --Mdir $(or $(BENCH_DIR),$(PRJ_DIR)/Verilator/map_$(1)) $(UNIT_SRC) \
	  $(TB_DIR)/TB_sienna_fmt_map.sv -o sim
	$(or $(BENCH_DIR),$(PRJ_DIR)/Verilator/map_$(1))/sim
endef
define map_run_vcs
	$(call vcs_build,TB_sienna_fmt_map,$(or $(BENCH_DIR),$(VDIR)/map_$(1)),$(UNIT_SRC) $(TB_DIR)/TB_sienna_fmt_map.sv,$(2) +incdir+$(TB_DIR))
	$(or $(BENCH_DIR),$(VDIR)/map_$(1))/sim $(VCS_RUN)
endef
MAP_RUN = map_run$(if $(filter vcs,$(SIM)),_vcs)
pkg_fp32:
	$(call $(MAP_RUN),fp32,+define+FMT_FP32)
	$(call $(MAP_RUN),default,+define+NO_FMT_DEFINE)
pkg_bf16:
	$(call $(MAP_RUN),bf16,+define+FMT_BF16)
pkg_int8:
	$(call $(MAP_RUN),int8,+define+FMT_INT8)

# the planted fault of testbenches/pkg_mutant.sed (int8 RESULT_DATA_WIDTH 16) against TB_sienna_fmt_map: passes only when the bench fails
UNIT_MAKE = $(MAKE)  # a recipe line naming $(MAKE) would run under make -n
pkg_mutant:
	@bash $(PRJ_DIR)/unit_mutant.sh int8_result_width_16 $(PRJ_DIR)/src/sienna_fmt_pkg.sv $(TB_DIR)/pkg_mutant.sed $(UNIT_MAKE) -s --no-print-directory pkg_int8 SIM=$(SIM)

FP32_UNITS = $(ARIL)/Multipliers/Radix4Booth/src/R4Booth.sv $(ARIL)/Multipliers/Karatsuba/src/karatsubaUnsigned.sv \
             $(ARIL)/Multipliers/FP32/src/fp32Multiplier.sv $(ARIL)/Adders/FP32/src/LZC.sv $(ARIL)/Adders/FP32/src/fp32Adder.sv

dump32:
ifeq ($(SIM),vcs)
	$(call vcs_build,TB_fp32Dump,$(VDIR)/dump32,$(FP32_UNITS) $(TB_DIR)/TB_fp32Dump.sv,+incdir+$(TB_DIR))
	cd $(VDIR)/dump32 && ./sim $(VCS_RUN) $(PLUSARGS)
else
	verilator $(FLAGS) --top-module TB_fp32Dump --Mdir $(PRJ_DIR)/Verilator/dump32 $(FP32_UNITS) $(TB_DIR)/TB_fp32Dump.sv -o sim
	cd $(PRJ_DIR)/Verilator/dump32 && ./sim $(PLUSARGS)
endif
	python3 $(PRJ_DIR)/models/check_fpu.py $(VDIR)/dump32/mul32.txt --unit mul --format fp32
	python3 $(PRJ_DIR)/models/check_fpu.py $(VDIR)/dump32/add32.txt --unit add --format fp32 --fp32-unit

ipu:
	python3 $(PRJ_DIR)/models/test_ipu.py
	python3 $(PRJ_DIR)/models/fourstate.py --selftest
	python3 $(PRJ_DIR)/vcs_lint.py --selftest

fpu:
	python3 $(PRJ_DIR)/models/test_fpu.py

truth:
	python3 $(PRJ_DIR)/models/truth.py --selftest
	python3 $(PRJ_DIR)/models/test_truth.py

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
ifeq ($(SIM),vcs)
	@echo "credit lint: not applicable to VCS (verilator --lint-only -Wall; VCS's +lint=all is the lint points' job)"
else
	@w=0; e=0; for top in credit_counter credit_reg credit_link_checker; do \
	  verilator --lint-only -Wall -DSYNTHESIS --top-module $$top $(CREDIT_SRC) > $(PRJ_DIR)/Verilator/credit_lint_$$top.log 2>&1; \
	  w=$$((w + $$(command grep -c '^%Warning' $(PRJ_DIR)/Verilator/credit_lint_$$top.log))); \
	  e=$$((e + $$(command grep -c '^%Error' $(PRJ_DIR)/Verilator/credit_lint_$$top.log))); \
	done; \
	echo "credit lint: $$w warnings, $$e errors"; \
	[ $$w -eq 0 ] && [ $$e -eq 0 ] || { cat $(PRJ_DIR)/Verilator/credit_lint_*.log; exit 1; }
endif

# a firing assertion in either simulator's words (Verilator's 'Assertion failed in <scope>', VCS's '"<file>", <line>: <scope>: at time' or
# 'started at .. failed at'), and the line that names assertion $$a; [f] keeps make's echo from matching
CREDIT_FIRES = Assertion [f]ailed|^(Error|Fatal): "|: started at .* [f]ailed at
CREDIT_NAMED = Assertion [f]ailed.*\.$$a:|\.$$a: (at time|started at)
CREDIT_BUILD = $(if $(filter vcs,$(SIM)),$(call vcs_build,TB_credit_link,$$d,$(CREDIT_SRC) $(TB_DIR)/TB_credit_link.sv,$(1)),verilator $(FLAGS) --top-module TB_credit_link $(2) --Mdir $$d $(CREDIT_SRC) $(TB_DIR)/TB_credit_link.sv -o sim)

$(CREDIT_RUNS): credit_run_%:
	@s=$(word 1,$(subst _, ,$*)); m=$(word 2,$(subst _, ,$*)); d=$(VDIR)/credit_s$${s}_m$${m}; rm -rf $$d; mkdir -p $(VDIR); \
	$(call CREDIT_BUILD,-pvalue+TB_credit_link.STAGES=$$s -pvalue+TB_credit_link.MODE=$$m,-GSTAGES=$$s -GMODE=$$m) > $$d.build.log 2>&1 \
	  || { echo "credit STAGES=$$s MODE=$$m: BUILD FAILED"; tail -20 $$d.build.log; exit 1; }; \
	$$d/sim $(if $(filter vcs,$(SIM)),$(VCS_RUN),+verilator+error+limit+100) > $$d.run.log 2>&1; \
	line=$$(command grep -m1 "^CREDIT_LINK STAGES=$$s MODE=$$m:" $$d.run.log); \
	res=$$(command grep -c "^RESULT: PASSED" $$d.run.log); \
	fails=$$(command grep -cE '$(CREDIT_FIRES)' $$d.run.log); \
	if [ $$m -eq 0 ] || [ $$m -eq 5 ]; then \
	  [ $$res -eq 1 ] && [ $$fails -eq 0 ] && echo "credit OK: $$line, 0 assertions fired" \
	    || { echo "credit FAIL: STAGES=$$s MODE=$$m: $$res PASSED lines, $$fails assertions fired"; tail -20 $$d.run.log; exit 1; }; \
	else \
	  want="$(CREDIT_WANT_$(word 2,$(subst _, ,$*)))"; ok=1; msg=""; \
	  for a in $$want; do n=$$(command grep -cE "$(CREDIT_NAMED)" $$d.run.log); msg="$$msg $$a x$$n"; [ $$n -ge 1 ] || ok=0; done; \
	  if [ $$m -eq 4 ]; then a=a_no_underflow; n=$$(command grep -cE "$(CREDIT_NAMED)" $$d.run.log); msg="$$msg a_no_underflow x$$n"; [ $$n -eq 0 ] || ok=0; fi; \
	  [ $$res -eq 1 ] && [ $$ok -eq 1 ] && echo "credit OK: $$line, fired:$$msg" \
	    || { echo "credit FAIL: STAGES=$$s MODE=$$m: $$res PASSED lines, fired:$$msg"; tail -20 $$d.run.log; exit 1; }; \
	fi

# expected $fatal per mode: 6 and 7 stop the build (elaboration), 8 stops the simulation at time 0
CREDIT_FATAL_6 = credit_counter: CRW
CREDIT_FATAL_7 = credit_counter: MAX 0 must be at least 1
CREDIT_FATAL_8 = credit_reg: DATA_W 31

$(CREDIT_FATALS): credit_fatal_%:
	@m=$*; d=$(VDIR)/credit_fatal_m$$m; rm -rf $$d; mkdir -p $(VDIR); want="$(CREDIT_FATAL_$*)"; \
	if $(call CREDIT_BUILD,-pvalue+TB_credit_link.MODE=$$m,-GMODE=$$m) > $$d.build.log 2>&1; then \
	  $$d/sim $(if $(filter vcs,$(SIM)),$(VCS_RUN)) > $$d.run.log 2>&1; log=$$d.run.log; else log=$$d.build.log; fi; \
	line=$$(command grep -m1 -F "$$want" $$log); \
	[ -n "$$line" ] && echo "credit OK: MODE=$$m fired: $$line" || { echo "credit FAIL: MODE=$$m: no '$$want'"; tail -20 $$log; exit 1; }

.PHONY: pkg_fp32 pkg_bf16 pkg_int8 pkg_mutant dump32 ipu fpu truth credit credit_lint $(CREDIT_RUNS) $(CREDIT_FATALS)
