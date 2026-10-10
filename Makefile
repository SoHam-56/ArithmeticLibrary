SHELL := /bin/bash
# make regression: every unit bench and model check once, each its own target (make -j runs them side by side), then one table.
PYTHON  ?= python3
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
	@echo "  make regression/<point>    - one point, e.g. regression/Adders/FP/check"
	@echo "  make regression-summary    - the table of the results in REG_DIR (default results/regression)"
	@echo "  Each unit's own Makefile has its benches: make -C Adders/FP check, ..."

# One point: runs in a private copy of the tree, writes $(REG_DIR)/<point>.log and .json.
regression/%:
	@$(PYTHON) regression.py --action point --name $* --results $(REG_DIR)$(if $(REG_RUN), --run $(REG_RUN))$(if $(filter regression,$(MAKECMDGOALS)), --keep-going)

regression: $(addprefix regression/,$(REG_POINTS))
	@$(REG_SUMMARY) --run $(REG_RUN)

regression-summary:
	@$(REG_SUMMARY)$(if $(REG_RUN), --run $(REG_RUN))

.PHONY: default help regression regression-summary
