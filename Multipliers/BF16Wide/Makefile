SHELL := /bin/bash
# bf16WideMultiplier: verilator (its direct reference bench: SoftFloat's exact fp32 product through DPI, bit for bit, flags), mutant (a planted fault its bench must fail), lint (-Wall, must be clean: 0 warnings, 0 errors). make -C Fmt equiv proved its words and done
# cycles equal to fpMulWiden (8, 7) before that generic unit left the library (ArithmeticLibrary acefcbc).
PRJ_DIR = $(shell pwd)
ARIL    = $(PRJ_DIR)/../..
COMMON  = $(ARIL)/Common
TB_DIR  = $(PRJ_DIR)/testbenches
SF      = $(ARIL)/Adders/FP32/testbenches/berkeley-softfloat-3
SF_INC  = $(SF)/source/include
SF_LIB  = $(SF)/build/Linux-x86_64-GCC/softfloat.a
PLUSARGS ?=
$(shell mkdir -p $(PRJ_DIR)/Verilator)  # Verilator makes --Mdir but not its parent
UNIT_SRC ?= $(PRJ_DIR)/src/bf16WideMultiplier.sv  # the mutant target points it at a faulted copy
include $(COMMON)/sim.mk
BENCH_DIR ?= $(PRJ_DIR)/$(if $(filter vcs,$(SIM)),VCS,Verilator)/sf
DESIGN  = $(UNIT_SRC)
FLAGS   = --binary --timing --assert --sv +define+FMT_BF16 -I$(COMMON)/testbenches -I$(TB_DIR) \
          --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-WIDTHCONCAT --Wno-INITIALDLY -j $(shell nproc) --build-jobs 0 $(EXTRA_FLAGS)

verilator: $(SF_LIB)
	verilator $(FLAGS) --top-module TB_bf16WideMultiplier --Mdir $(BENCH_DIR) $(COMMON)/src/sienna_fmt_pkg.sv $(DESIGN) \
	  $(TB_DIR)/TB_bf16WideMultiplier.sv $(COMMON)/testbenches/fp_ref.cpp \
	  -CFLAGS "-I$(SF_INC) -I$(COMMON)/testbenches" -LDFLAGS "$(SF_LIB)" -o sim
	cd $(BENCH_DIR) && ./sim $(PLUSARGS)

# the same bench on VCS (make vcs, or SIM=vcs through make regression): the DPI reference compiled in
vcs: $(SF_LIB)
	$(call vcs_build,TB_bf16WideMultiplier,$(BENCH_DIR),$(COMMON)/src/sienna_fmt_pkg.sv $(DESIGN) $(TB_DIR)/TB_bf16WideMultiplier.sv $(COMMON)/testbenches/fp_ref.cpp $(SF_LIB),+define+FMT_BF16 +incdir+$(COMMON)/testbenches +incdir+$(TB_DIR) -CFLAGS "-I$(SF_INC) -I$(COMMON)/testbenches")
	cd $(BENCH_DIR) && ./sim $(VCS_RUN) $(PLUSARGS)

# the planted fault of testbenches/mutant.sed against this bench: passes only when the bench fails
UNIT_MAKE = $(MAKE)  # a recipe line naming $(MAKE) would run under make -n
mutant:
	@bash $(COMMON)/unit_mutant.sh product_lsb_dropped $(PRJ_DIR)/src/bf16WideMultiplier.sv $(TB_DIR)/mutant.sed $(UNIT_MAKE) -s --no-print-directory $(if $(filter vcs,$(SIM)),vcs,verilator) SIM=$(SIM)

lint:
ifeq ($(SIM),vcs)
	$(call vcs_lint,bf16WideMultiplier,bf16WideMultiplier,$(DESIGN),+define+SYNTHESIS +define+FMT_BF16)
else
	bash $(COMMON)/lint.sh "lint bf16WideMultiplier" -Wall -Wno-fatal -DSYNTHESIS --top-module bf16WideMultiplier $(DESIGN)
endif

$(SF_LIB):
	$(MAKE) -j$(shell nproc) -C $(SF)/build/Linux-x86_64-GCC

.PHONY: mutant verilator vcs lint
