# The build's precision for every Makefile that includes this: FMT ?= fp32, any other value than fp32, bf16 or int8 stops make, and
# FMT_DEF is the define sienna_fmt_pkg's map reads (+define+FMT_FP32, FMT_BF16 or FMT_INT8); include it with an absolute path.
FMT     ?= fp32
FORMATS  = fp32 bf16 int8
ifneq ($(words $(FMT)),1)
$(error FMT=$(FMT): one of $(FORMATS))
endif
ifeq ($(filter $(FMT),$(FORMATS)),)
$(error FMT=$(FMT): not one of $(FORMATS))
endif
FMT_DEF  = +define+FMT_$(shell echo $(FMT) | tr a-z A-Z)
