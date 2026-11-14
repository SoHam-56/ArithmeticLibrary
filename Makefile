SHELL := /bin/bash
# ArithmeticLibrary's one Makefile: every unit's benches as make <unit>-<target> (make help lists the units), and make regression's points and table.
ROOT    := $(CURDIR)
SRC     = $(ROOT)/src
TBU     = $(ROOT)/testbenches/units
TBT     = $(ROOT)/testbenches/top
SCRIPTS = $(ROOT)/scripts
MODELS  = $(ROOT)/models
PYTHON  ?= python3
PLUSARGS ?=
include $(ROOT)/scripts/fmt.mk
# SIM ?= verilator; SIM=vcs builds and runs every point VCS can run (scripts/sim.mk), the rest are listed as not applicable
include $(ROOT)/scripts/sim.mk
# each unit builds in Verilator/<unit> (VCS/<unit> under SIM=vcs); Verilator makes --Mdir but not its parent
UNITS   = common fmt bf16Adder fp32Adder intAdder int32Adder bf16Multiplier bf16WideMultiplier fp32Multiplier intMultiplier int8Multiplier \
          int16Multiplier int24Multiplier karatsuba fp32ToBf16 int8Requantizer int8QuantizedAdder
$(shell mkdir -p $(addprefix $(ROOT)/Verilator/,$(UNITS)) $(addprefix $(call sim_dir,$(ROOT))/,$(UNITS)))
unit_dir = $(call sim_dir,$(ROOT))/$(1)
REG_DIR ?= $(ROOT)/results/regression
REG_SUMMARY = $(PYTHON) regression.py --action summary --results $(REG_DIR) --sim $(SIM)
ifneq ($(filter regression,$(MAKECMDGOALS)),)
ifeq ($(origin REG_RUN),undefined)
REG_RUN := $(shell date +%Y%m%d-%H%M%S)-$(shell echo $$PPID)
endif
REG_POINTS := $(shell $(PYTHON) regression.py --action points)
endif
# SoftFloat, the float benches' reference, builds on first use: a fresh clone has only its sources, and softfloat.a is ignored
SF      = $(TBU)/berkeley-softfloat-3
SF_INC  = $(SF)/source/include
SF_LIB  = $(SF)/build/Linux-x86_64-GCC/softfloat.a
UNIT_MAKE = $(MAKE)  # a recipe line naming $(MAKE) would run under make -n
VFLAGS  = --binary --timing --assert --sv
VWNO    = --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT --Wno-INITIALDLY -j $(shell nproc) --build-jobs 0 $(EXTRA_FLAGS)
PKG     = $(SRC)/fmt/sienna_fmt_pkg.sv

default: help

help:
	@echo "=== ArithmeticLibrary ==="
	@echo "  FMT=fp32|bf16|int8 picks the number format (default fp32); OP=mul|add|cmp|relu narrows make verilator to one operation."
	@echo ""
	@echo "  make regression               - every unit's checks against the true function, one table"
	@echo "  make regression/<point>       - one point, e.g. regression/intAdder/check (python3 regression.py --action points lists them)"
	@echo "  make verilator [OP=op]        - the format wrappers' bench (TB_fmt) at FMT: every operation, or one"
	@echo "  make vcs [OP=op]              - the same on Synopsys VCS; SIM=vcs runs make regression on VCS (README: Running with VCS)"
	@echo "  make <unit>-verilator         - one unit's own bench (fp32Adder, fp32Multiplier and karatsuba also write a waveform: make <unit>-wave)"
	@echo "  make lint                     - Verilator lint of every format's tops"
	@echo "  make clean                    - remove the builds and logs"
	@echo "  Units: $(UNITS)"

# The format wrappers' bench at FMT: every TB_fmt point of that format, or those of one operation (OP).
FMT_OP_POINTS = $(if $(OP),$(filter fmt-$(OP)_%,$(call of_fmt,$(FMT))),fmt-all_$(FMT))
verilator:
	@[ -n "$(FMT_OP_POINTS)" ] || { echo "make verilator: no TB_fmt point for FMT=$(FMT) OP=$(OP) (OP is mul, add, cmp or relu)"; exit 1; }
	@$(MAKE) --no-print-directory $(FMT_OP_POINTS)

vcs:
	@$(MAKE) --no-print-directory verilator SIM=vcs

lint:
	@$(MAKE) --no-print-directory fmt-lint_tops
	@for f in FP32 BF16 INT8; do $(PYTHON) $(SCRIPTS)/declared_first.py --label "aril $$f" -D FMT_$$f -D SYNTHESIS $(FM_INC) $(FM_SRC) || exit 1; done

# One point: runs in a private copy of the tree, writes $(REG_DIR)/<point>.log and .json.
regression/%:
	@$(PYTHON) regression.py --action point --name $* --results $(REG_DIR) --sim $(SIM)$(if $(REG_RUN), --run $(REG_RUN))$(if $(filter regression,$(MAKECMDGOALS)), --keep-going)

regression: $(addprefix regression/,$(REG_POINTS))
	@$(REG_SUMMARY) --run $(REG_RUN)

regression-summary:
	@$(REG_SUMMARY)$(if $(REG_RUN), --run $(REG_RUN))

check-fmt:
	@$(MAKE) -s --no-print-directory fmt-check_fmt PYTHON=$(PYTHON)

exhaustive:
	@$(MAKE) --no-print-directory fmt-exhaustive FMT=$(FMT) PYTHON=$(PYTHON)

equiv:
	@$(MAKE) --no-print-directory fmt-equiv PYTHON=$(PYTHON)

$(SF_LIB):
	$(MAKE) -j$(shell nproc) -C $(SF)/build/Linux-x86_64-GCC

clean:
	rm -rf $(ROOT)/Verilator $(ROOT)/VCS $(ROOT)/results

.PHONY: default help verilator vcs lint regression regression-summary check-fmt exhaustive equiv clean

# ─────────────────────────────────────────────────────────────────────────────
# common: the format package's define map per define, the fp32 units dumped for the Python model, the models fpu.py (narrow, widen) and
# ipu.py, the true-function gate truth.py, and the credit link modules.
# ─────────────────────────────────────────────────────────────────────────────
CM_FLAGS = $(VFLAGS) -I$(TBU) $(VWNO)
CM_V     = $(call unit_dir,common)
CM_SRC   = $(or $(UNIT_SRC),$(PKG))  # common-pkg_mutant points it at a faulted copy

# the define map under each define (pkg_fp32 also with no define, which must be fp32): TB_sienna_fmt_map against the spec's table
define map_run
	verilator $(CM_FLAGS) $(2) --top-module TB_sienna_fmt_map --Mdir $(or $(BENCH_DIR),$(ROOT)/Verilator/common/map_$(1)) $(CM_SRC) \
	  $(TBU)/TB_sienna_fmt_map.sv -o sim
	$(or $(BENCH_DIR),$(ROOT)/Verilator/common/map_$(1))/sim
endef
define map_run_vcs
	$(call vcs_build,TB_sienna_fmt_map,$(or $(BENCH_DIR),$(CM_V)/map_$(1)),$(CM_SRC) $(TBU)/TB_sienna_fmt_map.sv,$(2) +incdir+$(TBU))
	$(or $(BENCH_DIR),$(CM_V)/map_$(1))/sim $(VCS_RUN)
endef
MAP_RUN = map_run$(if $(filter vcs,$(SIM)),_vcs)
common-pkg_fp32:
	$(call $(MAP_RUN),fp32,+define+FMT_FP32)
	$(call $(MAP_RUN),default,+define+NO_FMT_DEFINE)
common-pkg_bf16:
	$(call $(MAP_RUN),bf16,+define+FMT_BF16)
common-pkg_int8:
	$(call $(MAP_RUN),int8,+define+FMT_INT8)

# the planted fault of testbenches/units/pkg_mutant.sed (int8 RESULT_DATA_WIDTH 16) against TB_sienna_fmt_map: passes only when the bench fails
common-pkg_mutant:
	@bash $(SCRIPTS)/unit_mutant.sh int8_result_width_16 $(PKG) $(TBU)/pkg_mutant.sed $(UNIT_MAKE) -s --no-print-directory common-pkg_int8 SIM=$(SIM)

FP32_UNITS = $(SRC)/multipliers/R4Booth.sv $(SRC)/multipliers/karatsubaUnsigned.sv \
             $(SRC)/multipliers/fp32Multiplier.sv $(SRC)/adders/LZC.sv $(SRC)/adders/fp32Adder.sv

common-dump32:
ifeq ($(SIM),vcs)
	$(call vcs_build,TB_fp32Dump,$(CM_V)/dump32,$(FP32_UNITS) $(TBU)/TB_fp32Dump.sv,+incdir+$(TBU))
	cd $(CM_V)/dump32 && ./sim $(VCS_RUN) $(PLUSARGS)
else
	verilator $(CM_FLAGS) --top-module TB_fp32Dump --Mdir $(ROOT)/Verilator/common/dump32 $(FP32_UNITS) $(TBU)/TB_fp32Dump.sv -o sim
	cd $(ROOT)/Verilator/common/dump32 && ./sim $(PLUSARGS)
endif
	python3 $(MODELS)/check_fpu.py $(CM_V)/dump32/mul32.txt --unit mul --format fp32
	python3 $(MODELS)/check_fpu.py $(CM_V)/dump32/add32.txt --unit add --format fp32 --fp32-unit

common-ipu:
	python3 $(MODELS)/test_ipu.py
	python3 $(MODELS)/fourstate.py --selftest
	python3 $(SCRIPTS)/vcs_lint.py --selftest

