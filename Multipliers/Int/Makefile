SHELL := /bin/bash
# intMultiplier: verilator (C reference through DPI, every int8 pair), check (against ipu.py), verilator16 / check16 (W = 16), lint.
PRJ_DIR = $(shell pwd)
ARIL    = $(PRJ_DIR)/../..
COMMON  = $(ARIL)/Common
TB_DIR  = $(PRJ_DIR)/testbenches
PLUSARGS ?=
$(shell mkdir -p $(PRJ_DIR)/Verilator)  # Verilator makes --Mdir but not its parent
include $(COMMON)/sim.mk
VDIR    = $(call sim_dir,$(PRJ_DIR))
RTL     = $(PRJ_DIR)/src/intMultiplier.sv
DESIGN  = $(COMMON)/src/sienna_fmt_pkg.sv $(RTL)
FLAGS   = --binary --timing --assert --sv -I$(COMMON)/testbenches -I$(TB_DIR) \
          --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT --Wno-INITIALDLY -j $(shell nproc) --build-jobs 0 $(EXTRA_FLAGS)

# make vcs, vcs16 are make verilator, verilator16 on VCS (sim.mk: a vcs goal sets SIM=vcs)
build:
ifeq ($(SIM),vcs)
	$(call vcs_build,TB_intMultiplier,$(VDIR)/ref,$(DESIGN) $(TB_DIR)/TB_intMultiplier.sv $(COMMON)/testbenches/int_ref.cpp,+incdir+$(COMMON)/testbenches +incdir+$(TB_DIR) -CFLAGS "-I$(COMMON)/testbenches")
else
	verilator $(FLAGS) --top-module TB_intMultiplier --Mdir $(PRJ_DIR)/Verilator/ref $(DESIGN) \
	  $(TB_DIR)/TB_intMultiplier.sv $(COMMON)/testbenches/int_ref.cpp -CFLAGS "-I$(COMMON)/testbenches" -o sim
endif

verilator vcs: build
	cd $(VDIR)/ref && ./sim $(SIM_RUN) $(PLUSARGS)

check: build
	cd $(VDIR)/ref && ./sim +DUMP=mul_int8.txt $(SIM_RUN) $(PLUSARGS)
	python3 $(COMMON)/models/check_ipu.py $(VDIR)/ref/mul_int8.txt --unit mul --exhaustive

build16:
ifeq ($(SIM),vcs)
	$(call vcs_build,TB_intMultiplier,$(VDIR)/ref16,$(DESIGN) $(TB_DIR)/TB_intMultiplier.sv $(COMMON)/testbenches/int_ref.cpp,-pvalue+TB_intMultiplier.W=16 +incdir+$(COMMON)/testbenches +incdir+$(TB_DIR) -CFLAGS "-I$(COMMON)/testbenches")
else
	verilator $(FLAGS) -GW=16 --top-module TB_intMultiplier --Mdir $(PRJ_DIR)/Verilator/ref16 $(DESIGN) \
	  $(TB_DIR)/TB_intMultiplier.sv $(COMMON)/testbenches/int_ref.cpp -CFLAGS "-I$(COMMON)/testbenches" -o sim
endif

verilator16 vcs16: build16
	cd $(VDIR)/ref16 && ./sim $(SIM_RUN) $(PLUSARGS)

check16: build16
	cd $(VDIR)/ref16 && ./sim +DUMP=mul_int16.txt $(SIM_RUN) $(PLUSARGS)
	python3 $(COMMON)/models/check_ipu.py $(VDIR)/ref16/mul_int16.txt --unit mul16

lint:
ifeq ($(SIM),vcs)
	$(call vcs_lint,intMultiplier W=8,intMultiplier,$(COMMON)/src/sienna_fmt_pkg.sv $(RTL),+define+SYNTHESIS -pvalue+intMultiplier.W=8)
	$(call vcs_lint,intMultiplier W=16,intMultiplier,$(COMMON)/src/sienna_fmt_pkg.sv $(RTL),+define+SYNTHESIS -pvalue+intMultiplier.W=16)
else
	bash $(COMMON)/lint.sh "lint intMultiplier W=8" -Wall -Wno-fatal -DSYNTHESIS --top-module intMultiplier -GW=8 $(RTL)
	bash $(COMMON)/lint.sh "lint intMultiplier W=16" -Wall -Wno-fatal -DSYNTHESIS --top-module intMultiplier -GW=16 $(RTL)
endif

.PHONY: build verilator vcs check build16 verilator16 vcs16 check16 lint
