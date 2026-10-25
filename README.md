# ArithmeticLibrary

Arithmetic units in SystemVerilog (fp32, bf16 and int8 adders and multipliers, the int8 requantizer and quantized adder, the fp32-to-bf16 narrower, credit links), each with a bench against a reference (SoftFloat, a C model through DPI, or the Python models in `models/`).

The two int8 units take real scales encoded by the host (`ipu.encode_scale`, `ipu.encode_add`), so they work for any scale within the encoder's domain (the adder refuses input-to-output scale ratios of 2^23 or more), not one framework's arithmetic:

- `int8Requantizer` (`src/quantized/`) turns an int32 sum into an int8 output: it multiplies by the channel's scale, held as a 24-bit mantissa and a right shift, rounds half up, adds the zero point and clamps (4 cycles).
- `int8QuantizedAdder` (`src/quantized/`) adds two int8 tensors with different scales, as a residual connection does: each input's offset from its zero point is multiplied by its scale ratio (two 32-bit mantissas on one shared shift), then rounded, offset and clamped like the requantizer (6 cycles).

Both are checked against the exact real-valued result: every output must be within one output step, or 1%, of it.

## One format per build

A design built on this library picks its number format with one define, `+define+FMT_FP32`, `FMT_BF16` or `FMT_INT8` (no define is fp32); `make FMT=<f>` sets it (`scripts/fmt.mk`). Only two kinds of code read it:

- `src/fmt/sienna_fmt_pkg.sv`, the format package: widths (`DATA_WIDTH`, `ACC_DATA_WIDTH`, `RESULT_DATA_WIDTH`, `BIAS_DATA_WIDTH`), latencies, format-dependent constants and steps (`LOWEST_VALUE`, `ONE_VALUE`, `DROPOUT_KEEP_SCALE`, `fmt_greater_than`, `fmt_relu`, `fmt_drop`), flags (`HAS_REQUANT_EPILOGUE`, `HAS_RESIDUAL_ADD`) and the int8 parameter bundles (1-bit placeholders in float builds). `models/fmt_pkg.py` is the one Python reader of it.
- The arithmetic units and the two wrappers `src/fmt/fmt_mul.sv` and `fmt_add.sv`, which elaborate only the selected format's unit (fp32Multiplier and fp32Adder; bf16Multiplier, bf16WideMultiplier, bf16Adder and fp32ToBf16; int8Multiplier and int32Adder).

Everything else carries plain words. `make check-fmt` fails if any other file names a format.

## Regression

```bash
make regression          # every unit bench and model check once, then one table (make -j4 runs four at a time)
make regression/intAdder/check   # one point; python3 regression.py --action points lists them
make regression-summary  # the table again, from results/regression/
```

Each point runs in a private copy of the working tree (git's files, ignored outputs left out) and passes only on its own verdict (the bench's `RESULT: PASSED`, the model check's 0 mismatches, each lint's count line with 0 errors), never on a clean exit alone. The regression fails if any point fails or did not run. The one Makefile also runs each unit's benches alone as `make <unit>-<target>`, e.g. `make intAdder-check` (`make help` lists the units).

The layout: `src/` holds the RTL by function (`adders`, `multipliers`, `converters`, `dividers`, `quantized`, `fmt`, `credit`), `testbenches/top/` the format bench `TB_fmt` and its harnesses, `testbenches/units/` every unit bench with its DPI references and SoftFloat, `models/` the Python models and `scripts/` the shell, make and Python helpers.

`scripts/regress.py` is the regression engine every repo that holds this library uses for its own `make regression`.

## Standalone machine

Everything above runs on any Linux machine; nothing depends on the authors' servers.

**You need:** GNU make, git, a C++ compiler with C++20 coroutines (g++ 10 or later), Verilator 5.035 built with that compiler (the version every regression runs on), and Python 3 with the packages in `requirements.txt` (tested with Python 3.11). The released Verilator 5.052 is not supported yet: it runs SystolicMesh's regression and SIENNA's fp32 and int8 points, but stops on bf16 builds (gpnae_tail.sv), on GPNAE's lane bench (a zero-delay warning in TB_gpnae) and on the lint gates (its new warnings, and its removal of --xml-only, which check-hier reads). A Verilator configured with a g++ older than 10 omits the `-fcoroutines` its `--timing` builds need: put a `g++` wrapper that adds it first on `PATH`.

```bash
git clone https://github.com/SoHam-56/ArithmeticLibrary.git && cd ArithmeticLibrary
python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt   # every make below runs in this shell
make -j8 regression
```