common-fpu:
	python3 $(MODELS)/test_fpu.py

common-truth:
	python3 $(MODELS)/truth.py --selftest
	python3 $(MODELS)/test_truth.py

# Credit link: lint, then TB_credit_link built per (STAGES, MODE): modes 0 (STAGES 0, 1, 3) and 5 fire no assertion, modes 1-4 fire the named ones, 6-8 the named $fatal.
CREDIT_SRC  = $(SRC)/credit/credit_link_if.sv $(SRC)/credit/credit_counter.sv $(SRC)/credit/credit_reg.sv $(SRC)/credit/credit_link_checker.sv
CREDIT_CFGS = 0_0 1_0 3_0 0_1 0_2 0_3 0_4 0_5
CREDIT_RUNS = $(addprefix common-credit_run_,$(CREDIT_CFGS))
CREDIT_FATALS = $(addprefix common-credit_fatal_,6 7 8)
# expected assertions per mode; mode 4 must not trip the counter's own a_no_underflow
CREDIT_WANT_1 = a_no_underflow
CREDIT_WANT_2 = a_within_slots a_no_overflow
CREDIT_WANT_3 = a_all_back
CREDIT_WANT_4 = a_put_has_credit

common-credit: common-credit_lint $(CREDIT_RUNS) $(CREDIT_FATALS)

common-credit_lint:
ifeq ($(SIM),vcs)
	@echo "credit lint: not applicable to VCS (verilator --lint-only -Wall; VCS's +lint=all is the lint points' job)"
else
	@w=0; e=0; for top in credit_counter credit_reg credit_link_checker; do \
	  verilator --lint-only -Wall -DSYNTHESIS --top-module $$top $(CREDIT_SRC) > $(ROOT)/Verilator/common/credit_lint_$$top.log 2>&1; \
	  w=$$((w + $$(command grep -c '^%Warning' $(ROOT)/Verilator/common/credit_lint_$$top.log))); \
	  e=$$((e + $$(command grep -c '^%Error' $(ROOT)/Verilator/common/credit_lint_$$top.log))); \
	done; \
	echo "credit lint: $$w warnings, $$e errors"; \
	[ $$w -eq 0 ] && [ $$e -eq 0 ] || { cat $(ROOT)/Verilator/common/credit_lint_*.log; exit 1; }
endif

# a firing assertion in either simulator's words (Verilator's 'Assertion failed in <scope>', VCS's '"<file>", <line>: <scope>: at time' or
# 'started at .. failed at'), and the line that names assertion $$a; [f] keeps make's echo from matching
CREDIT_FIRES = Assertion [f]ailed|^(Error|Fatal): "|: started at .* [f]ailed at
CREDIT_NAMED = Assertion [f]ailed.*\.$$a:|\.$$a: (at time|started at)
CREDIT_BUILD = $(if $(filter vcs,$(SIM)),$(call vcs_build,TB_credit_link,$$d,$(CREDIT_SRC) $(TBU)/TB_credit_link.sv,$(1)),verilator $(CM_FLAGS) --top-module TB_credit_link $(2) --Mdir $$d $(CREDIT_SRC) $(TBU)/TB_credit_link.sv -o sim)

$(CREDIT_RUNS): common-credit_run_%:
	@s=$(word 1,$(subst _, ,$*)); m=$(word 2,$(subst _, ,$*)); d=$(CM_V)/credit_s$${s}_m$${m}; rm -rf $$d; mkdir -p $(CM_V); \
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

# Memory array: lint of both read kinds, TB_mem_array modes 0-2 against its model, mode 3's $fatal (a mask that does not divide the row).
MEM_SRC  = $(SRC)/mem/mem_array.sv
MEM_RUNS = $(addprefix common-mem_run_,0 1 2)
MEM_BUILD = $(if $(filter vcs,$(SIM)),$(call vcs_build,TB_mem_array,$$d,$(MEM_SRC) $(TBU)/TB_mem_array.sv,$(1)),verilator $(CM_FLAGS) --top-module TB_mem_array $(2) --Mdir $$d $(MEM_SRC) $(TBU)/TB_mem_array.sv -o sim)

common-mem: common-mem_lint $(MEM_RUNS) common-mem_fatal
	@echo "mem OK: 4 of 4 checks passed"

common-mem_lint:
ifeq ($(SIM),vcs)
	@echo "mem lint: not applicable to VCS (verilator --lint-only -Wall; VCS's +lint=all is the lint points' job)"
else
	@w=0; e=0; for cfg in "" "-GSYNC_READ=0 -GNW=3 -GNR=4 -GMASK_W=8"; do \
	  verilator --lint-only -Wall -DSYNTHESIS --top-module mem_array $$cfg $(MEM_SRC) > $(ROOT)/Verilator/common/mem_lint.log 2>&1; \
	  w=$$((w + $$(command grep -c '^%Warning' $(ROOT)/Verilator/common/mem_lint.log))); \
	  e=$$((e + $$(command grep -c '^%Error' $(ROOT)/Verilator/common/mem_lint.log))); \
	done; \
	echo "mem lint: $$w warnings, $$e errors"; \
	[ $$w -eq 0 ] && [ $$e -eq 0 ] || { cat $(ROOT)/Verilator/common/mem_lint.log; exit 1; }
endif

$(MEM_RUNS): common-mem_run_%:
	@m=$*; d=$(CM_V)/mem_m$$m; rm -rf $$d; mkdir -p $(CM_V); \
	$(call MEM_BUILD,-pvalue+TB_mem_array.MODE=$$m,-GMODE=$$m) > $$d.build.log 2>&1 \
	  || { echo "mem FAIL: MODE=$$m: BUILD FAILED"; tail -20 $$d.build.log; exit 1; }; \
	$$d/sim $(if $(filter vcs,$(SIM)),$(VCS_RUN)) > $$d.run.log 2>&1; \
	line=$$(command grep -m1 "^MEM_ARRAY MODE=$$m:" $$d.run.log); \
	[ $$(command grep -c "^RESULT: PASSED" $$d.run.log) -eq 1 ] && echo "mem run: $$line" || { echo "mem FAIL: MODE=$$m: $$line"; tail -20 $$d.run.log; exit 1; }

common-mem_fatal:
	@d=$(CM_V)/mem_fatal; rm -rf $$d; mkdir -p $(CM_V); want="mem_array: MASK_W 7 must divide WIDTH 32"; \
	if $(call MEM_BUILD,-pvalue+TB_mem_array.MODE=3,-GMODE=3) > $$d.build.log 2>&1; then \
	  $$d/sim $(if $(filter vcs,$(SIM)),$(VCS_RUN)) > $$d.run.log 2>&1; log=$$d.run.log; else log=$$d.build.log; fi; \
	line=$$(command grep -m1 -F "$$want" $$log); \
	[ -n "$$line" ] && echo "mem fatal: fired: $$line" || { echo "mem FAIL: MODE=3: no '$$want'"; tail -20 $$log; exit 1; }

# expected $fatal per mode: 6 and 7 stop the build (elaboration), 8 stops the simulation at time 0
CREDIT_FATAL_6 = credit_counter: CRW
CREDIT_FATAL_7 = credit_counter: MAX 0 must be at least 1
CREDIT_FATAL_8 = credit_reg: DATA_W 31

$(CREDIT_FATALS): common-credit_fatal_%:
	@m=$*; d=$(CM_V)/credit_fatal_m$$m; rm -rf $$d; mkdir -p $(CM_V); want="$(CREDIT_FATAL_$*)"; \
	if $(call CREDIT_BUILD,-pvalue+TB_credit_link.MODE=$$m,-GMODE=$$m) > $$d.build.log 2>&1; then \
	  $$d/sim $(if $(filter vcs,$(SIM)),$(VCS_RUN)) > $$d.run.log 2>&1; log=$$d.run.log; else log=$$d.build.log; fi; \
	line=$$(command grep -m1 -F "$$want" $$log); \
	[ -n "$$line" ] && echo "credit OK: MODE=$$m fired: $$line" || { echo "credit FAIL: MODE=$$m: no '$$want'"; tail -20 $$log; exit 1; }

.PHONY: common-pkg_fp32 common-pkg_bf16 common-pkg_int8 common-pkg_mutant common-dump32 common-ipu common-fpu common-truth common-credit \
        common-credit_lint $(CREDIT_RUNS) $(CREDIT_FATALS) common-mem common-mem_lint $(MEM_RUNS) common-mem_fatal

