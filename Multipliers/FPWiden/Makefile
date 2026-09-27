SHELL := /bin/bash

# fpMulWiden checked against fp32Multiplier; FORMAT=bf16 (default) or fp16.
PRJ_DIR = $(shell pwd)
SRC_DIR = $(PRJ_DIR)/src
TB_DIR  = $(PRJ_DIR)/testbenches
FORMAT ?= bf16

ifeq ($(FORMAT),fp16)
  FMT_FLAGS = -GEXP_W=5 -GMAN_W=10
else
  FMT_FLAGS = -GEXP_W=8 -GMAN_W=7
endif

DESIGN_FILES = \
    $(PRJ_DIR)/../Radix4Booth/src/R4Booth.sv \
    $(PRJ_DIR)/../Karatsuba/src/karatsubaUnsigned.sv \
    $(PRJ_DIR)/../FP32/src/fp32Multiplier.sv \
    $(SRC_DIR)/fpMulWiden.sv

TESTBENCH  = $(TB_DIR)/TB_fpMulWiden.sv
TOP_MODULE = TB_fpMulWiden
VERILATOR_DIR = $(PRJ_DIR)/Verilator_$(FORMAT)

VERILATOR_FLAGS = \
    --binary \
    --timing \
    --assert \
    --top-module $(TOP_MODULE) \
    --sv \
    -I$(SRC_DIR) \
    -I$(TB_DIR) \
    --Mdir $(VERILATOR_DIR) \
    --Wno-WIDTHTRUNC \
    --Wno-WIDTHEXPAND \
    --Wno-WIDTHCONCAT \
    --Wno-INITIALDLY \
    $(FMT_FLAGS)

.PHONY: verilator clean
verilator:
	verilator $(VERILATOR_FLAGS) $(DESIGN_FILES) $(TESTBENCH) -o $(TOP_MODULE)_sim
	$(VERILATOR_DIR)/$(TOP_MODULE)_sim

clean:
	rm -rf $(PRJ_DIR)/Verilator_bf16 $(PRJ_DIR)/Verilator_fp16
