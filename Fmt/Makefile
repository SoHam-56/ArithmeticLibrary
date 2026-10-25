SHELL := /bin/bash
# Fmt: one wrapper per fundamental operation (fmt_mul, fmt_add) and the package functions fmt_greater_than and fmt_relu. Each point lints its top and
# runs TB_fmt (wrapper against its unit, function against the inline logic it replaces: words and cycles) at one define and width;
# truefn, fmt_pkg, check_fmt, controls and mutants check the gate library, the parser, the RTL scan and the define; exhaustive runs the unit sweeps
# (fmt_mul, fmt_add, the package functions, fp32ToBf16, int8Requantizer and int8QuantizedAdder).
PRJ_DIR = $(shell pwd)
ARIL    = $(PRJ_DIR)/..
COMMON  = $(ARIL)/Common
TB_DIR  = $(PRJ_DIR)/testbenches
LINT_BASELINE ?= $(TB_DIR)/lint_baseline.txt  # the controls point it at a copy
V       = $(PRJ_DIR)/Verilator
PYTHON ?= python3
N      ?= 200000
include $(COMMON)/fmt.mk
include $(COMMON)/sim.mk
$(shell mkdir -p $(V))  # Verilator makes --Mdir but not its parent

PKG = $(COMMON)/src/sienna_fmt_pkg.sv  # the package with its define map
# the per-format units the wrappers and test tops use, and the generic integer units the equivalence tops compare them with
UNITS = $(ARIL)/Multipliers/Radix4Booth/src/R4Booth.sv $(ARIL)/Multipliers/Karatsuba/src/karatsubaUnsigned.sv \
        $(ARIL)/Multipliers/FP32/src/fp32Multiplier.sv $(ARIL)/Adders/FP32/src/LZC.sv $(ARIL)/Adders/FP32/src/fp32Adder.sv \
        $(ARIL)/Multipliers/BF16/src/bf16Multiplier.sv $(ARIL)/Adders/BF16/src/bf16Adder.sv \
        $(ARIL)/Multipliers/BF16Wide/src/bf16WideMultiplier.sv $(ARIL)/Converters/FP32ToBF16/src/fp32ToBf16.sv \
        $(ARIL)/Multipliers/Int8/src/int8Multiplier.sv $(ARIL)/Adders/Int32/src/int32Adder.sv \
        $(ARIL)/Requantizer/src/int8Requantizer.sv $(ARIL)/QuantizedAdder/src/int8QuantizedAdder.sv
GENERIC = $(ARIL)/Multipliers/Int/src/intMultiplier.sv $(ARIL)/Adders/Int/src/intAdder.sv
EQ_ONLY = $(ARIL)/Multipliers/Int16/src/int16Multiplier.sv $(ARIL)/Multipliers/Int24/src/int24Multiplier.sv  # GPNAE's units, proven here
WRAPPERS = $(PRJ_DIR)/src/fmt_mul.sv $(PRJ_DIR)/src/fmt_add.sv
TOPS     = $(TB_DIR)/fmt_tops.sv  # test tops: fmt_greater_than, fmt_relu, fp32ToBf16, int8Requantizer, int8QuantizedAdder under the port names the benches drive
INC     = -I$(COMMON)/src
FLAGS0  = --binary --timing --assert --sv --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT --Wno-INITIALDLY \
          -j $(shell nproc) --build-jobs 0 $(EXTRA_FLAGS)
FLAGS   = $(FLAGS0) $(INC)
SWEEP_FLAGS0 = --cc --exe --build --sv --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT -O3 --x-assign fast --x-initial fast -MAKEFLAGS OPT_FAST=-O2 \
          -j $(shell nproc) --build-jobs 0 $(EXTRA_FLAGS)
SWEEP_FLAGS = $(SWEEP_FLAGS0) $(INC)
SRC     = $(PKG) $(UNITS) $(WRAPPERS) $(TOPS)
# a point's lint: lint_gate.py fails on any warning in new code, and on any warning in an existing file beyond testbenches/lint_baseline.txt
TOP_mul = fmt_mul
TOP_add = fmt_add
TOP_cmp = fmt_fn_cmp
TOP_relu = fmt_fn_relu
TOP_narrow = fmt_fn_narrow
TOP_requantize = fmt_fn_requantize
TOP_quantized_add = fmt_fn_quantized_add