# ─────────────────────────────────────────────────────────────────────────────
# The per-format units' direct reference benches: <unit>-verilator (its bench against its C reference through DPI), <unit>-vcs (the same bench
# on VCS, the DPI reference compiled in), <unit>-mutant (testbenches/units/<unit>_mutant.sed, a planted fault its bench must fail), <unit>-lint
# (-Wall, must be clean: 0 warnings, 0 errors). make fmt-equiv proved the bf16 units' words and done cycles equal to the generic units (8, 7)
# before those left the library (acefcbc), and checks the integer units against intMultiplier and intAdder.
#   bf16Multiplier: SoftFloat, 2 ulp, flags; bf16Adder: SoftFloat, 3 ulp, flags; bf16WideMultiplier: SoftFloat's exact fp32 product, bit for bit,
#   flags; int8Multiplier: every pair; int16Multiplier, int24Multiplier: corners and random pairs; int32Adder: wrap corners, carry chains, random pairs.
# 1 unit, 2 its define, 3 the sources before it, 4 its reference (sf: SoftFloat's fp_ref.cpp, int: int_ref.cpp), 5 the build directory's name,
# 6 the mutant's name, 7 its src/ folder
# ─────────────────────────────────────────────────────────────────────────────
REF_CPP_sf  = $(TBU)/fp_ref.cpp
REF_CPP_int = $(TBU)/int_ref.cpp
REF_V_sf    = -CFLAGS "-I$(SF_INC) -I$(TBU)" -LDFLAGS "$(SF_LIB)"
REF_V_int   = -CFLAGS "-I$(TBU)"
REF_VCS_sf  = $(TBU)/fp_ref.cpp $(SF_LIB)
REF_VCS_int = $(TBU)/int_ref.cpp
REF_CF_sf   = -CFLAGS "-I$(SF_INC) -I$(TBU)"
REF_CF_int  = -CFLAGS "-I$(TBU)"
REF_DEP_sf  = $(SF_LIB)
REF_DEP_int =
define ref_bench
$(1)_DESIGN = $(3) $$(or $$(UNIT_SRC),$(SRC)/$(7)/$(1).sv)
$(1)_BENCH  = $$(or $$(BENCH_DIR),$(ROOT)/$$(if $$(filter vcs,$$(SIM)),VCS,Verilator)/$(1)/$(5))
$(1)_FLAGS  = $$(VFLAGS) +define+FMT_$(2) -I$$(TBU) $$(VWNO)

$(1)-verilator: $$(REF_DEP_$(4))
	verilator $$($(1)_FLAGS) --top-module TB_$(1) --Mdir $$($(1)_BENCH) $$(PKG) $$($(1)_DESIGN) \
	  $$(TBU)/TB_$(1).sv $$(REF_CPP_$(4)) $$(REF_V_$(4)) -o sim
	cd $$($(1)_BENCH) && ./sim $$(PLUSARGS)

$(1)-vcs: $$(REF_DEP_$(4))
	$$(call vcs_build,TB_$(1),$$($(1)_BENCH),$$(PKG) $$($(1)_DESIGN) $$(TBU)/TB_$(1).sv $$(REF_VCS_$(4)),+define+FMT_$(2) +incdir+$$(TBU) $$(REF_CF_$(4)))
	cd $$($(1)_BENCH) && ./sim $$(VCS_RUN) $$(PLUSARGS)

$(1)-mutant:
	@bash $$(SCRIPTS)/unit_mutant.sh $(6) $(SRC)/$(7)/$(1).sv $$(TBU)/$(1)_mutant.sed $$(UNIT_MAKE) -s --no-print-directory $$(if $$(filter vcs,$$(SIM)),$(1)-vcs,$(1)-verilator) SIM=$$(SIM)

$(1)-lint:
ifeq ($$(SIM),vcs)
	$$(call vcs_lint,$(1),$(1),$$($(1)_DESIGN),+define+SYNTHESIS +define+FMT_$(2))
else
	bash $$(SCRIPTS)/lint.sh "lint $(1)" -Wall -Wno-fatal -DSYNTHESIS --top-module $(1) $$($(1)_DESIGN)
endif

.PHONY: $(1)-verilator $(1)-vcs $(1)-mutant $(1)-lint
endef
BOOTH_KARATSUBA = $(SRC)/multipliers/R4Booth.sv $(SRC)/multipliers/karatsubaUnsigned.sv
$(eval $(call ref_bench,bf16Multiplier,BF16,$(BOOTH_KARATSUBA),sf,sf,sign_of_a_only,multipliers))
$(eval $(call ref_bench,bf16Adder,BF16,,sf,sf,carry_exponent_kept,adders))
$(eval $(call ref_bench,bf16WideMultiplier,BF16,,sf,sf,product_lsb_dropped,multipliers))
$(eval $(call ref_bench,int8Multiplier,INT8,,int,ref,b_unsigned,multipliers))
$(eval $(call ref_bench,int16Multiplier,INT8,,int,ref,a_unsigned,multipliers))
$(eval $(call ref_bench,int24Multiplier,INT8,,int,ref,product_47_bits,multipliers))
$(eval $(call ref_bench,int32Adder,INT8,,int,ref,carry_cut_at_16,adders))

# ─────────────────────────────────────────────────────────────────────────────
# The generic integer units: intAdder-verilator (C reference through DPI: wrap corners, carry chains, random), intAdder-check (against ipu.py),
# intAdder-lint; intMultiplier-verilator (C reference through DPI, every int8 pair), -check (against ipu.py), -verilator16 / -check16 (W = 16),
# -lint. intAdder-vcs, intMultiplier-vcs and intMultiplier-vcs16 are the same benches on VCS (sim.mk: a vcs goal sets SIM=vcs).
# ─────────────────────────────────────────────────────────────────────────────
INT_FLAGS = $(VFLAGS) -I$(TBU) $(VWNO)
IA_V      = $(call unit_dir,intAdder)
IA_RTL    = $(SRC)/adders/intAdder.sv

intAdder-build:
ifeq ($(SIM),vcs)
	$(call vcs_build,TB_intAdder,$(IA_V)/ref,$(PKG) $(IA_RTL) $(TBU)/TB_intAdder.sv $(TBU)/int_ref.cpp,+incdir+$(TBU) -CFLAGS "-I$(TBU)")
else
	verilator $(INT_FLAGS) --top-module TB_intAdder --Mdir $(ROOT)/Verilator/intAdder/ref $(PKG) $(IA_RTL) \
	  $(TBU)/TB_intAdder.sv $(TBU)/int_ref.cpp -CFLAGS "-I$(TBU)" -o sim
endif

intAdder-verilator intAdder-vcs: intAdder-build
	cd $(IA_V)/ref && ./sim $(SIM_RUN) $(PLUSARGS)

intAdder-check: intAdder-build
	cd $(IA_V)/ref && ./sim +DUMP=add_int32.txt $(SIM_RUN) $(PLUSARGS)
	python3 $(MODELS)/check_ipu.py $(IA_V)/ref/add_int32.txt --unit add

intAdder-lint:
ifeq ($(SIM),vcs)
	$(call vcs_lint,intAdder,intAdder,$(PKG) $(IA_RTL),+define+SYNTHESIS)
else
	bash $(SCRIPTS)/lint.sh "lint intAdder" -Wall -Wno-fatal -DSYNTHESIS --top-module intAdder $(IA_RTL)
endif

IM_V      = $(call unit_dir,intMultiplier)
IM_RTL    = $(SRC)/multipliers/intMultiplier.sv

intMultiplier-build:
ifeq ($(SIM),vcs)
	$(call vcs_build,TB_intMultiplier,$(IM_V)/ref,$(PKG) $(IM_RTL) $(TBU)/TB_intMultiplier.sv $(TBU)/int_ref.cpp,+incdir+$(TBU) -CFLAGS "-I$(TBU)")
else
	verilator $(INT_FLAGS) --top-module TB_intMultiplier --Mdir $(ROOT)/Verilator/intMultiplier/ref $(PKG) $(IM_RTL) \
	  $(TBU)/TB_intMultiplier.sv $(TBU)/int_ref.cpp -CFLAGS "-I$(TBU)" -o sim
endif

intMultiplier-verilator intMultiplier-vcs: intMultiplier-build
	cd $(IM_V)/ref && ./sim $(SIM_RUN) $(PLUSARGS)

intMultiplier-check: intMultiplier-build
	cd $(IM_V)/ref && ./sim +DUMP=mul_int8.txt $(SIM_RUN) $(PLUSARGS)
	python3 $(MODELS)/check_ipu.py $(IM_V)/ref/mul_int8.txt --unit mul --exhaustive

intMultiplier-build16:
ifeq ($(SIM),vcs)
	$(call vcs_build,TB_intMultiplier,$(IM_V)/ref16,$(PKG) $(IM_RTL) $(TBU)/TB_intMultiplier.sv $(TBU)/int_ref.cpp,-pvalue+TB_intMultiplier.W=16 +incdir+$(TBU) -CFLAGS "-I$(TBU)")
else
	verilator $(INT_FLAGS) -GW=16 --top-module TB_intMultiplier --Mdir $(ROOT)/Verilator/intMultiplier/ref16 $(PKG) $(IM_RTL) \
	  $(TBU)/TB_intMultiplier.sv $(TBU)/int_ref.cpp -CFLAGS "-I$(TBU)" -o sim
endif

intMultiplier-verilator16 intMultiplier-vcs16: intMultiplier-build16
	cd $(IM_V)/ref16 && ./sim $(SIM_RUN) $(PLUSARGS)

intMultiplier-check16: intMultiplier-build16
	cd $(IM_V)/ref16 && ./sim +DUMP=mul_int16.txt $(SIM_RUN) $(PLUSARGS)
	python3 $(MODELS)/check_ipu.py $(IM_V)/ref16/mul_int16.txt --unit mul16

intMultiplier-lint:
ifeq ($(SIM),vcs)
	$(call vcs_lint,intMultiplier W=8,intMultiplier,$(PKG) $(IM_RTL),+define+SYNTHESIS -pvalue+intMultiplier.W=8)
	$(call vcs_lint,intMultiplier W=16,intMultiplier,$(PKG) $(IM_RTL),+define+SYNTHESIS -pvalue+intMultiplier.W=16)
else
	bash $(SCRIPTS)/lint.sh "lint intMultiplier W=8" -Wall -Wno-fatal -DSYNTHESIS --top-module intMultiplier -GW=8 $(IM_RTL)
	bash $(SCRIPTS)/lint.sh "lint intMultiplier W=16" -Wall -Wno-fatal -DSYNTHESIS --top-module intMultiplier -GW=16 $(IM_RTL)
