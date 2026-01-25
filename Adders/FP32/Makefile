SHELL := /bin/bash

PRJ_DIR = $(shell pwd)
SRC_DIR = $(PRJ_DIR)/src
TB_DIR  = $(PRJ_DIR)/testbenches

# --- SoftFloat Configuration ---
SOFTFLOAT_BASE = $(TB_DIR)/berkeley-softfloat-3
SOFTFLOAT_INC  = $(SOFTFLOAT_BASE)/source/include
# Note: This path matches the one you provided
SOFTFLOAT_LIB  = $(SOFTFLOAT_BASE)/build/Linux-x86_64-GCC/softfloat.a

VERILATOR = verilator
VCS       = vcs
WAVE      = surfer

# ADDER_FILES = \
#     fp32Adder.sv \
#     LZC.sv

# DESIGN_FILES = \
#     $(addprefix $(SRC_DIR)/,$(ADDER_FILES))

ADDER_FILES = \
    /home/admin/Desktop/SystolicArray/src/MAC/Adder_FP32.sv \
    /home/admin/Desktop/SystolicArray/src/MAC/LZC.sv

DESIGN_FILES = $(ADDER_FILES)

TESTBENCH  = TB_fp32Adder.sv
CPP_FILES  = $(TB_DIR)/fp32_ref.cpp

TOP_MODULE = TB_fp32Adder

VERILATOR_DIR = $(PRJ_DIR)/Verilator
VCS_DIR       = $(PRJ_DIR)/VCS

VERILATOR_FLAGS = \
    --trace \
    --timing \
    --top-module $(TOP_MODULE) \
    --threads $(shell nproc) \
    --sv \
    -I$(SRC_DIR) \
    -I$(TB_DIR) \
    --Mdir $(VERILATOR_DIR) \
    --Wno-WIDTHTRUNC \
    --Wno-WIDTHEXPAND \
    --Wno-WIDTHCONCAT \
    --Wno-INITIALDLY \
		--Wno-SHORTREAL \
		-CFLAGS "-I$(SOFTFLOAT_INC)" \
    -LDFLAGS "$(SOFTFLOAT_LIB)"


VCS_FLAGS = \
    -full64 \
    -sverilog \
    -debug_all \
    -timescale=1ns/1ps \
    -Mdir=$(VCS_DIR) \
    +v2k \
    +incdir+$(SRC_DIR) \
    +incdir+$(TB_DIR) \
    +define+VCS

default: help

help:
	@echo "=== IEEE 754 Single Precision Adder ==="
	@echo ""
	@echo "Simulation Targets:"
	@echo "  make verilator         - Simulate using Verilator"
	@echo "  make vcs               - Simulate using Synopsys VCS"
	@echo ""
	@echo "Analysis Targets:"
	@echo "  make lint              - Run Verilator lint check (Code Quality)"
	@echo "  make check-files       - Verify source files exist"
	@echo ""
	@echo "Utility Targets:"
	@echo "  make wave              - View waveforms (dump.vcd)"
	@echo "  make clean             - Remove simulation artifacts"
	@echo ""
	@echo "Configuration:"
	@echo "  TOP_MODULE: $(TOP_MODULE)"
	@echo "  FILES:      $(words $(DESIGN_FILES)) Source files"


verilator: check-files
			@echo "=== Verilator simulation for $(TOP_MODULE) ==="
			@mkdir -p $(VERILATOR_DIR)
			@echo "-- Compiling RTL..."
			$(VERILATOR) --binary \
					$(VERILATOR_FLAGS) \
					$(DESIGN_FILES) \
					$(TB_DIR)/$(TESTBENCH) \
					$(CPP_FILES) \
					-o $(TOP_MODULE)_sim
			@echo "-- Building Executable..."
			make -C $(VERILATOR_DIR) -f V$(TOP_MODULE).mk
			@echo "-- Running Simulation..."
			cd $(VERILATOR_DIR) && ./$(TOP_MODULE)_sim
			@echo "=== Simulation Complete ==="
			@echo "-- Trace file: $(VERILATOR_DIR)/dump.vcd"


vcs: check-files
			@echo "=== VCS simulation for $(TOP_MODULE) ==="
			@mkdir -p $(VCS_DIR)
			$(VCS) $(VCS_FLAGS) \
					-o $(VCS_DIR)/$(TOP_MODULE)_sim \
					$(DESIGN_FILES) \
					$(TB_DIR)/$(TESTBENCH) \
					$(CPP_FILES)
			@echo "-- Running VCS simulation"
			cd $(VCS_DIR) && ./$(TOP_MODULE)_sim
			@echo "=== VCS simulation complete ==="

wave:
			@if [ -f $(VERILATOR_DIR)/dump.vcd ]; then \
					echo "-- Opening Verilator waveform"; \
					$(WAVE) $(VERILATOR_DIR)/dump.vcd; \
			elif [ -f $(VCS_DIR)/dump.vcd ]; then \
					echo "-- Opening VCS waveform"; \
					$(WAVE) $(VCS_DIR)/dump.vcd; \
			else \
					echo "-- No waveform dumps found. Run 'make verilator' first."; \
			fi

lint:
			@echo "=== Linting $(TOP_MODULE) ==="
			@mkdir -p $(VERILATOR_DIR)
			$(VERILATOR) --lint-only \
					$(VERILATOR_FLAGS) \
					$(DESIGN_FILES) \
					$(TB_DIR)/$(TESTBENCH)
			@echo "-- Lint check complete"

check-files:
			@echo "=== Checking source files ==="
			@missing=0; \
			for file in $(DESIGN_FILES) $(TB_DIR)/$(TESTBENCH) $(CPP_FILES); do \
					if [ ! -f "$$file" ]; then \
					echo "  MISSING: $$file"; \
					missing=$$((missing + 1)); \
					fi; \
			done; \
			if [ $$missing -eq 0 ]; then \
					echo "  OK: All files found."; \
			else \
					echo "  ERROR: $$missing file(s) missing!"; \
					exit 1; \
			fi

clean:
			@echo "-- Cleaning simulation artifacts"
			-rm -rf $(VERILATOR_DIR) $(VCS_DIR)
			-rm -f *.vpd *.vcd *.wlf *.log *.key
			-rm -f csrc simv simv.daidir
			@echo "-- Clean complete"

.PHONY: default help verilator vcs wave lint check-files clean
