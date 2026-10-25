# ArithmeticLibrary

Arithmetic units in SystemVerilog (fp32, bf16 and int8 adders and multipliers, the int8 requantizer and quantized adder, the fp32-to-bf16 narrower, credit links), each with a bench against a reference (SoftFloat, a C model through DPI, or the Python models in `Common/models`).

The two int8 units take real scales encoded by the host (`ipu.encode_scale`, `ipu.encode_add`), so they work for any scale within the encoder's domain (the adder refuses input-to-output scale ratios of 2^23 or more), not one framework's arithmetic:

- `int8Requantizer` (`Requantizer/`) turns an int32 sum into an int8 output: it multiplies by the channel's scale, held as a 24-bit mantissa and a right shift, rounds half up, adds the zero point and clamps (4 cycles).
- `int8QuantizedAdder` (`QuantizedAdder/`) adds two int8 tensors with different scales, as a residual connection does: each input's offset from its zero point is multiplied by its scale ratio (two 32-bit mantissas on one shared shift), then rounded, offset and clamped like the requantizer (6 cycles).

Both are checked against the exact real-valued result: every output must be within one output step, or 1%, of it.

## One format per build

A design built on this library picks its number format with one define, `+define+FMT_FP32`, `FMT_BF16` or `FMT_INT8` (no define is fp32); `make FMT=<f>` sets it (`Common/fmt.mk`). Only two kinds of code read it:

- `Common/src/sienna_fmt_pkg.sv`, the format package: widths (`DATA_WIDTH`, `ACC_DATA_WIDTH`, `RESULT_DATA_WIDTH`, `BIAS_DATA_WIDTH`), latencies, format-dependent constants and steps (`LOWEST_VALUE`, `ONE_VALUE`, `DROPOUT_KEEP_SCALE`, `fmt_greater_than`, `fmt_relu`, `fmt_drop`), flags (`HAS_REQUANT_EPILOGUE`, `HAS_RESIDUAL_ADD`) and the int8 parameter bundles (1-bit placeholders in float builds). `Common/models/fmt_pkg.py` is the one Python reader of it.
- The arithmetic units and the two wrappers `Fmt/src/fmt_mul.sv` and `fmt_add.sv`, which elaborate only the selected format's unit (fp32Multiplier and fp32Adder; bf16Multiplier, bf16WideMultiplier, bf16Adder and fp32ToBf16; int8Multiplier and int32Adder).

Everything else carries plain words. `make check-fmt` fails if any other file names a format.

## Regression

```bash
make regression          # every unit bench and model check once, then one table (make -j4 runs four at a time)
make regression/Adders/Int/check  # one point; python3 regression.py --action points lists them
make regression-summary  # the table again, from results/regression/
```

Each point runs in a private copy of the working tree (git's files, ignored outputs left out) and passes only on its own verdict (the bench's `RESULT: PASSED`, the model check's 0 mismatches, each lint's count line with 0 errors), never on a clean exit alone. The regression fails if any point fails or did not run. Each unit's Makefile still runs its benches alone, e.g. `make -C Adders/Int check`.

`Common/regress.py` is the regression engine every repo that holds this library uses for its own `make regression`.