endif

.PHONY: intAdder-build intAdder-verilator intAdder-vcs intAdder-check intAdder-lint intMultiplier-build intMultiplier-verilator intMultiplier-vcs \
        intMultiplier-check intMultiplier-build16 intMultiplier-verilator16 intMultiplier-vcs16 intMultiplier-check16 intMultiplier-lint

# ─────────────────────────────────────────────────────────────────────────────
# fp32ToBf16: check (its direct reference bench, round to nearest even on corners, every tie class and RANDOM values, then the dump against
# fpu.narrow), mutant, lint (-Wall, must be clean: 0 warnings, 0 errors). make fmt-equiv proved its words equal to fpNarrow (8, 7) on every
# fp32 word before fpNarrow left the library (acefcbc).
# ─────────────────────────────────────────────────────────────────────────────
RANDOM ?= 1000000
NB_DESIGN = $(or $(UNIT_SRC),$(SRC)/converters/fp32ToBf16.sv)  # the mutant target points it at a faulted copy
NB_FLAGS  = $(VFLAGS) -I$(TBU) $(VWNO)
NB_BENCH  = $(or $(BENCH_DIR),$(call unit_dir,fp32ToBf16)/ref)

fp32ToBf16-check:
ifeq ($(SIM),vcs)
	$(call vcs_build,TB_fp32ToBf16,$(NB_BENCH),$(NB_DESIGN) $(TBU)/TB_fp32ToBf16.sv,-pvalue+TB_fp32ToBf16.RANDOM=$(RANDOM) +incdir+$(TBU))
else
	verilator $(NB_FLAGS) -GRANDOM=$(RANDOM) --top-module TB_fp32ToBf16 --Mdir $(NB_BENCH) $(NB_DESIGN) $(TBU)/TB_fp32ToBf16.sv -o sim
endif
	cd $(NB_BENCH) && ./sim +DUMP=narrow_bf16.txt $(SIM_RUN) | tee run.log
	command grep -q "^RESULT: PASSED" $(NB_BENCH)/run.log
	python3 $(MODELS)/check_fpu.py $(NB_BENCH)/narrow_bf16.txt --unit narrow --format bf16

# the planted fault of testbenches/units/fp32ToBf16_mutant.sed against this bench: passes only when the bench fails
fp32ToBf16-mutant:
	@bash $(SCRIPTS)/unit_mutant.sh ties_round_down $(SRC)/converters/fp32ToBf16.sv $(TBU)/fp32ToBf16_mutant.sed $(UNIT_MAKE) -s --no-print-directory fp32ToBf16-check SIM=$(SIM)

fp32ToBf16-lint:
ifeq ($(SIM),vcs)
	$(call vcs_lint,fp32ToBf16,fp32ToBf16,$(NB_DESIGN),+define+SYNTHESIS)
else
	bash $(SCRIPTS)/lint.sh "lint fp32ToBf16" -Wall -Wno-fatal -DSYNTHESIS --top-module fp32ToBf16 $(NB_DESIGN)
endif

.PHONY: fp32ToBf16-check fp32ToBf16-mutant fp32ToBf16-lint

# ─────────────────────────────────────────────────────────────────────────────
# int8Requantizer: verilator (C reference through DPI on every row, then the true function on each row's real scale), shift_bad (a_shift_range
# fires, and only it), lint. int8QuantizedAdder: verilator (C reference through DPI: every (q1, q2) under the corner sets, then RANDOM rows;
# then the true function on the real ratios), shift_bad (a_shift_range fires), lint. <unit>-vcs is <unit>-verilator on VCS.
# 1 unit, 2 the vector generator, 3 the checker, 4 the run reads a constants file (1) or not, 5 the bad row, 6 the message it must print
# ─────────────────────────────────────────────────────────────────────────────
Q8_FLAGS = $(VFLAGS) +define+FMT_INT8 -I$(TBU) $(VWNO)
# A simulation (1: command, 2: its log, 3: its bench) fails the target unless it exits 0, prints RESULT: PASSED and prints no %Error or failed assertion (a simulator may carry on after $error); [f] and [E] keep make's echo of this line from matching, here and in regress.py's firing scan.
RUN_CHECKED = set -o pipefail; $(1) | tee $(2) && command grep -q '^RESULT: PASSED' $(2) && ! command grep -qE '^(\[[0-9]+\] )?%[E]rror|Assertion [f]ailed|^([E]rror|[F]atal): "|^[E]rror-\[' $(2) || { echo "$(3): the simulation failed, printed an error or a failed assertion, or printed no RESULT: PASSED ($(2))"; exit 1; }
define quant_bench
$(1)_V      = $$(call unit_dir,$(1))
$(1)_DESIGN = $$(PKG) $(SRC)/quantized/$(1).sv
$(1)_BUILD  = $$(if $$(filter vcs,$$(SIM)),$$(call vcs_build,TB_$(1),$$($(1)_V)/ref,$$($(1)_DESIGN) $$(TBU)/TB_$(1).sv $$(TBU)/int_ref.cpp,+define+FMT_INT8 +incdir+$$(TBU) -CFLAGS "-I$$(TBU)"),verilator $$(Q8_FLAGS) --top-module TB_$(1) --Mdir $$($(1)_V)/ref $$($(1)_DESIGN) $$(TBU)/TB_$(1).sv $$(TBU)/int_ref.cpp -CFLAGS "-I$$(TBU)" -o sim)

$(1)-verilator $(1)-vcs:
	$$(PYTHON) $$(SCRIPTS)/$(2) $$($(1)_V)/vec.txt --random $$(RANDOM)
	$$($(1)_BUILD)
	$$(call RUN_CHECKED,$$($(1)_V)/ref/sim $$(SIM_RUN) $(if $(4),+CONSTS=$$($(1)_V)/vec.txt.consts )+VEC=$$($(1)_V)/vec.txt +DUMP=$$($(1)_V)/dump.txt $$(PLUSARGS),$$($(1)_V)/sim_vec.log,TB_$(1))
	$$(PYTHON) $$(SCRIPTS)/$(3) $$($(1)_V)/dump.txt --vectors $$($(1)_V)/vec.txt

$(1)-shift_bad:
	@printf '$(5)\n' > $$($(1)_V)/vec_bad.txt
	@$$($(1)_BUILD) > $$($(1)_V)/build_bad.log 2>&1 || { cat $$($(1)_V)/build_bad.log; echo NOT-FIRED; exit 1; }
	@$$($(1)_V)/ref/sim $$(SIM_RUN) +VEC=$$($(1)_V)/vec_bad.txt > $$($(1)_V)/sim_bad.txt 2>&1; cat $$($(1)_V)/sim_bad.txt; \
	  if command grep -q "$(6)" $$($(1)_V)/sim_bad.txt; then echo FIRED; \
	  else echo NOT-FIRED; exit 1; fi

$(1)-lint:
ifeq ($$(SIM),vcs)
	$$(call vcs_lint,$(1),$(1),$(SRC)/quantized/$(1).sv,+define+SYNTHESIS)
	$$(call vcs_lint,$(1) (assertions),$(1),$(SRC)/quantized/$(1).sv,)
else
	bash $$(SCRIPTS)/lint.sh "lint $(1)" -Wall -Wno-fatal -DSYNTHESIS --top-module $(1) $(SRC)/quantized/$(1).sv
	bash $$(SCRIPTS)/lint.sh "lint $(1) (assertions)" -Wall -Wno-fatal --top-module $(1) $(SRC)/quantized/$(1).sv
endif

.PHONY: $(1)-verilator $(1)-vcs $(1)-shift_bad $(1)-lint
endef
$(eval $(call quant_bench,int8Requantizer,gen_requantizer_vectors.py,check_requantizer.py,,00000064 800000 38 00 80 7f,int8Requantizer: shift 56 above 55))
$(eval $(call quant_bench,int8QuantizedAdder,gen_quantized_adder_vectors.py,check_quantized_adder.py,1,0a 0a 00 00 80000000 80000000 2a 00 80 7f,int8QuantizedAdder: shift 42 above 41))

# ─────────────────────────────────────────────────────────────────────────────
# The fp32 units of record and the Karatsuba multiplier: <unit>-verilator (SoftFloat through DPI for the fp32 units), -vcs, -lint (Verilator's
# --lint-only of the bench), -check-files, -wave (dump.vcd), -help, -clean. 1 unit, 2 title, 3 the bench's top, 4 sources, 5 the C reference,
# 6 flags after --sv, 7 flags at the end, 8 SoftFloat: 1 linked, 2 linked and checked by -check-files, empty not used, 9 the sources' src/ folder
# ─────────────────────────────────────────────────────────────────────────────
SIM_THREADS ?= 1  # one, since a unit bench is small (8 threads measured 4.3x slower than 1 on GPNAE; several at once also spin)
WAVE = surfer
SF_VFLAGS = -CFLAGS "-I$(SF_INC)" -LDFLAGS "$(SF_LIB)"
define fp32_bench
$(1)_VDIR   = $(ROOT)/Verilator/$(1)
$(1)_VCSDIR = $(ROOT)/VCS/$(1)
$(1)_FLAGS  = --trace --timing --top-module $(3) --threads $$(SIM_THREADS) -j $$(shell nproc) --build-jobs 0 --sv $(6) -I$(SRC)/$(9) -I$$(TBU) \
              --Mdir $$($(1)_VDIR) --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT --Wno-INITIALDLY $(7)
