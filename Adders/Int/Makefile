SHELL := /bin/bash
# intAdder: verilator (C reference through DPI: wrap corners, carry chains, random), check (against ipu.py), lint.
PRJ_DIR = $(shell pwd)
ARIL    = $(PRJ_DIR)/../..
COMMON  = $(ARIL)/Common
TB_DIR  = $(PRJ_DIR)/testbenches
PLUSARGS ?=
$(shell mkdir -p $(PRJ_DIR)/Verilator)  # Verilator makes --Mdir but not its parent
include $(COMMON)/sim.mk
VDIR    = $(call sim_dir,$(PRJ_DIR))
RTL     = $(PRJ_DIR)/src/intAdder.sv
DESIGN  = $(COMMON)/src/sienna_fmt_pkg.sv $(RTL)
FLAGS   = --binary --timing --assert --sv -I$(COMMON)/testbenches -I$(TB_DIR) \
          --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT --Wno-INITIALDLY -j $(shell nproc) --build-jobs 0 $(EXTRA_FLAGS)

build:
ifeq ($(SIM),vcs)
	$(call vcs_build,TB_intAdder,$(VDIR)/ref,$(DESIGN) $(TB_DIR)/TB_intAdder.sv $(COMMON)/testbenches/int_ref.cpp,+incdir+$(COMMON)/testbenches +incdir+$(TB_DIR) -CFLAGS "-I$(COMMON)/testbenches")
else
	verilator $(FLAGS) --top-module TB_intAdder --Mdir $(PRJ_DIR)/Verilator/ref $(DESIGN) \
	  $(TB_DIR)/TB_intAdder.sv $(COMMON)/testbenches/int_ref.cpp -CFLAGS "-I$(COMMON)/testbenches" -o sim
endif

# make vcs is make verilator on VCS (sim.mk: a vcs goal sets SIM=vcs)
verilator vcs: build
	cd $(VDIR)/ref && ./sim $(SIM_RUN) $(PLUSARGS)

check: build
	cd $(VDIR)/ref && ./sim +DUMP=add_int32.txt $(SIM_RUN) $(PLUSARGS)
	python3 $(COMMON)/models/check_ipu.py $(VDIR)/ref/add_int32.txt --unit add

lint:
ifeq ($(SIM),vcs)
	$(call vcs_lint,intAdder,intAdder,$(COMMON)/src/sienna_fmt_pkg.sv $(RTL),+define+SYNTHESIS)
else
	bash $(COMMON)/lint.sh "lint intAdder" -Wall -Wno-fatal -DSYNTHESIS --top-module intAdder $(RTL)
endif

.PHONY: build verilator vcs check lint
