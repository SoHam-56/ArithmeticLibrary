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

## Standalone machine

Everything above runs on any Linux machine; nothing depends on the authors' servers.

**You need:** GNU make, git, a C++ compiler with C++20 coroutines (g++ 10 or later), Verilator built with that compiler (tested: 5.035 for every regression, and the released 5.052), and Python 3 with the packages in `requirements.txt` (tested with Python 3.11).

```bash
git clone https://github.com/SoHam-56/ArithmeticLibrary.git && cd ArithmeticLibrary
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
make -j8 regression PYTHON=$PWD/.venv/bin/python
```

**Choosing N in `make -jN`:** each point is one small bench; the largest process of the whole regression peaked at 0.46 GB (measured, `make -j8` on an 8-core, 64 GB machine, 3 minutes 19 seconds), so N = your core count fits in a few GB. Nothing is skipped.

## Running with VCS

Every regression above runs on Verilator by default. The same regression also runs on Synopsys VCS, a 4-state simulator: it also models unknown (X) and floating (Z) bit values, which Verilator, a 2-state simulator, turns into 0 or 1.

**The authors have not run the VCS path yet** (no VCS license where it was written). The commands, the gates and the parsers are in place and checked without VCS; your run is the first real one.

**You need:** `vcs` on your `PATH` with a working license, a C++ compiler VCS can call, GNU make, and Python 3 with `pip install -r requirements.txt`.

**Run it:**

```bash
make -j4 regression SIM=vcs
```

**Read the table** (also written to `results/regression/regression.log`). Each row is one check: its name, its verdict, its time and its log. The last line is the overall verdict, for example `ARITHMETICLIBRARY REGRESSION PASS: 57 of 57 gated points passed; 12 reported, not gated; 8 not applicable to vcs`.

| Verdict | Meaning |
|---|---|
| `PASS` | the check met its gate: the same true-function and reference gates as the Verilator run |
| `FAIL (...)` | it did not; the bracket says why, the log says where |
| `N/A (...)` | the check tests something only Verilator has (its lint messages, its C++ harnesses, the Vivado benches); listed, never run |
| `..., reported, not gated` | a VCS lint (`+lint=all`): its counts are shown but do not fail the run until its warning baseline is recorded (below) |

**If something fails**, send back `results/regression/regression.log` and the log of each failing row (the path is on the row). A line such as `FAIL: X in output word 37 of test add (add_int32.txt)` means the design produced an unknown value where a number was expected; that is a real finding for the authors, not a set-up problem. A license or compile failure shows as `FAIL (exit N)` with VCS's own message in the log.

**Recording the lint baseline** (once, on the first clean run): `make -C <unit> lint SIM=vcs RECORD=1` for each unit with a lint row writes `vcs_lint_baseline.txt`; commit it, and from then on a new VCS lint warning fails its row.

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
| `--lint-only -Wall` | `+lint=all`, reported until its baseline is recorded | the Verilator lint points and Fmt's lint lines are N/A under VCS |
| `-j`, `--build-jobs`, `--threads`, `SIM_THREADS` | `-j<cores>` (compile) | VCS simulates on one thread |
| `OPT_FAST=-O0`, the large code model | not applicable | Verilator build workarounds |
| Verilator C++ harnesses (`Fmt` sweeps, `equiv`, `controls`, `mutants`) | not applicable | they drive a Verilated model from C++ |
| `/* verilator lint_off ... */` | ignored | comments to VCS |

## Vivado DPI Linker Fix

This guide outlines how to configure Xilinx Vivado to use the host system's modern linker instead of its bundled, outdated version. This is often necessary when working with SystemVerilog DPI (Direct Programming Interface) and modern C++ standards.

## The Problem

Xilinx Vivado bundles its own version of `binutils` (including the `ld` linker) within its installation directory (`tps/lnx64`). This bundled version is often significantly older than the default system linker found on modern Linux distributions (e.g., Ubuntu 20.04/22.04, RHEL 8+).

When compiling DPI applications—especially those using C++14, C++17, or C++20—Vivado's internal `ld` often fails with:
* Symbol resolution errors.
* Incompatibilities with system `glibc` or `libstdc++`.
* Linker script syntax errors.

## The Solution

The fix involves forcing Vivado to use the host system's `/usr/bin/ld` by replacing the bundled binary with a symbolic link.

> **⚠️ Note:** This procedure modifies files inside your Vivado installation directory. Ensure you have write permissions (or use `sudo`) and follow the backup step below.

## Instructions

### 1. Identify Your Vivado Installation Path
Locate your Vivado installation. Common default paths include:
* `/tools/Xilinx/Vivado/<VERSION>`
* `/opt/Xilinx/Vivado/<VERSION>`
* `/home/<USER>/Xilinx/Vivado/<VERSION>`

### 2. Navigate to the Vivado `binutils` Directory
The linker is located deep in the `tps` (Third Party Software) directory. The specific `binutils` version folder (e.g., `binutils-2.37`) varies by Vivado release.

Run the following command, replacing `<INSTALL_PATH>` and `<VERSION>` with your actual values:

```bash
# General Syntax
cd <INSTALL_PATH>/Vivado/<VERSION>/tps/lnx64/binutils-*/bin/

# Example
# cd /tools/Xilinx/Vivado/2025.2/tps/lnx64/binutils-2.37/bin/
```

### 3. Back Up the Original Linker
Rename the existing `ld` binary to `ld.orig`. This acts as a backup, allowing you to easily revert changes if needed.

```bash
mv ld ld.bak
```

### 4. Link the System Linker
Create a symbolic link pointing from Vivado's local `ld` to your system's modern linker (`/usr/bin/ld`).

```bash
ln -s /usr/bin/ld ld
```

### 5. Verify the Change
Check that the link is valid and pointing to the correct location.

```bash
ls -l ld
```

Expected Output:
```
lrwxrwxrwx 1 user group 11 Jan 15 10:00 ld -> /usr/bin/ld
```

## ↩️ How to Revert
If you encounter unexpected issues with standard FPGA synthesis or implementation after this change, restore the original linker:

1. Navigate back to the `binutils/bin` directory.
2. Remove the symbolic link:
```bash
rm ld
```

3. Restore the backup:
```bash
mv ld.bak ld
```