$(1)_VCSFLAGS = +incdir+$(SRC)/$(9) +incdir+$$(TBU)$(if $(8), -CFLAGS "-I$$(SF_INC)")

$(1)-help:
	@echo "=== $(2) ==="
	@echo ""
	@echo "Simulation Targets:"
	@echo "  make $(1)-verilator   - Simulate using Verilator"
	@echo "  make $(1)-vcs         - Simulate using Synopsys VCS"
	@echo ""
	@echo "Analysis Targets:"
	@echo "  make $(1)-lint        - Run Verilator lint check (Code Quality)"
	@echo "  make $(1)-check-files - Verify source files exist"
	@echo ""
	@echo "Utility Targets:"
	@echo "  make $(1)-wave        - View waveforms (dump.vcd)"
	@echo "  make $(1)-clean       - Remove simulation artifacts"
	@echo ""
	@echo "Configuration:"
	@echo "  TOP_MODULE: $(3)"
	@echo "  FILES:      $$(words $(4)) Source files"

$(1)-verilator: $(if $(8),$$(SF_LIB)) $(1)-check-files
	@echo "=== Verilator simulation for $(3) ==="
	@mkdir -p $$($(1)_VDIR)
	@echo "-- Compiling RTL..."
	verilator --binary $$($(1)_FLAGS) $(4) $$(TBU)/$(3).sv $(5) -o $(3)_sim
	@echo "-- Building Executable..."
	make -C $$($(1)_VDIR) -f V$(3).mk
	@echo "-- Running Simulation..."
	cd $$($(1)_VDIR) && ./$(3)_sim
	@echo "=== Simulation Complete ==="
	@echo "-- Trace file: $$($(1)_VDIR)/dump.vcd"

$(1)-vcs: $(if $(8),$$(SF_LIB)) $(1)-check-files
	@echo "=== VCS simulation for $(3) ==="
	$$(call vcs_build,$(3),$$($(1)_VCSDIR),$(4) $$(TBU)/$(3).sv $(5)$(if $(8), $$(SF_LIB)),$$($(1)_VCSFLAGS))
	@echo "-- Running VCS simulation"
	cd $$($(1)_VCSDIR) && ./sim $$(VCS_RUN)
	@echo "=== VCS simulation complete ==="

$(1)-wave:
	@if [ -f $$($(1)_VDIR)/dump.vcd ]; then \
		echo "-- Opening Verilator waveform"; \
		$$(WAVE) $$($(1)_VDIR)/dump.vcd; \
	elif [ -f $$($(1)_VCSDIR)/dump.vcd ]; then \
		echo "-- Opening VCS waveform"; \
		$$(WAVE) $$($(1)_VCSDIR)/dump.vcd; \
	else \
		echo "-- No waveform dumps found. Run 'make $(1)-verilator' first."; \
	fi

$(1)-lint:
	@echo "=== Linting $(3) ==="
	@mkdir -p $$($(1)_VDIR)
	verilator --lint-only $$($(1)_FLAGS) $(4) $$(TBU)/$(3).sv
	@echo "-- Lint check complete"

$(1)-check-files: $(if $(filter 2,$(8)),$$(SF_LIB))
	@echo "=== Checking source files ==="
	@missing=0; \
	for file in $(strip $(4) $$(TBU)/$(3).sv $(5))$(if $(filter 2,$(8)), $$(SF_LIB)); do \
		if [ ! -f "$$$$file" ]; then \
		echo "  MISSING: $$$$file"; \
		missing=$$$$((missing + 1)); \
		fi; \
	done; \
	if [ $$$$missing -eq 0 ]; then \
		echo "  OK: All files found."; \
	else \
		echo "  ERROR: $$$$missing file(s) missing!"; \
		exit 1; \
	fi

$(1)-clean:
	@echo "-- Cleaning simulation artifacts"
	-rm -rf $$($(1)_VDIR) $$($(1)_VCSDIR)
	@echo "-- Clean complete"

.PHONY: $(1)-help $(1)-verilator $(1)-vcs $(1)-wave $(1)-lint $(1)-check-files $(1)-clean
endef
$(eval $(call fp32_bench,fp32Adder,IEEE 754 Single Precision Adder,TB_fp32Adder,$(SRC)/adders/fp32Adder.sv $(SRC)/adders/LZC.sv,$(TBU)/fp32Adder_ref.cpp,,--Wno-SHORTREAL $(SF_VFLAGS),1,adders))
$(eval $(call fp32_bench,fp32Multiplier,IEEE 754 Single Precision Multiplier,TB_fp32Multiplier,$(BOOTH_KARATSUBA) $(SRC)/multipliers/fp32Multiplier.sv,$(TBU)/fp32Multiplier_ref.cpp,--autoflush,$(SF_VFLAGS),2,multipliers))
$(eval $(call fp32_bench,karatsuba,Karatsuba Multiplier,TB_karatsuba,$(SRC)/multipliers/R4Booth.sv $(SRC)/multipliers/karatsubaUnsigned.sv $(SRC)/multipliers/karatsubaSigned.sv,,,--Wno-IMPLICITSTATIC,,multipliers))

# ─────────────────────────────────────────────────────────────────────────────
# fmt: one wrapper per fundamental operation (fmt_mul, fmt_add) and the package functions fmt_greater_than and fmt_relu. Each point lints its
# top and runs TB_fmt (wrapper against its unit, function against the inline logic it replaces: words and cycles) at one define and width;
# truefn, fmt_pkg, check_fmt, controls and mutants check the gate library, the parser, the RTL scan and the define; exhaustive runs the unit
# sweeps (fmt_mul, fmt_add, the package functions, fp32ToBf16, int8Requantizer and int8QuantizedAdder).
# ─────────────────────────────────────────────────────────────────────────────
LINT_BASELINE ?= $(TBT)/lint_baseline.txt  # the controls point it at a copy
FM_V    = $(ROOT)/Verilator/fmt
N      ?= 200000
# the per-format units the wrappers and test tops use, and the generic integer units the equivalence tops compare them with
FM_UNITS = $(SRC)/multipliers/R4Booth.sv $(SRC)/multipliers/karatsubaUnsigned.sv \
        $(SRC)/multipliers/fp32Multiplier.sv $(SRC)/adders/LZC.sv $(SRC)/adders/fp32Adder.sv \
        $(SRC)/multipliers/bf16Multiplier.sv $(SRC)/adders/bf16Adder.sv \
        $(SRC)/multipliers/bf16WideMultiplier.sv $(SRC)/converters/fp32ToBf16.sv \
        $(SRC)/multipliers/int8Multiplier.sv $(SRC)/adders/int32Adder.sv \
        $(SRC)/quantized/int8Requantizer.sv $(SRC)/quantized/int8QuantizedAdder.sv
FM_GENERIC = $(SRC)/multipliers/intMultiplier.sv $(SRC)/adders/intAdder.sv
FM_EQ_ONLY = $(SRC)/multipliers/int16Multiplier.sv $(SRC)/multipliers/int24Multiplier.sv  # GPNAE's units, proven here
FM_WRAPPERS = $(SRC)/fmt/fmt_mul.sv $(SRC)/fmt/fmt_add.sv
FM_TOPS     = $(TBT)/fmt_tops.sv  # test tops: fmt_greater_than, fmt_relu, fp32ToBf16, int8Requantizer, int8QuantizedAdder under the port names the benches drive
FM_INC     = -I$(SRC)/fmt
FM_FLAGS0  = --binary --timing --assert --sv --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT --Wno-INITIALDLY \
          -j $(shell nproc) --build-jobs 0 $(EXTRA_FLAGS)
FM_FLAGS   = $(FM_FLAGS0) $(FM_INC)
FM_SWEEP_FLAGS0 = --cc --exe --build --sv --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT -O3 --x-assign fast --x-initial fast -MAKEFLAGS OPT_FAST=-O2 \
          -j $(shell nproc) --build-jobs 0 $(EXTRA_FLAGS)
FM_SWEEP_FLAGS = $(FM_SWEEP_FLAGS0) $(FM_INC)
FM_SRC     = $(PKG) $(FM_UNITS) $(FM_WRAPPERS) $(FM_TOPS)
# a point's lint: lint_gate.py fails on any warning in new code, and on any warning in an existing file beyond testbenches/top/lint_baseline.txt
FM_TOP_mul = fmt_mul
FM_TOP_add = fmt_add
FM_TOP_cmp = fmt_fn_cmp
FM_TOP_relu = fmt_fn_relu
FM_TOP_narrow = fmt_fn_narrow
FM_TOP_requantize = fmt_fn_requantize
FM_TOP_quantized_add = fmt_fn_quantized_add

# ── the points: name | format | kind | TB_fmt's parameters | the top's parameters for its lint (~ for a space) ──
FM_POINTS = mul_fp32|fp32|mul|| \
         mul_bf16_o16|bf16|mul|| \
         mul_bf16_o32|bf16|mul|-GMUL_EXT_DATA_WIDTH=32|-GEXT_DATA_WIDTH=32 \
         mul_int8_o16|int8|mul|| \
         mul_int8_o32|int8|mul|-GMUL_EXT_DATA_WIDTH=32|-GEXT_DATA_WIDTH=32 \
         add_fp32|fp32|add|| add_bf16|bf16|add|| add_bf16_w16|bf16|add|-GADD_DATA_WIDTH=16|-GDATA_WIDTH=16 \
         add_int8|int8|add|| \
         cmp_fp32|fp32|cmp|| cmp_bf16|bf16|cmp|| cmp_int8|int8|cmp|| \
         relu_fp32|fp32|relu|| relu_bf16|bf16|relu|| relu_int8|int8|relu||