# ── the points: name | format | kind | TB_fmt's parameters | the top's parameters for its lint (~ for a space) ──
POINTS = mul_fp32|fp32|mul|| \
         mul_bf16_o16|bf16|mul|| \
         mul_bf16_o32|bf16|mul|-GMUL_EXT_DATA_WIDTH=32|-GEXT_DATA_WIDTH=32 \
         mul_int8_o16|int8|mul|| \
         mul_int8_o32|int8|mul|-GMUL_EXT_DATA_WIDTH=32|-GEXT_DATA_WIDTH=32 \
         add_fp32|fp32|add|| add_bf16|bf16|add|| add_bf16_w16|bf16|add|-GADD_DATA_WIDTH=16|-GDATA_WIDTH=16 \
         add_int8|int8|add|| \
         cmp_fp32|fp32|cmp|| cmp_bf16|bf16|cmp|| cmp_int8|int8|cmp|| \
         relu_fp32|fp32|relu|| relu_bf16|bf16|relu|| relu_int8|int8|relu||
POINT_NAMES = $(foreach p,$(POINTS),$(word 1,$(subst |, ,$(p))))

help:
	@echo "  make <point>          - lint its top and run TB_fmt: $(POINT_NAMES)"
	@echo "  make points           - the TB_fmt point names, one per line (regression.py's self-test reads them)"
	@echo "  make lint-baseline    - re-record each point's existing-file warnings in testbenches/lint_baseline.txt; refused when an existing"
	@echo "                        file changed since the last record (FORCE=1 re-records anyway)"
	@echo "  make all_<fmt>        - every point of one format"
	@echo "  make truefn | fmt_pkg | check_fmt | controls | mutants | lint_tops"
	@echo "  make exhaustive FMT=<f> - the unit sweeps of the gate table (sweep.py; every core)"
	@echo "  make sweep-build KIND=<k> FMT=<f> [DATA_WIDTH=<n>] [EXT_DATA_WIDTH=<n>] [RULE=lane] - one sweep harness (kinds: mul add cmp relu narrow"
	@echo "                        requantize quantized_add; RULE=lane judges fmt_add by the lane rule at any width)"
	@echo "  make equiv            - each per-width integer unit equals the generic unit it replaces (equiv.py; every core)"
	@echo "  make eq-build TOP=<eq top> BITS=<n> [COMB=1] - one equivalence harness"

# ── one point: lint (0 library warnings, 0 errors), then TB_fmt; under VCS TB_fmt only (the lint is Verilator's, its baseline Verilator's warnings) ──
ifeq ($(SIM),vcs)
define point
$(1):
	@echo "lint $(1): not applicable to VCS (verilator --lint-only against lint_baseline.txt; the unit lint points run VCS's +lint=all)"
	@d=$$(PRJ_DIR)/VCS/tb_$(1); rm -rf $$$$d; \
	$$(call vcs_build,TB_fmt,$$$$d,$$(SRC) $$(TB_DIR)/TB_fmt.sv,+define+FMT_$(shell echo $(2) | tr a-z A-Z) +incdir+$$(COMMON)/src $$(call vcs_g,TB_fmt,-GKIND='"$(3)"' $(4))) \
	  > $$$$d.build.log 2>&1 || { echo "TB_fmt $(1): BUILD FAILED"; tail -30 $$$$d.build.log; exit 1; }; \
	$$$$d/sim +N=$$(N) +SEED=1 $$(VCS_RUN)
