SHELL := /bin/bash
# make regression: every unit bench and model check once, each its own target (make -j runs them side by side), then one table.
PYTHON  ?= python3
include $(CURDIR)/Common/fmt.mk
REG_DIR ?= $(CURDIR)/results/regression
REG_SUMMARY = $(PYTHON) regression.py --action summary --results $(REG_DIR)
ifneq ($(filter regression,$(MAKECMDGOALS)),)
ifeq ($(origin REG_RUN),undefined)
REG_RUN := $(shell date +%Y%m%d-%H%M%S)-$(shell echo $$PPID)
endif
REG_POINTS := $(shell $(PYTHON) regression.py --action points)
endif

default: help

help:
	@echo "  make regression            - every unit bench and model check (regression.py --action points lists them), then one table"
	@echo "  make regression/<point>    - one point, e.g. regression/Adders/Int/check"
	@echo "  make regression-summary    - the table of the results in REG_DIR (default results/regression)"
	@echo "  make check-fmt             - no RTL outside the allowlist names a precision (FMT_, EXP_W, MAN_W, EXPONENT_WIDTH, MANTISSA_WIDTH, is_int,"
	@echo "                               is_fp32, from_fp32, widen()"
	@echo "  make exhaustive FMT=<f>    - the unit sweeps of the restructure's gate table for one format (Fmt/sweep.py, every core)"
	@echo "  make equiv                 - each per-width integer unit against the generic unit it replaces (Fmt/equiv.py, every core)"
	@echo "  FMT ?= fp32 (fp32, bf16 or int8) picks the define, +define+FMT_<F>; make regression runs every format's points whatever FMT is"
	@echo "  Each unit's own Makefile has its benches: make -C Adders/Int check, ..."

# One point: runs in a private copy of the tree, writes $(REG_DIR)/<point>.log and .json.
regression/%:
	@$(PYTHON) regression.py --action point --name $* --results $(REG_DIR)$(if $(REG_RUN), --run $(REG_RUN))$(if $(filter regression,$(MAKECMDGOALS)), --keep-going)

regression: $(addprefix regression/,$(REG_POINTS))
	@$(REG_SUMMARY) --run $(REG_RUN)

regression-summary:
	@$(REG_SUMMARY)$(if $(REG_RUN), --run $(REG_RUN))

check-fmt:
	@$(MAKE) -s --no-print-directory -C Fmt check_fmt PYTHON=$(PYTHON)

exhaustive:
	@$(MAKE) --no-print-directory -C Fmt exhaustive FMT=$(FMT) PYTHON=$(PYTHON)

equiv:
	@$(MAKE) --no-print-directory -C Fmt equiv PYTHON=$(PYTHON)

.PHONY: default help regression regression-summary check-fmt exhaustive equiv