FM_POINT_NAMES = $(foreach p,$(FM_POINTS),$(word 1,$(subst |, ,$(p))))

fmt-help:
	@echo "  make fmt-<point>          - lint its top and run TB_fmt: $(FM_POINT_NAMES)"
	@echo "  make fmt-points           - the TB_fmt point names, one per line (regression.py's self-test reads them)"
	@echo "  make fmt-lint-baseline    - re-record each point's existing-file warnings in testbenches/top/lint_baseline.txt; refused when an"
	@echo "                            existing file changed since the last record (FORCE=1 re-records anyway)"
	@echo "  make fmt-all_<fmt>        - every point of one format"
	@echo "  make fmt-truefn | fmt-fmt_pkg | fmt-check_fmt | fmt-controls | fmt-mutants | fmt-lint_tops"
	@echo "  make fmt-exhaustive FMT=<f> - the unit sweeps of the gate table (sweep.py; every core)"
	@echo "  make fmt-sweep-build KIND=<k> FMT=<f> [DATA_WIDTH=<n>] [EXT_DATA_WIDTH=<n>] [RULE=lane] - one sweep harness (kinds: mul add cmp relu"
	@echo "                            narrow requantize quantized_add; RULE=lane judges fmt_add by the lane rule at any width)"
	@echo "  make fmt-equiv            - each per-width integer unit equals the generic unit it replaces (equiv.py; every core)"
	@echo "  make fmt-eq-build TOP=<eq top> BITS=<n> [COMB=1] - one equivalence harness"

# ── one point: lint (0 library warnings, 0 errors), then TB_fmt; under VCS TB_fmt only (the lint is Verilator's, its baseline Verilator's warnings) ──
ifeq ($(SIM),vcs)
define fm_point
fmt-$(1):
	@echo "lint $(1): not applicable to VCS (verilator --lint-only against lint_baseline.txt; the unit lint points run VCS's +lint=all)"
	@d=$$(ROOT)/VCS/fmt/tb_$(1); rm -rf $$$$d; \
	$$(call vcs_build,TB_fmt,$$$$d,$$(FM_SRC) $$(TBT)/TB_fmt.sv,+define+FMT_$(shell echo $(2) | tr a-z A-Z) +incdir+$$(SRC)/fmt $$(call vcs_g,TB_fmt,-GKIND='"$(3)"' $(4))) \
	  > $$$$d.build.log 2>&1 || { echo "TB_fmt $(1): BUILD FAILED"; tail -30 $$$$d.build.log; exit 1; }; \
	$$$$d/sim +N=$$(N) +SEED=1 $$(VCS_RUN)
endef
else
define fm_point
fmt-$(1):
	@log=$$(FM_V)/lint_$(1).log; verilator --lint-only -Wall -Wno-fatal -DSYNTHESIS +define+FMT_$(shell echo $(2) | tr a-z A-Z) $$(FM_INC) $(5) \
	  --top-module $$(FM_TOP_$(3)) $$(FM_SRC) > $$$$log 2>&1; rc=$$$$?; \
	  $$(PYTHON) $$(SCRIPTS)/lint_gate.py $$$$log $(1) $$(FM_TOP_$(3)) $$(if $$(RECORD),--record) $$(if $$(FORCE),--force) --baseline $$(LINT_BASELINE) $$(LINT_GATE_ARGS) && [ $$$$rc -eq 0 ]
	@d=$$(FM_V)/tb_$(1); rm -rf $$$$d; \
	verilator $$(FM_FLAGS) +define+FMT_$(shell echo $(2) | tr a-z A-Z) -GKIND='"$(3)"' $(4) --top-module TB_fmt --Mdir $$$$d $$(FM_SRC) $$(TBT)/TB_fmt.sv -o sim \
	  > $$$$d.build.log 2>&1 || { echo "TB_fmt $(1): BUILD FAILED"; tail -30 $$$$d.build.log; exit 1; }; \
	$$$$d/sim +N=$$(N) +SEED=1
endef
endif
field = $(subst ~, ,$(word $(2),$(subst |, ,$(1))))
$(foreach p,$(FM_POINTS),$(eval $(call fm_point,$(call field,$(p),1),$(call field,$(p),2),$(call field,$(p),3),$(call field,$(p),4),$(call field,$(p),5))))

# the test tops TB_fmt does not drive, linted per define as the points are (0 library warnings): fmt_fn_narrow in fp32 and bf16, the int8 units' tops
TOP_LINTS = narrow_fp32:fp32:narrow narrow_bf16:bf16:narrow requantize_int8:int8:requantize quantized_add_int8:int8:quantized_add
fmt-lint_tops:
	@rc=0; for t in $(TOP_LINTS); do IFS=: read -r n f k <<< "$$t"; top=fmt_fn_$$k; log=$(FM_V)/lint_$$n.log; \
	  verilator --lint-only -Wall -Wno-fatal -DSYNTHESIS +define+FMT_$$(echo $$f | tr a-z A-Z) $(FM_INC) --top-module $$top $(FM_SRC) > $$log 2>&1 || rc=1; \
	  $(PYTHON) $(SCRIPTS)/lint_gate.py $$log $$n $$top $(if $(RECORD),--record) $(if $(FORCE),--force) --baseline $(LINT_BASELINE) $(LINT_GATE_ARGS) || rc=1; \
	done; exit $$rc

LB_POINTS ?= $(FM_POINT_NAMES) lint_tops
C6_MAKE = $(MAKE)  # a recipe line naming $(MAKE) runs under make -n; this one only prints

fmt-points:
	@printf '%s\n' $(FM_POINT_NAMES)

# the old file stays: lint_gate.py --record refuses when an existing file changed since it was recorded (FORCE=1 overrides)
fmt-lint-baseline:
	@for p in $(LB_POINTS); do $(MAKE) -s --no-print-directory fmt-$$p RECORD=1 N=1 || exit 1; done; \
	mkdir -p $(ROOT)/results && cp $(LINT_BASELINE) $(ROOT)/results/lint_baseline.txt; wc -l $(LINT_BASELINE)

of_fmt = $(foreach n,$(FM_POINT_NAMES),$(if $(findstring _$(1),$(n)),fmt-$(n)))  # make's filter takes one % per pattern
fmt-all_fp32: $(call of_fmt,fp32)
fmt-all_bf16: $(call of_fmt,bf16)
fmt-all_int8: $(call of_fmt,int8)

# ── the gate library, the parser and the RTL scan (Python, no simulator) ──
fmt-truefn:
	$(PYTHON) $(MODELS)/truefn.py --selftest
	$(PYTHON) $(MODELS)/test_truefn.py
	$(PYTHON) $(SCRIPTS)/sweep.py --selftest

fmt-fmt_pkg:
	$(PYTHON) $(MODELS)/fmt_pkg.py --selftest