endef
else
define point
$(1):
	@log=$$(V)/lint_$(1).log; verilator --lint-only -Wall -Wno-fatal -DSYNTHESIS +define+FMT_$(shell echo $(2) | tr a-z A-Z) $$(INC) $(5) \
	  --top-module $$(TOP_$(3)) $$(SRC) > $$$$log 2>&1; rc=$$$$?; \
	  $$(PYTHON) $$(PRJ_DIR)/lint_gate.py $$$$log $(1) $$(TOP_$(3)) $$(if $$(RECORD),--record) $$(if $$(FORCE),--force) --baseline $$(LINT_BASELINE) $$(LINT_GATE_ARGS) && [ $$$$rc -eq 0 ]
	@d=$$(V)/tb_$(1); rm -rf $$$$d; \
	verilator $$(FLAGS) +define+FMT_$(shell echo $(2) | tr a-z A-Z) -GKIND='"$(3)"' $(4) --top-module TB_fmt --Mdir $$$$d $$(SRC) $$(TB_DIR)/TB_fmt.sv -o sim \
	  > $$$$d.build.log 2>&1 || { echo "TB_fmt $(1): BUILD FAILED"; tail -30 $$$$d.build.log; exit 1; }; \
	$$$$d/sim +N=$$(N) +SEED=1
endef
endif
field = $(subst ~, ,$(word $(2),$(subst |, ,$(1))))
$(foreach p,$(POINTS),$(eval $(call point,$(call field,$(p),1),$(call field,$(p),2),$(call field,$(p),3),$(call field,$(p),4),$(call field,$(p),5))))

# the test tops TB_fmt does not drive, linted per define as the points are (0 library warnings): fmt_fn_narrow in fp32 and bf16, the int8 units' tops
TOP_LINTS = narrow_fp32:fp32:narrow narrow_bf16:bf16:narrow requantize_int8:int8:requantize quantized_add_int8:int8:quantized_add
lint_tops:
	@rc=0; for t in $(TOP_LINTS); do IFS=: read -r n f k <<< "$$t"; top=fmt_fn_$$k; log=$(V)/lint_$$n.log; \
	  verilator --lint-only -Wall -Wno-fatal -DSYNTHESIS +define+FMT_$$(echo $$f | tr a-z A-Z) $(INC) --top-module $$top $(SRC) > $$log 2>&1 || rc=1; \
	  $(PYTHON) $(PRJ_DIR)/lint_gate.py $$log $$n $$top $(if $(RECORD),--record) $(if $(FORCE),--force) --baseline $(LINT_BASELINE) $(LINT_GATE_ARGS) || rc=1; \
	done; exit $$rc

LB_POINTS ?= $(POINT_NAMES) lint_tops
C6_MAKE = $(MAKE)  # a recipe line naming $(MAKE) runs under make -n; this one only prints

points:
	@printf '%s\n' $(POINT_NAMES)

# the old file stays: lint_gate.py --record refuses when an existing file changed since it was recorded (FORCE=1 overrides)
lint-baseline:
	@for p in $(LB_POINTS); do $(MAKE) -s --no-print-directory $$p RECORD=1 N=1 || exit 1; done; \
	mkdir -p $(PRJ_DIR)/results && cp $(LINT_BASELINE) $(PRJ_DIR)/results/lint_baseline.txt; wc -l $(LINT_BASELINE)

of_fmt = $(foreach n,$(POINT_NAMES),$(if $(findstring _$(1),$(n)),$(n)))  # make's filter takes one % per pattern
all_fp32: $(call of_fmt,fp32)
all_bf16: $(call of_fmt,bf16)
all_int8: $(call of_fmt,int8)

# ── the gate library, the parser and the RTL scan (Python, no simulator) ──
truefn:
	$(PYTHON) $(COMMON)/models/truefn.py --selftest
	$(PYTHON) $(COMMON)/models/test_truefn.py
	$(PYTHON) $(PRJ_DIR)/sweep.py --selftest

fmt_pkg:
	$(PYTHON) $(COMMON)/models/fmt_pkg.py --selftest

