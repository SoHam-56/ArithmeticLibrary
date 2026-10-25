# The simulator of every build that includes this: SIM ?= verilator (default) or vcs, any other value stops make; include it with an absolute path.
SIM ?= verilator
SIMS = verilator vcs
# a goal named vcs (vcs, vcs16, vcs-lint, ...) is a VCS run whatever SIM the environment holds
ifneq ($(filter vcs vcs%,$(MAKECMDGOALS)),)
ifeq ($(origin SIM),command line)
ifneq ($(SIM),vcs)
$(error make $(filter vcs vcs%,$(MAKECMDGOALS)) runs VCS: SIM=$(SIM) contradicts it)
endif
endif
override SIM := vcs
endif
ifneq ($(words $(SIM)),1)
$(error SIM=$(SIM): one of $(SIMS))
endif
ifeq ($(filter $(SIM),$(SIMS)),)
$(error SIM=$(SIM): not one of $(SIMS))
endif
SIM_MK_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
VCS      ?= vcs
# VCS opt-ins: XPROP=1 X-propagation (-xprop=tmerge); RANDINIT=1 random register power-up, seed SEED (Verilator's --x-initial unique, +verilator+rand+reset+2).
XPROP    ?= 0
RANDINIT ?= 0
SEED     ?= 1
# A plain VCS build: 4-state, SystemVerilog, every core; TRACE=1 (or vcd, fst) adds debug access and ENABLE_TRACE, nothing else does.
VCS_OPTS  = -full64 -sverilog -timescale=1ns/1ps -j$(shell nproc) \
            $(if $(filter 1 vcd fst,$(TRACE)),-debug_access+all +define+ENABLE_TRACE) $(if $(filter 1,$(XPROP)),-xprop=tmerge) \
            $(if $(filter 1,$(RANDINIT)),+vcs+initreg+random +define+NO_ZERO_INIT)
# Run-time options: RANDINIT=1's power-up seed; without TRACE, +vcs+dumpvarsoff stops a bench's own $dumpvars, so a VCS run writes no waveform.
VCS_RUN   = $(if $(filter 1,$(RANDINIT)),+vcs+initreg+$(SEED)) $(if $(filter 1 vcd fst,$(TRACE)),,+vcs+dumpvarsoff)
# One VCS build: 1 the top, 2 the build directory (the simulator is <2>/sim), 3 the sources (.sv, DPI .c/.cpp, .a), 4 more options (+define+, +incdir+, -pvalue+, -CFLAGS).
vcs_build = mkdir -p $(2) && $(VCS) $(VCS_OPTS) -top $(1) -Mdir=$(2)/csrc -o $(2)/sim $(4) $(3)
# Verilator's -G<name>=<value> overrides in 2 as VCS's -pvalue+<1>.<name>=<value>, 1 the top.
vcs_g = $(foreach g,$(filter -G%,$(2)),-pvalue+$(1).$(patsubst -G%,%,$(g)))
# One VCS lint (+lint=all, compiled in a scratch directory): 1 its label, 2 the top, 3 the sources, 4 more options; vcs_lint.py counts it and gates on VCS_LINT_BASELINE once recorded.
VCS_LINT_BASELINE ?= $(abspath $(SIM_MK_DIR)/..)/vcs_lint_baseline.txt
PYTHON ?= python3
vcs_lint = $(PYTHON) $(SIM_MK_DIR)/vcs_lint.py "$(1)" --top $(2) --baseline $(VCS_LINT_BASELINE)$(if $(RECORD), --record) -- $(VCS) -full64 -sverilog -timescale=1ns/1ps +lint=all $(4) $(3)
# A recipe shared by both simulators: VCS_RUN under VCS, nothing under Verilator; SIM_DIR is the simulator's own build tree under 1.
SIM_RUN   = $(if $(filter vcs,$(SIM)),$(VCS_RUN))
sim_dir   = $(1)/$(if $(filter vcs,$(SIM)),VCS,Verilator)