ARIL_ALLOW = ^src/(fmt|adders|multipliers|converters|dividers|quantized)/.*$$
# the tree passes; a planted EXP_W in a credit module (C4) fails
fmt-check_fmt:
	@bash $(SCRIPTS)/check_fmt.sh $(ROOT) '$(ARIL_ALLOW)' && echo "check_fmt OK: the tree passes" || { echo "check_fmt FAIL: the tree"; exit 1; }
	@t=$(FM_V)/check_fmt_c4; rm -rf $$t; mkdir -p $$t/src/fmt $$t/src/credit; cp $(PKG) $$t/src/fmt/; cp $(SRC)/credit/*.sv $$t/src/credit/; \
	sed -i 's/^endmodule/  localparam int EXP_W = 8;\nendmodule/' $$t/src/credit/credit_reg.sv; \
	if bash $(SCRIPTS)/check_fmt.sh $$t '$(ARIL_ALLOW)'; then echo "check_fmt FAIL: C4 planted EXP_W passed"; exit 1; else echo "check_fmt OK: C4 planted EXP_W in credit_reg.sv fails"; fi

# ── controls: FMT outside the list, two defines (the preprocessor stops), the elaboration check behind it, widths a wrapper refuses ──
# a width each wrapper refuses: format, top, parameter, the start of its message
define bad_width
@log=$(FM_V)/c5_w_$(1)_$(2)_$(subst =,,$(3)).log; \
	if verilator --lint-only -DSYNTHESIS +define+FMT_$(shell echo $(1) | tr a-z A-Z) $(FM_INC) $(3) --top-module $(2) $(FM_SRC) > $$log 2>&1; then \
	  echo "controls FAIL: $(1) $(2) $(3) elaborated"; exit 1; fi; \
	command grep -q -F "$(4)" $$log && echo "controls OK: $(1) $(2) $(3) refused" || { echo "controls FAIL: $(1) $(2) $(3) message"; cat $$log; exit 1; }
endef
fmt-controls:
	@if $(MAKE) -s --no-print-directory fmt-help FMT=fp16 > $(FM_V)/c5_fp16.log 2>&1; then echo "controls FAIL: FMT=fp16 accepted"; exit 1; fi; \
	command grep -q "FMT=fp16: not one of fp32 bf16 int8" $(FM_V)/c5_fp16.log && echo "controls OK: FMT=fp16 stops make" || { echo "controls FAIL: FMT=fp16 message"; exit 1; }
	@for pair in INT8_BF16 INT8_FP32 BF16_FP32; do a=$${pair%_*}; b=$${pair#*_}; \
	  if verilator --lint-only +define+FMT_$$a +define+FMT_$$b $(FM_INC) --top-module fmt_mul $(FM_SRC) > $(FM_V)/c5_$$pair.log 2>&1; then \
	    echo "controls FAIL: FMT_$$a with FMT_$$b built"; exit 1; fi; \
	  command grep -q "SIENNA_FMT_ERROR_FMT_$${a}_AND_FMT_$${b}_BOTH_DEFINED" $(FM_V)/c5_$$pair.log \
	    && echo "controls OK: FMT_$$a with FMT_$$b stops the preprocessor" || { echo "controls FAIL: FMT_$$a with FMT_$$b message"; cat $(FM_V)/c5_$$pair.log; exit 1; }; \
	done
	@if verilator --lint-only +define+FMT_INT8 +define+FMT_BF16 +define+SIENNA_FMT_ERROR_FMT_INT8_AND_FMT_BF16_BOTH_DEFINED= $(FM_INC) \
	  --top-module fmt_mul $(FM_SRC) > $(FM_V)/c5_elab.log 2>&1; then echo "controls FAIL: two defines elaborated"; exit 1; fi; \
	command grep -q "fmt_mul: 2 precision defines" $(FM_V)/c5_elab.log && echo "controls OK: the elaboration check repeats it" \
	  || { echo "controls FAIL: elaboration message"; cat $(FM_V)/c5_elab.log; exit 1; }
	@for f in fp32 bf16 int8; do $(PYTHON) $(MODELS)/fmt_pkg.py --fmt $$f --get FORMAT_NAME | command grep -qx $$f || { echo "controls FAIL: fmt_pkg $$f"; exit 1; }; done; \
	verilator --lint-only -Wno-fatal -DSYNTHESIS $(FM_INC) --top-module fmt_mul $(FM_SRC) > $(FM_V)/c5_default.log 2>&1 || { echo "controls FAIL: no define"; exit 1; }; \
	echo "controls OK: no define elaborates fp32"
	@for m in WRAPPER_DATA_WIDTH EXT_DATA_WIDTH; do d=$(FM_V)/c5_no_$$m; rm -rf $$d; \
	  cf=$$($(PYTHON) $(MODELS)/fmt_pkg.py --fmt bf16 --cflags add --data-width 16 | sed "s/-D$$m=[0-9]*//"); \
	  if verilator $(FM_SWEEP_FLAGS) +define+FMT_BF16 -GDATA_WIDTH=16 --top-module fmt_add --Mdir $$d $(FM_SRC) $(TBT)/sweep_fmt.cpp \
	      -CFLAGS "-O2 -DKIND_ADD -DVTOP=Vfmt_add $$cf" -o sweep > $$d.log 2>&1; then \
	    echo "controls FAIL: a sweep harness for bf16 fmt_add #(16) built without $$m (it would judge by a default width)"; exit 1; fi; \
	  command grep -q "$$m is not defined" $$d.log && echo "controls OK: a sweep harness missing $$m does not build" \
	    || { echo "controls FAIL: no #error for a missing $$m"; tail -5 $$d.log; exit 1; }; \
	done
	@d=$(FM_V)/c5_misdecode; rm -rf $$d; cf=$$($(PYTHON) $(MODELS)/fmt_pkg.py --fmt bf16 --cflags add --data-width 32); \
	verilator $(FM_SWEEP_FLAGS) +define+FMT_BF16 -GDATA_WIDTH=16 --top-module fmt_add --Mdir $$d $(FM_SRC) $(TBT)/sweep_fmt.cpp \
	  -CFLAGS "-O2 -DKIND_ADD -DVTOP=Vfmt_add $$cf" -o sweep > $$d.build.log 2>&1 || { echo "controls FAIL: the misdecode harness did not build"; exit 1; }; \
	$$d/sweep --mode pairs16 --lo 63 > $$d.log 2>&1; \
	v=$$(cd $(SCRIPTS) && $(PYTHON) -c "import re, sweep; l = [x for x in open('$$d.log') if x.startswith('SWEEP ')][0]; \
	  g = lambda k: int(re.search(' ' + k + ' ([0-9]+)', l).group(1)); print(sweep.gate_verdict(0, g('miss'), 0, 1, g('n'), g('ungated'), g('floor_only')))"); \
	case "$$v" in "FAIL (every gated row is decided by the floor)") echo "controls OK: a misdecoded sweep fails: $$v ($$(command grep -m1 -o 'n [0-9]* miss [0-9]*' $$d.log), $$(command grep -m1 -o 'floor_only [0-9]*' $$d.log))";; \
	  *) echo "controls FAIL: a misdecoded sweep (bf16 words judged as fp32) does not fail for its floor-decided rows: $$v"; exit 1;; esac
	@d=$(FM_V)/c5_lint; rm -rf $$d; mkdir -p $$d/src/adders $$d/src/fmt; \
	sed 's/^endmodule/  logic c5_planted_signal;\nendmodule/' $(SRC)/adders/fp32Adder.sv > $$d/src/adders/fp32Adder.sv; \
	sed 's/^endmodule/  logic c5_planted_signal;\nendmodule/' $(SRC)/fmt/fmt_add.sv > $$d/src/fmt/fmt_add.sv; \
	for c in existing:$$d/src/adders/fp32Adder.sv:$(SRC)/fmt/fmt_add.sv new:$(SRC)/adders/fp32Adder.sv:$$d/src/fmt/fmt_add.sv; do \
	  IFS=: read -r what unit wrap <<< "$$c"; \
	  verilator --lint-only -Wall -Wno-fatal -DSYNTHESIS +define+FMT_FP32 $(FM_INC) --top-module fmt_add $(PKG) $(SRC)/adders/LZC.sv $$unit $$wrap \
	    > $$d/$$what.log 2>&1; \
	  if $(PYTHON) $(SCRIPTS)/lint_gate.py $$d/$$what.log add_fp32 fmt_add --as $$d > $$d/$$what.gate 2>&1; then \
	    echo "controls FAIL: a warning planted in $$what code passed the lint gate"; cat $$d/$$what.gate; exit 1; fi; \
	  echo "controls OK: a warning planted in $$what code fails the lint gate: $$(command grep -m1 -o 'NEW WARNING.*c5_planted_signal' $$d/$$what.gate | cut -c1-110)"; \
	done; \
	printf '%s\n' "%Warning-PLANTED: a warning with no location" > $$d/unplaced.log; \
	if $(PYTHON) $(SCRIPTS)/lint_gate.py $$d/unplaced.log add_fp32 fmt_add > $$d/unplaced.gate 2>&1; then \
	  echo "controls FAIL: a %Warning line with no location passed the lint gate"; exit 1; fi; \
	echo "controls OK: a %Warning line with no location fails the lint gate"
	@t=$(FM_V)/c6_tree; rm -rf $$t; mkdir -p $$t/src/adders; cp $(TBT)/lint_baseline.txt $(FM_V)/c6_baseline.txt; \
	sed 's/^endmodule/endmodule  \/\/ c6: an edit since the baseline was recorded/' $(SRC)/adders/fp32Adder.sv > $$t/src/adders/fp32Adder.sv; \
	if $(C6_MAKE) -s --no-print-directory fmt-lint-baseline LB_POINTS=add_fp32 LINT_BASELINE=$(FM_V)/c6_baseline.txt LINT_GATE_ARGS="--root $$t" \
	    > $(FM_V)/c6_rerecord.log 2>&1; then echo "controls FAIL: make lint-baseline re-recorded over an existing file changed since the baseline"; exit 1; fi; \
	command grep -q "refusing to re-record: existing files changed since the baseline: src/adders/fp32Adder.sv" $(FM_V)/c6_rerecord.log \
	  && echo "controls OK: make lint-baseline refuses to re-record over a changed existing file" \
	  || { echo "controls FAIL: make lint-baseline did not refuse for the changed fp32Adder.sv"; tail -5 $(FM_V)/c6_rerecord.log; exit 1; }
	$(call bad_width,fp32,fmt_mul,-GDATA_WIDTH=16,fmt_mul: fp32 multiplies DATA_WIDTH = 32)
	$(call bad_width,bf16,fmt_mul,-GEXT_DATA_WIDTH=24,fmt_mul: bf16 multiplies DATA_WIDTH = 16)
	$(call bad_width,int8,fmt_mul,-GDATA_WIDTH=16,fmt_mul: int8 multiplies DATA_WIDTH = 8)
	$(call bad_width,int8,fmt_mul,-GEXT_DATA_WIDTH=12,fmt_mul: int8 multiplies DATA_WIDTH = 8)
	$(call bad_width,bf16,fmt_add,-GDATA_WIDTH=8,fmt_add: a float build adds at)
	$(call bad_width,int8,fmt_add,-GDATA_WIDTH=8,fmt_add: int8 adds at the accumulator width)