ARIL_ALLOW = ^(Common/src/sienna_fmt_pkg\.sv|Fmt/src/.*|(Adders|Multipliers|Converters|Divider|Requantizer|QuantizedAdder)/.*)$$
# the tree passes; a planted EXP_W in a credit module (C4) fails
check_fmt:
	@bash $(COMMON)/check_fmt.sh $(ARIL) '$(ARIL_ALLOW)' && echo "check_fmt OK: the tree passes" || { echo "check_fmt FAIL: the tree"; exit 1; }
	@t=$(V)/check_fmt_c4; rm -rf $$t; mkdir -p $$t/Common/src; cp $(COMMON)/src/*.sv $$t/Common/src/; \
	sed -i 's/^endmodule/  localparam int EXP_W = 8;\nendmodule/' $$t/Common/src/credit_reg.sv; \
	if bash $(COMMON)/check_fmt.sh $$t '$(ARIL_ALLOW)'; then echo "check_fmt FAIL: C4 planted EXP_W passed"; exit 1; else echo "check_fmt OK: C4 planted EXP_W in credit_reg.sv fails"; fi

# ── controls: FMT outside the list, two defines (the preprocessor stops), the elaboration check behind it, widths a wrapper refuses ──
# a width each wrapper refuses: format, top, parameter, the start of its message
define bad_width
@log=$(V)/c5_w_$(1)_$(2)_$(subst =,,$(3)).log; \
	if verilator --lint-only -DSYNTHESIS +define+FMT_$(shell echo $(1) | tr a-z A-Z) $(INC) $(3) --top-module $(2) $(SRC) > $$log 2>&1; then \
	  echo "controls FAIL: $(1) $(2) $(3) elaborated"; exit 1; fi; \
	command grep -q -F "$(4)" $$log && echo "controls OK: $(1) $(2) $(3) refused" || { echo "controls FAIL: $(1) $(2) $(3) message"; cat $$log; exit 1; }
endef
controls:
	@if $(MAKE) -s --no-print-directory help FMT=fp16 > $(V)/c5_fp16.log 2>&1; then echo "controls FAIL: FMT=fp16 accepted"; exit 1; fi; \
	command grep -q "FMT=fp16: not one of fp32 bf16 int8" $(V)/c5_fp16.log && echo "controls OK: FMT=fp16 stops make" || { echo "controls FAIL: FMT=fp16 message"; exit 1; }
	@for pair in INT8_BF16 INT8_FP32 BF16_FP32; do a=$${pair%_*}; b=$${pair#*_}; \
	  if verilator --lint-only +define+FMT_$$a +define+FMT_$$b $(INC) --top-module fmt_mul $(SRC) > $(V)/c5_$$pair.log 2>&1; then \
	    echo "controls FAIL: FMT_$$a with FMT_$$b built"; exit 1; fi; \
	  command grep -q "SIENNA_FMT_ERROR_FMT_$${a}_AND_FMT_$${b}_BOTH_DEFINED" $(V)/c5_$$pair.log \
	    && echo "controls OK: FMT_$$a with FMT_$$b stops the preprocessor" || { echo "controls FAIL: FMT_$$a with FMT_$$b message"; cat $(V)/c5_$$pair.log; exit 1; }; \
	done
	@if verilator --lint-only +define+FMT_INT8 +define+FMT_BF16 +define+SIENNA_FMT_ERROR_FMT_INT8_AND_FMT_BF16_BOTH_DEFINED= $(INC) \
	  --top-module fmt_mul $(SRC) > $(V)/c5_elab.log 2>&1; then echo "controls FAIL: two defines elaborated"; exit 1; fi; \
	command grep -q "fmt_mul: 2 precision defines" $(V)/c5_elab.log && echo "controls OK: the elaboration check repeats it" \
	  || { echo "controls FAIL: elaboration message"; cat $(V)/c5_elab.log; exit 1; }
	@for f in fp32 bf16 int8; do $(PYTHON) $(COMMON)/models/fmt_pkg.py --fmt $$f --get FORMAT_NAME | command grep -qx $$f || { echo "controls FAIL: fmt_pkg $$f"; exit 1; }; done; \
	verilator --lint-only -Wno-fatal -DSYNTHESIS $(INC) --top-module fmt_mul $(SRC) > $(V)/c5_default.log 2>&1 || { echo "controls FAIL: no define"; exit 1; }; \
	echo "controls OK: no define elaborates fp32"
	@for m in WRAPPER_DATA_WIDTH EXT_DATA_WIDTH; do d=$(V)/c5_no_$$m; rm -rf $$d; \
	  cf=$$($(PYTHON) $(COMMON)/models/fmt_pkg.py --fmt bf16 --cflags add --data-width 16 | sed "s/-D$$m=[0-9]*//"); \
	  if verilator $(SWEEP_FLAGS) +define+FMT_BF16 -GDATA_WIDTH=16 --top-module fmt_add --Mdir $$d $(SRC) $(TB_DIR)/sweep_fmt.cpp \
	      -CFLAGS "-O2 -DKIND_ADD -DVTOP=Vfmt_add $$cf" -o sweep > $$d.log 2>&1; then \
	    echo "controls FAIL: a sweep harness for bf16 fmt_add #(16) built without $$m (it would judge by a default width)"; exit 1; fi; \
	  command grep -q "$$m is not defined" $$d.log && echo "controls OK: a sweep harness missing $$m does not build" \
	    || { echo "controls FAIL: no #error for a missing $$m"; tail -5 $$d.log; exit 1; }; \
	done
	@d=$(V)/c5_misdecode; rm -rf $$d; cf=$$($(PYTHON) $(COMMON)/models/fmt_pkg.py --fmt bf16 --cflags add --data-width 32); \
	verilator $(SWEEP_FLAGS) +define+FMT_BF16 -GDATA_WIDTH=16 --top-module fmt_add --Mdir $$d $(SRC) $(TB_DIR)/sweep_fmt.cpp \
	  -CFLAGS "-O2 -DKIND_ADD -DVTOP=Vfmt_add $$cf" -o sweep > $$d.build.log 2>&1 || { echo "controls FAIL: the misdecode harness did not build"; exit 1; }; \
	$$d/sweep --mode pairs16 --lo 63 > $$d.log 2>&1; \
	v=$$(cd $(PRJ_DIR) && $(PYTHON) -c "import re, sweep; l = [x for x in open('$$d.log') if x.startswith('SWEEP ')][0]; \
	  g = lambda k: int(re.search(' ' + k + ' ([0-9]+)', l).group(1)); print(sweep.gate_verdict(0, g('miss'), 0, 1, g('n'), g('ungated'), g('floor_only')))"); \
	case "$$v" in "FAIL (every gated row is decided by the floor)") echo "controls OK: a misdecoded sweep fails: $$v ($$(command grep -m1 -o 'n [0-9]* miss [0-9]*' $$d.log), $$(command grep -m1 -o 'floor_only [0-9]*' $$d.log))";; \
	  *) echo "controls FAIL: a misdecoded sweep (bf16 words judged as fp32) does not fail for its floor-decided rows: $$v"; exit 1;; esac
	@d=$(V)/c5_lint; rm -rf $$d; mkdir -p $$d/Adders/FP32/src $$d/Fmt/src; \
	sed 's/^endmodule/  logic c5_planted_signal;\nendmodule/' $(ARIL)/Adders/FP32/src/fp32Adder.sv > $$d/Adders/FP32/src/fp32Adder.sv; \
	sed 's/^endmodule/  logic c5_planted_signal;\nendmodule/' $(PRJ_DIR)/src/fmt_add.sv > $$d/Fmt/src/fmt_add.sv; \
	for c in existing:$$d/Adders/FP32/src/fp32Adder.sv:$(PRJ_DIR)/src/fmt_add.sv new:$(ARIL)/Adders/FP32/src/fp32Adder.sv:$$d/Fmt/src/fmt_add.sv; do \
	  IFS=: read -r what unit wrap <<< "$$c"; \
	  verilator --lint-only -Wall -Wno-fatal -DSYNTHESIS +define+FMT_FP32 $(INC) --top-module fmt_add $(PKG) $(ARIL)/Adders/FP32/src/LZC.sv $$unit $$wrap \
	    > $$d/$$what.log 2>&1; \
	  if $(PYTHON) $(PRJ_DIR)/lint_gate.py $$d/$$what.log add_fp32 fmt_add --as $$d > $$d/$$what.gate 2>&1; then \
	    echo "controls FAIL: a warning planted in $$what code passed the lint gate"; cat $$d/$$what.gate; exit 1; fi; \
	  echo "controls OK: a warning planted in $$what code fails the lint gate: $$(command grep -m1 -o 'NEW WARNING.*c5_planted_signal' $$d/$$what.gate | cut -c1-110)"; \
	done; \
	printf '%s\n' "%Warning-PLANTED: a warning with no location" > $$d/unplaced.log; \
	if $(PYTHON) $(PRJ_DIR)/lint_gate.py $$d/unplaced.log add_fp32 fmt_add > $$d/unplaced.gate 2>&1; then \
	  echo "controls FAIL: a %Warning line with no location passed the lint gate"; exit 1; fi; \
	echo "controls OK: a %Warning line with no location fails the lint gate"
	@t=$(V)/c6_tree; rm -rf $$t; mkdir -p $$t/Adders/FP32/src; cp $(TB_DIR)/lint_baseline.txt $(V)/c6_baseline.txt; \
	sed 's/^endmodule/endmodule  \/\/ c6: an edit since the baseline was recorded/' $(ARIL)/Adders/FP32/src/fp32Adder.sv > $$t/Adders/FP32/src/fp32Adder.sv; \
	if $(C6_MAKE) -s --no-print-directory lint-baseline LB_POINTS=add_fp32 LINT_BASELINE=$(V)/c6_baseline.txt LINT_GATE_ARGS="--root $$t" \
	    > $(V)/c6_rerecord.log 2>&1; then echo "controls FAIL: make lint-baseline re-recorded over an existing file changed since the baseline"; exit 1; fi; \
	command grep -q "refusing to re-record: existing files changed since the baseline: Adders/FP32/src/fp32Adder.sv" $(V)/c6_rerecord.log \
	  && echo "controls OK: make lint-baseline refuses to re-record over a changed existing file" \
	  || { echo "controls FAIL: make lint-baseline did not refuse for the changed fp32Adder.sv"; tail -5 $(V)/c6_rerecord.log; exit 1; }
	$(call bad_width,fp32,fmt_mul,-GDATA_WIDTH=16,fmt_mul: fp32 multiplies DATA_WIDTH = 32)
	$(call bad_width,bf16,fmt_mul,-GEXT_DATA_WIDTH=24,fmt_mul: bf16 multiplies DATA_WIDTH = 16)
	$(call bad_width,int8,fmt_mul,-GDATA_WIDTH=16,fmt_mul: int8 multiplies DATA_WIDTH = 8)
	$(call bad_width,int8,fmt_mul,-GEXT_DATA_WIDTH=12,fmt_mul: int8 multiplies DATA_WIDTH = 8)
	$(call bad_width,bf16,fmt_add,-GDATA_WIDTH=8,fmt_add: a float build adds at)
	$(call bad_width,int8,fmt_add,-GDATA_WIDTH=8,fmt_add: int8 adds at the accumulator width)