Activate the venv in the shell that runs make: some checks call `python3` directly, and without the venv that is the system's Python, which may lack NumPy.

**Choosing N in `make -jN`:** each point is one small bench; the largest process of the whole regression peaked at 0.46 GB (measured, `make -j8` on an 8-core, 64 GB machine, 3 minutes 19 seconds), so N = your core count fits in a few GB. Nothing is skipped.

## Running with VCS

Every regression above runs on Verilator by default. The same regression also runs on Synopsys VCS, a 4-state simulator: it also models unknown (X) and floating (Z) bit values, which Verilator, a 2-state simulator, turns into 0 or 1.

**The authors have not run the VCS path yet** (no VCS license where it was written). The commands, the gates and the parsers are in place and checked without VCS; your run is the first real one.

**You need:** `vcs` on your `PATH` with a working license, a C++ compiler VCS can call, GNU make, and Python 3 with `pip install -r requirements.txt`.

**Run it:**

```bash
make -j4 regression SIM=vcs
```

**Read the table** (also written to `results/regression/regression.log`). Each row is one check: its name, its verdict, its time and its log. The last line is the overall verdict, for example `ARITHMETICLIBRARY REGRESSION PASS: 57 of 57 gated points passed; 12 reported, not gated; 4 not applicable to vcs`.

| Verdict | Meaning |
|---|---|
| `PASS` | the check met its gate: the same true-function and reference gates as the Verilator run |
| `FAIL (...)` | it did not; the bracket says why, the log says where |
| `N/A (...)` | the check tests something only Verilator has (its lint messages, its C++ harnesses); listed, never run |
| `..., reported, not gated` | a VCS lint (`+lint=all`): its counts are shown but do not fail the run until its warning baseline is recorded (below) |

**If something fails**, send back `results/regression/regression.log` and the log of each failing row (the path is on the row). A line such as `FAIL: X in output word 37 of test add (add_int32.txt)` means the design produced an unknown value where a number was expected; that is a real finding for the authors, not a set-up problem. A license or compile failure shows as `FAIL (exit N)` with VCS's own message in the log.

**Recording the lint baseline** (once, on the first clean run): `make <unit>-lint SIM=vcs RECORD=1` for each unit with a lint row writes `vcs_lint_baseline.txt`; commit it, and from then on a new VCS lint warning fails its row.

**Options:** `TRACE=1` writes waveforms (adds `-debug_access+all`); `XPROP=1` adds X-propagation (`-xprop=tmerge`); `RANDINIT=1 SEED=<n>` powers every register up random instead of X. Without them a VCS build is plain: no debug access, no waveform.

What maps to what:

| Verilator | VCS | Note |
|---|---|---|
| `--binary --timing --assert` | `vcs -full64 -sverilog -timescale=1ns/1ps` | VCS runs delays and assertions natively |
| `--top-module X` | `-top X` | |
| `-I<dir>`, `+define+X`, `-DX` | `+incdir+<dir>`, `+define+X` | |
| `-G<name>=<value>` | `-pvalue+<top>.<name>=<value>` | top-level parameters only, as with `-G` |
| DPI C/C++ files and `-CFLAGS`, SoftFloat's `softfloat.a` | the same files on the `vcs` line, `-CFLAGS` | compiled by VCS's C compiler |
| `--trace` (TRACE=1) | `-debug_access+all` (TRACE=1) | without TRACE, `+vcs+dumpvarsoff` silences a bench's own `$dumpvars` |
| `--x-initial unique` and `+verilator+rand+reset+2` | `+vcs+initreg+random` (compile) and `+vcs+initreg+<SEED>` (run), RANDINIT=1 | VCS's default is X power-up, stricter than Verilator's zeros |
| (none) | `-xprop=tmerge`, XPROP=1 | X-propagation through `if` and `case` |
| `+verilator+error+limit+100` | nothing | VCS carries on after `$error` by default |
| `--lint-only -Wall` | `+lint=all`, reported until its baseline is recorded | the Verilator lint points and the fmt points' lint lines are N/A under VCS |
| `-j`, `--build-jobs`, `--threads`, `SIM_THREADS` | `-j<cores>` (compile) | VCS simulates on one thread |
| `OPT_FAST=-O0`, the large code model | not applicable | Verilator build workarounds |
| Verilator C++ harnesses (`fmt` sweeps, `equiv`, `controls`, `mutants`) | not applicable | they drive a Verilated model from C++ |
| `/* verilator lint_off ... */` | ignored | comments to VCS |