# ── mutants (testbenches/top/mutants.list): y must fail TB_fmt (words or cycles) and the true-function sweep, n TB_fmt, s the sweep (params_random
# for the units with parameter sets); a mutant's copies keep the old layout: src/ the wrappers, pkg/ the package, tops/ fmt_tops.sv ──
fmt-mutants:
	@caught=0; total=0; while IFS='|' read -r name f kind file expr sizes sw; do case "$$name" in ''|'#'*) continue;; esac; total=$$((total + 1)); \
	  d=$(FM_V)/mut_$$name; rm -rf $$d; mkdir -p $$d/src $$d/pkg $$d/tops; cp $(FM_WRAPPERS) $$d/src/; cp $(PKG) $$d/pkg/; cp $(FM_TOPS) $$d/tops/; \
	  urel=""; case "$$file" in pkg) tgt=$$d/pkg/sienna_fmt_pkg.sv;; tops) tgt=$$d/tops/fmt_tops.sv;; \
	    unit:*) urel=$${file#unit:}; mkdir -p $$d/unit; tgt=$$d/unit/$$(basename $$urel); cp $(ROOT)/$$urel $$tgt;; *) tgt=$$d/$$file;; esac; \
	  cp $$tgt $$tgt.orig; sed -i "$$expr" $$tgt; if cmp -s $$tgt $$tgt.orig; then echo "mutant $$name FAIL: the sed changed nothing"; exit 1; fi; \
	  src="$$d/pkg/sienna_fmt_pkg.sv $(FM_UNITS) $(FM_GENERIC) $(FM_EQ_ONLY) $$d/src/fmt_mul.sv $$d/src/fmt_add.sv $$d/tops/fmt_tops.sv"; F=$$(echo $$f | tr a-z A-Z); \
	  if [ -n "$$urel" ]; then n=""; for w in $$src; do [ "$$w" = "$(ROOT)/$$urel" ] && w=$$tgt; n="$$n $$w"; done; src=$$n; fi; \
	  set -- $$sizes; tbg=""; swg=""; pw=""; \
	  if [ -n "$$1" ]; then case $$kind in \
	    mul) tbg="-GMUL_DATA_WIDTH=$$1 -GMUL_EXT_DATA_WIDTH=$$2"; swg="-GDATA_WIDTH=$$1 -GEXT_DATA_WIDTH=$$2"; pw="--data-width $$1 --ext-data-width $$2";; \
	    add) tbg="-GADD_DATA_WIDTH=$$1"; swg="-GDATA_WIDTH=$$1"; pw="--data-width $$1";; esac; fi; \
	  if [ "$$sw" != s ]; then \
	  if verilator $(FM_FLAGS0) -I$(SRC)/fmt +define+FMT_$$F -GKIND="\"$$kind\"" $$tbg --top-module TB_fmt --Mdir $$d/tb $$src $(TBT)/TB_fmt.sv \
	      -o sim > $$d/build.log 2>&1; then $$d/tb/sim +N=20000 +SEED=3 > $$d/run.log 2>&1; else echo "BUILD FAILED" > $$d/run.log; fi; \
	  if command grep -q "^BUILD FAILED" $$d/run.log; then echo "mutant $$name ($$f $$kind) SURVIVED: its build failed, which is not a kill"; \
	  elif command grep -q "^RESULT: PASSED" $$d/run.log; then echo "mutant $$name ($$f $$kind) SURVIVED TB_fmt"; \
	  else caught=$$((caught + 1)); echo "mutant $$name ($$f $$kind) caught by TB_fmt: $$(command grep -m1 -E '^TB_fmt|BUILD|rror' $$d/run.log | tr -d '%' | cut -c1-150)"; fi; \
	  else total=$$((total - 1)); fi; \
	  if [ "$$sw" = y ] || [ "$$sw" = s ]; then total=$$((total + 1)); top=$$(case $$kind in mul) echo fmt_mul;; add) echo fmt_add;; *) echo fmt_fn_$$kind;; esac); \
	    swm="--mode random --n 200000 --seed 9"; case $$kind in requantize|quantized_add) \
	      $(PYTHON) $(SCRIPTS)/sweep.py --write-params $$kind $$d/params.txt > /dev/null || { echo "mutant $$name: no parameter sets"; exit 1; }; \
	      swm="--mode params_random --n 200000 --seed 9 --params $$d/params.txt";; esac; \
	    if verilator $(FM_SWEEP_FLAGS0) -I$(SRC)/fmt +define+FMT_$$F $$swg --top-module $$top --Mdir $$d/sw $$src $(TBT)/sweep_fmt.cpp \
	        -CFLAGS "-O2 -DKIND_$$(echo $$kind | tr a-z A-Z) -DVTOP=V$$top $$($(PYTHON) $(MODELS)/fmt_pkg.py --fmt $$f --cflags $$kind $$pw)" \
	        -o sweep > $$d/sw.build.log 2>&1; then $$d/sw/sweep $$swm > $$d/sw.log 2>&1; else echo "BUILD FAILED" > $$d/sw.log; fi; \
	    if command grep -q "^BUILD FAILED" $$d/sw.log; then echo "mutant $$name ($$f $$kind) SURVIVED: its sweep build failed, which is not a kill"; \
	    elif [ -n "$$1" ] && ! command grep -q "data_width $$1 ext_data_width $${2:-$$1}$$" $$d/sw.log; then \
	      echo "mutant $$name ($$f $$kind) SURVIVED: its sweep ran at other widths than $$sizes, which is not a kill"; \
	    elif command grep -q "^RESULT: PASSED" $$d/sw.log; then echo "mutant $$name ($$f $$kind) SURVIVED the true-function sweep"; \
	    else caught=$$((caught + 1)); echo "mutant $$name ($$f $$kind) caught by the true-function sweep: $$(command grep -m1 '^SWEEP ' $$d/sw.log | cut -c1-150)"; fi; fi; \
	done < $(TBT)/mutants.list; echo "mutants: $$caught of $$total caught"; [ $$total -gt 0 ] && [ $$caught -eq $$total ]

# ── unit sweeps ──
KIND  ?= mul
DATA_WIDTH ?=
EXT_DATA_WIDTH ?=
RULE  ?=
ifneq ($(filter-out lane,$(RULE)),)
$(error RULE=$(RULE): only RULE=lane (fmt_add judged by the lane rule) or no RULE)
endif
FM_SW_DIR = $(FM_V)/sweep_$(FMT)_$(KIND)$(if $(DATA_WIDTH),_d$(DATA_WIDTH))$(if $(EXT_DATA_WIDTH),_e$(EXT_DATA_WIDTH))$(if $(RULE),_$(RULE))
fmt-sweep-build:
	@rm -rf $(FM_SW_DIR); \
	verilator $(FM_SWEEP_FLAGS) $(FMT_DEF) $(if $(DATA_WIDTH),-GDATA_WIDTH=$(DATA_WIDTH)) $(if $(EXT_DATA_WIDTH),-GEXT_DATA_WIDTH=$(EXT_DATA_WIDTH)) \
	  --top-module $(FM_TOP_$(KIND)) --Mdir $(FM_SW_DIR) $(FM_SRC) $(TBT)/sweep_fmt.cpp -CFLAGS "-O2 -DKIND_$(shell echo $(KIND) | tr a-z A-Z) \
	  -DVTOP=V$(FM_TOP_$(KIND)) \
	  $(if $(filter lane,$(RULE)),-DLANE_RULE) \
	  $(shell $(PYTHON) $(MODELS)/fmt_pkg.py --fmt $(FMT) --cflags $(KIND) $(if $(DATA_WIDTH),--data-width $(DATA_WIDTH)) \
	  $(if $(EXT_DATA_WIDTH),--ext-data-width $(EXT_DATA_WIDTH)))" -o sweep > $(FM_SW_DIR).build.log 2>&1 \
	  || { echo "sweep-build $(KIND) $(FMT): BUILD FAILED"; tail -40 $(FM_SW_DIR).build.log; exit 1; }; echo "sweep-build $(KIND) $(FMT): $(FM_SW_DIR)/sweep"

fmt-exhaustive:
	$(PYTHON) $(SCRIPTS)/sweep.py --fmt $(FMT) $(if $(SWEEP_KINDS),--kinds $(SWEEP_KINDS)) $(if $(SWEEP_ARGS),$(SWEEP_ARGS))

# ── equivalence: each per-width integer unit against the generic unit it replaces (eq_tops.sv) ──
TOP  ?= eq_int16_mul
BITS ?= 16
FM_EQ_DIR = $(FM_V)/eq_$(TOP)
fmt-eq-build:
	@rm -rf $(FM_EQ_DIR); \
	verilator $(FM_SWEEP_FLAGS) --top-module $(TOP) --Mdir $(FM_EQ_DIR) $(PKG) $(FM_UNITS) $(FM_GENERIC) $(FM_EQ_ONLY) $(TBT)/eq_tops.sv $(TBT)/eq_fmt.cpp \
	  -CFLAGS "-O2 -DVTOP=V$(TOP) -DEQ_BITS=$(BITS) $(if $(COMB),-DCOMB)" -o eq > $(FM_EQ_DIR).build.log 2>&1 \
	  || { echo "eq-build $(TOP): BUILD FAILED"; tail -40 $(FM_EQ_DIR).build.log; exit 1; }; echo "eq-build $(TOP): $(FM_EQ_DIR)/eq"

fmt-equiv:
	$(PYTHON) $(SCRIPTS)/equiv.py $(if $(EQ_ARGS),$(EQ_ARGS))

# every pair on its first slice and 10^5 random vectors: the harness in make regression (make fmt-equiv is the proof)
fmt-equiv_quick:
	$(PYTHON) $(SCRIPTS)/equiv.py --slices 2 --scale 0.008 --out $(ROOT)/results/equiv_quick

.PHONY: fmt-help fmt-points fmt-lint_tops fmt-lint-baseline fmt-all_fp32 fmt-all_bf16 fmt-all_int8 fmt-truefn fmt-fmt_pkg fmt-check_fmt fmt-controls \
        fmt-mutants fmt-sweep-build fmt-exhaustive fmt-eq-build fmt-equiv fmt-equiv_quick $(addprefix fmt-,$(FM_POINT_NAMES))