# ── mutants (testbenches/mutants.list): y must fail TB_fmt (words or cycles) and the true-function sweep, n TB_fmt, s the sweep (params_random for the
# units with parameter sets) ──
mutants:
	@caught=0; total=0; while IFS='|' read -r name f kind file expr sizes sw; do case "$$name" in ''|'#'*) continue;; esac; total=$$((total + 1)); \
	  d=$(V)/mut_$$name; rm -rf $$d; mkdir -p $$d/src $$d/pkg $$d/tops; cp $(PRJ_DIR)/src/*.sv $$d/src/; cp $(PKG) $$d/pkg/; cp $(TOPS) $$d/tops/; \
	  urel=""; case "$$file" in pkg) tgt=$$d/pkg/sienna_fmt_pkg.sv;; tops) tgt=$$d/tops/fmt_tops.sv;; \
	    unit:*) urel=$${file#unit:}; mkdir -p $$d/unit; tgt=$$d/unit/$$(basename $$urel); cp $(ARIL)/$$urel $$tgt;; *) tgt=$$d/$$file;; esac; \
	  cp $$tgt $$tgt.orig; sed -i "$$expr" $$tgt; if cmp -s $$tgt $$tgt.orig; then echo "mutant $$name FAIL: the sed changed nothing"; exit 1; fi; \
	  src="$$d/pkg/sienna_fmt_pkg.sv $(UNITS) $(GENERIC) $(EQ_ONLY) $$d/src/fmt_mul.sv $$d/src/fmt_add.sv $$d/tops/fmt_tops.sv"; F=$$(echo $$f | tr a-z A-Z); \
	  if [ -n "$$urel" ]; then n=""; for w in $$src; do [ "$$w" = "$(ARIL)/$$urel" ] && w=$$tgt; n="$$n $$w"; done; src=$$n; fi; \
	  set -- $$sizes; tbg=""; swg=""; pw=""; \
	  if [ -n "$$1" ]; then case $$kind in \
	    mul) tbg="-GMUL_DATA_WIDTH=$$1 -GMUL_EXT_DATA_WIDTH=$$2"; swg="-GDATA_WIDTH=$$1 -GEXT_DATA_WIDTH=$$2"; pw="--data-width $$1 --ext-data-width $$2";; \
	    add) tbg="-GADD_DATA_WIDTH=$$1"; swg="-GDATA_WIDTH=$$1"; pw="--data-width $$1";; esac; fi; \
	  if [ "$$sw" != s ]; then \
	  if verilator $(FLAGS0) -I$(COMMON)/src +define+FMT_$$F -GKIND="\"$$kind\"" $$tbg --top-module TB_fmt --Mdir $$d/tb $$src $(TB_DIR)/TB_fmt.sv \
	      -o sim > $$d/build.log 2>&1; then $$d/tb/sim +N=20000 +SEED=3 > $$d/run.log 2>&1; else echo "BUILD FAILED" > $$d/run.log; fi; \
	  if command grep -q "^BUILD FAILED" $$d/run.log; then echo "mutant $$name ($$f $$kind) SURVIVED: its build failed, which is not a kill"; \
	  elif command grep -q "^RESULT: PASSED" $$d/run.log; then echo "mutant $$name ($$f $$kind) SURVIVED TB_fmt"; \
	  else caught=$$((caught + 1)); echo "mutant $$name ($$f $$kind) caught by TB_fmt: $$(command grep -m1 -E '^TB_fmt|BUILD|rror' $$d/run.log | tr -d '%' | cut -c1-150)"; fi; \
	  else total=$$((total - 1)); fi; \
	  if [ "$$sw" = y ] || [ "$$sw" = s ]; then total=$$((total + 1)); top=$$(case $$kind in mul) echo fmt_mul;; add) echo fmt_add;; *) echo fmt_fn_$$kind;; esac); \
	    swm="--mode random --n 200000 --seed 9"; case $$kind in requantize|quantized_add) \
	      $(PYTHON) $(PRJ_DIR)/sweep.py --write-params $$kind $$d/params.txt > /dev/null || { echo "mutant $$name: no parameter sets"; exit 1; }; \
	      swm="--mode params_random --n 200000 --seed 9 --params $$d/params.txt";; esac; \
	    if verilator $(SWEEP_FLAGS0) -I$(COMMON)/src +define+FMT_$$F $$swg --top-module $$top --Mdir $$d/sw $$src $(TB_DIR)/sweep_fmt.cpp \
	        -CFLAGS "-O2 -DKIND_$$(echo $$kind | tr a-z A-Z) -DVTOP=V$$top $$($(PYTHON) $(COMMON)/models/fmt_pkg.py --fmt $$f --cflags $$kind $$pw)" \
	        -o sweep > $$d/sw.build.log 2>&1; then $$d/sw/sweep $$swm > $$d/sw.log 2>&1; else echo "BUILD FAILED" > $$d/sw.log; fi; \
	    if command grep -q "^BUILD FAILED" $$d/sw.log; then echo "mutant $$name ($$f $$kind) SURVIVED: its sweep build failed, which is not a kill"; \
	    elif [ -n "$$1" ] && ! command grep -q "data_width $$1 ext_data_width $${2:-$$1}$$" $$d/sw.log; then \
	      echo "mutant $$name ($$f $$kind) SURVIVED: its sweep ran at other widths than $$sizes, which is not a kill"; \
	    elif command grep -q "^RESULT: PASSED" $$d/sw.log; then echo "mutant $$name ($$f $$kind) SURVIVED the true-function sweep"; \
	    else caught=$$((caught + 1)); echo "mutant $$name ($$f $$kind) caught by the true-function sweep: $$(command grep -m1 '^SWEEP ' $$d/sw.log | cut -c1-150)"; fi; fi; \
	done < $(TB_DIR)/mutants.list; echo "mutants: $$caught of $$total caught"; [ $$total -gt 0 ] && [ $$caught -eq $$total ]

# ── unit sweeps ──
KIND  ?= mul
DATA_WIDTH ?=
EXT_DATA_WIDTH ?=
RULE  ?=
ifneq ($(filter-out lane,$(RULE)),)
$(error RULE=$(RULE): only RULE=lane (fmt_add judged by the lane rule) or no RULE)
endif
SW_DIR = $(V)/sweep_$(FMT)_$(KIND)$(if $(DATA_WIDTH),_d$(DATA_WIDTH))$(if $(EXT_DATA_WIDTH),_e$(EXT_DATA_WIDTH))$(if $(RULE),_$(RULE))
sweep-build:
	@rm -rf $(SW_DIR); \
	verilator $(SWEEP_FLAGS) $(FMT_DEF) $(if $(DATA_WIDTH),-GDATA_WIDTH=$(DATA_WIDTH)) $(if $(EXT_DATA_WIDTH),-GEXT_DATA_WIDTH=$(EXT_DATA_WIDTH)) \
	  --top-module $(TOP_$(KIND)) --Mdir $(SW_DIR) $(SRC) $(TB_DIR)/sweep_fmt.cpp -CFLAGS "-O2 -DKIND_$(shell echo $(KIND) | tr a-z A-Z) \
	  -DVTOP=V$(TOP_$(KIND)) \
	  $(if $(filter lane,$(RULE)),-DLANE_RULE) \
	  $(shell $(PYTHON) $(COMMON)/models/fmt_pkg.py --fmt $(FMT) --cflags $(KIND) $(if $(DATA_WIDTH),--data-width $(DATA_WIDTH)) \
	  $(if $(EXT_DATA_WIDTH),--ext-data-width $(EXT_DATA_WIDTH)))" -o sweep > $(SW_DIR).build.log 2>&1 \
	  || { echo "sweep-build $(KIND) $(FMT): BUILD FAILED"; tail -40 $(SW_DIR).build.log; exit 1; }; echo "sweep-build $(KIND) $(FMT): $(SW_DIR)/sweep"

exhaustive:
	$(PYTHON) $(PRJ_DIR)/sweep.py --fmt $(FMT) $(if $(SWEEP_KINDS),--kinds $(SWEEP_KINDS)) $(if $(SWEEP_ARGS),$(SWEEP_ARGS))

# ── equivalence: each per-width integer unit against the generic unit it replaces (eq_tops.sv) ──
TOP  ?= eq_int16_mul
BITS ?= 16
EQ_DIR = $(V)/eq_$(TOP)
eq-build:
	@rm -rf $(EQ_DIR); \
	verilator $(SWEEP_FLAGS) --top-module $(TOP) --Mdir $(EQ_DIR) $(PKG) $(UNITS) $(GENERIC) $(EQ_ONLY) $(TB_DIR)/eq_tops.sv $(TB_DIR)/eq_fmt.cpp \
	  -CFLAGS "-O2 -DVTOP=V$(TOP) -DEQ_BITS=$(BITS) $(if $(COMB),-DCOMB)" -o eq > $(EQ_DIR).build.log 2>&1 \
	  || { echo "eq-build $(TOP): BUILD FAILED"; tail -40 $(EQ_DIR).build.log; exit 1; }; echo "eq-build $(TOP): $(EQ_DIR)/eq"

equiv:
	$(PYTHON) $(PRJ_DIR)/equiv.py $(if $(EQ_ARGS),$(EQ_ARGS))

# every pair on its first slice and 10^5 random vectors: the harness in make regression (make equiv is the proof)
equiv_quick:
	$(PYTHON) $(PRJ_DIR)/equiv.py --slices 2 --scale 0.008 --out $(PRJ_DIR)/results/equiv_quick

clean:
	rm -rf $(V) $(PRJ_DIR)/results

.PHONY: help points lint_tops lint-baseline all_fp32 all_bf16 all_int8 truefn fmt_pkg check_fmt controls mutants sweep-build exhaustive eq-build equiv equiv_quick clean \
        $(POINT_NAMES)
