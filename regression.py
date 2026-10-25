#!/usr/bin/env python3
"""ArithmeticLibrary's make regression: every unit bench and model check once (the benches fix their own formats), then one table."""

import contextlib
import glob
import io
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(ROOT, "Common"))
import regress  # noqa: E402

TB = (r"^RESULT: PASSED",)  # the benches print RESULT and finish with status 0 either way
TB_BAD = (r"RESULT: FAILED", r"^FAILURE:")
LINT_BAD = (r"^%Warning-(?:LATCH|MULTIDRIVEN|UNOPTFLAT).*$",)
POINTS = [  # (unit, target, need, bad, firing scan)
    ("Common", "dump32", TB, TB_BAD, True), ("Common", "ipu", TB, TB_BAD, True),
    ("Common", "fpu", TB, TB_BAD, True), ("Common", "truth", TB + (r"^truth selftest: \d+ checks, 0 failures$",), TB_BAD, True),
    ("Common", "credit", (r"^credit lint: 0 warnings, 0 errors$",), (r"credit FAIL",), False),  # and CREDIT_OK 'credit OK' lines; the fault modes' lines quote the assertions they fire
    ("Adders/FP32", "verilator", (r"^SUCCESS: All \d+ vectors passed",), TB_BAD, True),
    ("Adders/Int", "verilator", TB, TB_BAD, True), ("Adders/Int", "check", TB, TB_BAD, True),
    ("Adders/Int", "lint", (), LINT_BAD, True),
    ("Multipliers/FP32", "verilator", (r"^SUCCESS: All \d+ vectors passed",), TB_BAD, True),
    ("Multipliers/Karatsuba", "verilator", (r"^PASS: Unsigned\(\d+\) and Signed\(\d+\) vectors passed",), (r"^FAIL:",), True),
    ("Multipliers/Int", "verilator", TB, TB_BAD, True), ("Multipliers/Int", "check", TB, TB_BAD, True),
    ("Multipliers/Int", "verilator16", TB, TB_BAD, True), ("Multipliers/Int", "check16", TB, TB_BAD, True),
    ("Multipliers/Int", "lint", (), LINT_BAD, True),
    ("Requantizer", "verilator", TB, TB_BAD, True), ("Requantizer", "lint", (), LINT_BAD, True),
    ("Requantizer", "shift_bad", (r"^FIRED$",), (r"^NOT-FIRED$",), False),  # its log shows the assertion's %Error
    ("QuantizedAdder", "verilator", TB, TB_BAD, True),
    ("QuantizedAdder", "lint", (), LINT_BAD, True), ("QuantizedAdder", "shift_bad", (r"^FIRED$",), (r"^NOT-FIRED$",), False),
    ("Common", "pkg_fp32", TB, TB_BAD, True), ("Common", "pkg_bf16", TB, TB_BAD, True), ("Common", "pkg_int8", TB, TB_BAD, True),  # the define map
]
NEW_UNITS = (("Multipliers/BF16", "bf16Multiplier", "verilator"), ("Adders/BF16", "bf16Adder", "verilator"),
             ("Multipliers/BF16Wide", "bf16WideMultiplier", "verilator"), ("Converters/FP32ToBF16", "fp32ToBf16", "check"),
             ("Multipliers/Int8", "int8Multiplier", "verilator"), ("Multipliers/Int16", "int16Multiplier", "verilator"),
             ("Multipliers/Int24", "int24Multiplier", "verilator"), ("Adders/Int32", "int32Adder", "verilator"))  # the per-format units
POINTS += [(u, t, TB + (rf"^{top}: \d+ .* 0 errors", ), TB_BAD, True) for u, top, t in NEW_UNITS]  # each on its direct reference bench
POINTS += [(u, "lint", (rf"^lint {top}: 0 warnings, 0 errors$",), LINT_BAD, True) for u, top, _ in NEW_UNITS]  # lint clean; make -C Fmt equiv
MUTANT_OK = (r"^mutant \S+ caught by its bench: ",)
MUTANT_BAD = (r"SURVIVED", r"^mutant \S+ FAIL")
POINTS += [(u, "mutant", MUTANT_OK, MUTANT_BAD, False) for u, *_ in NEW_UNITS]  # testbenches/mutant.sed: a planted fault the unit's own bench must fail
POINTS += [("Common", "pkg_mutant", MUTANT_OK, MUTANT_BAD, False)]  # the define map's planted fault against TB_sienna_fmt_map
def mutant_total():
    """Fmt's mutant count: one per line of testbenches/mutants.list, two for a 'y' line (TB_fmt and the sweep)."""
    rows = [ln.rstrip("\n").split("|") for ln in open(os.path.join(ROOT, "Fmt", "testbenches", "mutants.list")) if ln.strip() and not ln.startswith("#")]
    return sum(2 if r[6] == "y" else 1 for r in rows)


MUTANT_TOTAL = mutant_total()
FMT_POINTS = ("mul_fp32", "mul_bf16_o16", "mul_bf16_o32", "mul_int8_o16", "mul_int8_o32", "add_fp32", "add_bf16", "add_bf16_w16", "add_int8",
              "cmp_fp32", "cmp_bf16", "cmp_int8", "relu_fp32", "relu_bf16", "relu_int8")  # fmt_mul and fmt_add at every width, fmt_greater_than and fmt_relu, per define
POINTS += [("Fmt", p, TB + (rf"^lint \S+ {p}: 0 library warnings, 0 new unit warnings \(\d+ in the recorded baseline\), 0 unplaced warnings, 0 errors$",), TB_BAD, True)
           for p in FMT_POINTS]  # lint clean: no warning in new code, none beyond the recorded baseline in the existing units
POINTS += [
    ("Fmt", "truefn", TB + (r"^truefn selftest: \d+ checks, 0 failures$", r"^test_truefn: \d+ checks, 0 failures$",
                            r"^sweep selftest: \d+ checks, 0 failures$"), TB_BAD, True),
    ("Fmt", "fmt_pkg", TB + (r"^fmt_pkg selftest: \d+ checks, 0 failures$",), TB_BAD, True),
    ("Fmt", "check_fmt", (r"^check_fmt OK: the tree passes$", r"^check_fmt OK: C4 "), (r"check_fmt FAIL",), True),
    ("Fmt", "controls", (r"^controls OK: FMT=fp16 stops make$", r"^controls OK: FMT_INT8 with FMT_BF16 ", r"^controls OK: FMT_INT8 with FMT_FP32 ",
                         r"^controls OK: FMT_BF16 with FMT_FP32 ", r"^controls OK: the elaboration check repeats it$", r"^controls OK: no define elaborates fp32$",
                         r"^controls OK: a sweep harness missing WRAPPER_DATA_WIDTH does not build$",
                         r"^controls OK: a sweep harness missing EXT_DATA_WIDTH does not build$", r"^controls OK: a misdecoded sweep fails: FAIL \(every gated row is decided by the floor\) ",
                         r"^controls OK: a warning planted in existing code fails the lint gate: NEW WARNING ",
                         r"^controls OK: a warning planted in new code fails the lint gate: NEW WARNING ",
                         r"^controls OK: a %Warning line with no location fails the lint gate$",
                         r"^controls OK: make lint-baseline refuses to re-record over a changed existing file$")
     + tuple(rf"^controls OK: {w} refused$" for w in ("fp32 fmt_mul -GDATA_WIDTH=16", "bf16 fmt_mul -GEXT_DATA_WIDTH=24", "int8 fmt_mul -GDATA_WIDTH=16",
                                                     "int8 fmt_mul -GEXT_DATA_WIDTH=12", "bf16 fmt_add -GDATA_WIDTH=8", "int8 fmt_add -GDATA_WIDTH=8")),
     (r"controls FAIL",), True),
    ("Fmt", "mutants", (rf"^mutants: {MUTANT_TOTAL} of {MUTANT_TOTAL} caught$",), (r"SURVIVED",), False),  # pinned to the list; lines quote failures
    ("Fmt", "lint_tops", tuple(rf"^lint fmt_fn_\w+ {n}: 0 library warnings, 0 new unit warnings \(\d+ in the recorded baseline\), 0 unplaced warnings, 0 errors$"
                              for n in ("narrow_fp32", "narrow_bf16", "requantize_int8", "quantized_add_int8")), (r"NEW WARNING", r"UNPLACED"), True),
    ("Fmt", "equiv_quick", TB + (r"^EQUIV: 4 of 4 pairs equal$",), TB_BAD, True),  # make -C Fmt equiv is the proof; this runs its harness on a slice
]
CREDIT_OK = 11  # TB_credit_link: 8 (STAGES, MODE) runs and 3 $fatal modes, one 'credit OK' line each
LINT_RUNS = {"Adders/Int/lint": 1, "Multipliers/Int/lint": 2, "Requantizer/lint": 2, "QuantizedAdder/lint": 2}  # Common/lint.sh lines each lint prints, one per configuration
LINT_RUNS.update({f"{u}/lint": 1 for u, *_ in NEW_UNITS})
TABLE = {f"{u}/{t}": (u, t, need, bad, firing) for u, t, need, bad, firing in POINTS}
# ── SIM=vcs: each point's VCS target, the Verilator-only points, and the VCS lint labels ──
VCS_TARGET = {"verilator": "vcs", "verilator16": "vcs16"}  # the reference benches' VCS targets; every other target takes SIM=vcs itself
VERILATOR_ONLY = {  # point (or target) -> why it means nothing under VCS
    "vivado_tb": "a Vivado bench, run here on Verilator; the Vivado removal takes it out",
    "Fmt/controls": "Verilator's lint and preprocessor messages and its C++ sweep harness (sweep_fmt.cpp) are what it checks",
    "Fmt/mutants": "each kill is judged by TB_fmt and by a Verilator C++ sweep harness (sweep_fmt.cpp drives a Verilated model)",
    "Fmt/lint_tops": "verilator --lint-only against Verilator's recorded lint baseline; the unit lint points run VCS's +lint=all",
    "Fmt/equiv_quick": "a Verilator C++ harness (eq_fmt.cpp drives Verilated models)",
}
VCS_LINT_LABELS = {"Adders/Int/lint": ("intAdder",), "Multipliers/Int/lint": ("intMultiplier W=8", "intMultiplier W=16"),
                   "Requantizer/lint": ("int8Requantizer", "int8Requantizer (assertions)"),
                   "QuantizedAdder/lint": ("int8QuantizedAdder", "int8QuantizedAdder (assertions)")}
VCS_LINT_LABELS.update({f"{u}/lint": (top,) for u, top, _ in NEW_UNITS})
VCS_LINT_BASELINE = os.path.join(ROOT, "vcs_lint_baseline.txt")  # written by make -C <unit> lint SIM=vcs RECORD=1 on a real VCS run


def vcs_lint_recorded(labels, path=VCS_LINT_BASELINE):
    """True when the baseline holds every label: until then a VCS lint point is reported, not gated."""
    have = {ln.split("\t")[0] for ln in open(path) if ln.strip() and not ln.startswith("#")} if os.path.exists(path) else set()
    return all(x in have for x in labels)


class ArilSpec(regress.Spec):
    title = "ARITHMETICLIBRARY REGRESSION"
    artifacts = ()  # each bench's dumps stay in its Verilator directory
    drop = ("RANDOM",)  # Requantizer's and QuantizedAdder's Makefiles take it with ?=: a caller's would change a point's vectors (FMT: regress.MAKE_VARS)

    def points(self, small, formats):
        return ["selftest"] + list(TABLE)

    def parse(self, name):
        if name != "selftest" and name not in TABLE:
            raise ValueError(f"{name}: not a point; regression.py --action points lists them")
        return {"n": 0, "name": name}

    def argv(self, name, opts):
        if name == "selftest":
            return [sys.executable, "regression.py", "--action", "selftest"]
        u, t = TABLE[name][:2]
        if self.sim == "vcs":
            return ["make", "-C", u, VCS_TARGET.get(t, t), "SIM=vcs"]
        return ["make", "-C", u, t]

    def not_applicable(self, name):
        if self.sim != "vcs" or name == "selftest":
            return None
        return VERILATOR_ONLY.get(name) or VERILATOR_ONLY.get(TABLE[name][1])

    def gated(self, name):
        return not (self.sim == "vcs" and name in VCS_LINT_LABELS and not vcs_lint_recorded(VCS_LINT_LABELS[name]))

    def verdict(self, name, text, rc):
        if name == "selftest":
            return regress.marker_verdict(text, rc, need=(r"^ALL \d+ PASSED$",))
        _, t, need, bad, firing = TABLE[name]
        if self.sim == "vcs":
            return self.vcs_verdict(name, text, rc)
        v = regress.marker_verdict(text, rc, need, bad, firing)
        if v == "PASS" and name in LINT_RUNS:  # a clean exit is not a lint: each configuration's count line, with 0 errors
            n = len(re.findall(r"^lint .*: \d+ warnings, 0 errors$", regress.ANSI.sub("", text), re.M))
            v = "PASS" if n == LINT_RUNS[name] else f"FAIL ({n} of {LINT_RUNS[name]} lint runs counted)"
        if v == "PASS" and t == "credit":
            n = len([x for x in regress.ANSI.sub("", text).splitlines() if x.startswith("credit OK: ")])
            v = "PASS" if n == CREDIT_OK else f"FAIL ({n} of {CREDIT_OK} credit checks passed)"
        return v


    def vcs_verdict(self, name, text, rc):
        """The Verilator gate less what only Verilator prints: a VCS lint's own count lines, credit's lint line, the Fmt points' lint line."""
        u, t, need, bad, firing = TABLE[name]
        if name in VCS_LINT_LABELS:
            v = regress.marker_verdict(text, rc, (), (r"NEW WARNING", r"^vcs lint .*: FAIL"), True)
            labels = re.findall(r"^vcs lint (.+): \d+ warnings, 0 errors$", regress.ANSI.sub("", text), re.M)
            want = VCS_LINT_LABELS[name]
            return v if v != "PASS" else ("PASS" if sorted(labels) == sorted(want) else f"FAIL ({len(labels)} of {len(want)} VCS lint runs counted)")
        if t == "credit":
            need = (r"^credit lint: not applicable to VCS",)
        if u == "Fmt" and t in FMT_POINTS:
            need = TB + (rf"^lint {t}: not applicable to VCS",)
        v = regress.marker_verdict(text, rc, need, bad, firing)
        if v == "PASS" and t == "credit":
            n = len([x for x in regress.ANSI.sub("", text).splitlines() if x.startswith("credit OK: ")])
            v = "PASS" if n == CREDIT_OK else f"FAIL ({n} of {CREDIT_OK} credit checks passed)"
        return v


SPEC = ArilSpec(ROOT, os.path.join(ROOT, "results", "regression"))


# ── self-tests (the engine's and this list's; no simulator) ──

TESTS = []


def selftest(fn):
    TESTS.append(fn)
    return fn


def _exit(fn, *a, **k):
    """(exit code, stdout) of a function that ends in sys.exit."""
    with contextlib.redirect_stdout(io.StringIO()) as out:
        try:
            fn(*a, **k)
            code = 0
        except SystemExit as e:
            code = e.code if isinstance(e.code, int) else 1
    return code, out.getvalue()


def _args(**k):
    """Engine options as main() parses them."""
    d = dict(action="point", name=None, results="", run="", keep_going=False, small=False, formats=None, model_dir="")
    d.update(k)
    return type("A", (), d)()


class FakeSpec(regress.Spec):
    """Two formats, two sizes' worth of points, one reported, one that needs a directory."""
    title, formats, sized, reported = "FAKE REGRESSION", ("f1", "f2"), True, frozenset({"f2/acc"})

    def points(self, small, formats):
        return [f"{f}/{k}" for f in formats for k in ("acc", "N8_T2/run", "N32_T8/run", "N8_T2/mod") if k != "acc" or f == "f2"
                if not (small and "N32" in k)]

    def parse(self, name):
        if name.split("/")[0] not in self.formats:
            raise ValueError(name)
        return {"n": int(name.split("/")[1][1:].split("_")[0]) if "_T" in name else 0}

    def argv(self, name, opts):
        return [sys.executable, "-c", opts.probe]

    def verdict(self, name, text, rc):
        return regress.marker_verdict(text, rc, need=(r"^ok$",))

    def not_run(self, name, opts):
        return None if not name.endswith("/mod") or opts.model_dir else "DIR unset: make regression DIR=<d>"


@selftest
def test_threads_and_environment():
    for flags, want in (("s", None), ("", None), ("s -j4 --jobserver-auth=3,4", "2"), ("s -j3 --jobserver-auth=3,4", "2"), ("s -j16", "1"),
                        ("s -j", "1"), ("ks -j1", "8"), (" -- TEST=x", None)):
        assert regress.sim_threads(flags, 8) == want, (flags, regress.sim_threads(flags, 8), want)
    spec = FakeSpec(ROOT, "")
    saved = {k: os.environ.get(k) for k in ("TRACE", "OPT_FAST", "SIM_THREADS", "FMT", "EXTRA_FLAGS")}
    os.environ.update(TRACE="vcd", OPT_FAST="-O3", SIM_THREADS="5", FMT="f1", EXTRA_FLAGS="-DX")
    try:
        small, big, par = regress.point_env(spec, "f1/N8_T2/run", "s", 8), regress.point_env(spec, "f1/N32_T8/run", "s", 8), regress.point_env(spec, "f1/N8_T2/run", "s -j2", 8)
    finally:
        for k, v in saved.items():
            os.environ.pop(k) if v is None else os.environ.__setitem__(k, v)
    assert small["TRACE"] == big["TRACE"] == "0" and "OPT_FAST" not in small and big["OPT_FAST"] == "-O0" and par["SIM_THREADS"] == "4"
    assert not {"SIM_THREADS", "FMT", "EXTRA_FLAGS"} & (set(small) | set(big))  # the caller's variables never reach a point
    affinity = os.__dict__.pop("sched_getaffinity", None)  # macOS has no sched_getaffinity: the share comes from os.cpu_count()
    try:
        env = regress.point_env(spec, "f1/N8_T2/run", "s -j2")
    finally:
        if affinity:
            os.sched_getaffinity = affinity
    assert env["SIM_THREADS"] == str(max(1, os.cpu_count() // 2)), env.get("SIM_THREADS")


@selftest
def test_verdict_rules():
    v = regress.marker_verdict
    assert v("RESULT: PASSED\n", 0, TB, TB_BAD) == "PASS" and v("RESULT: PASSED\n", 2, TB, TB_BAD) == "FAIL (exit 2)"
    assert v("done\n", 0, TB, TB_BAD) == "FAIL (no 'RESULT: PASSED')"  # finishing cleanly is not a pass
    assert v("RESULT: PASSED\nRESULT: FAILED\n", 0, TB, TB_BAD) == "FAIL (log: RESULT: FAILED)"  # the benches exit 0 when they fail
    assert v("RESULT: PASSED\nlane 3 RESULT: FAILED at 7\n", 0, TB, TB_BAD) == "FAIL (log: lane 3 RESULT: FAILED at 7)"  # the whole line, not the match
    assert v("\x1b[92mRESULT: PASSED\x1b[0m\n", 0, TB, TB_BAD) == "PASS"
    assert v("RESULT: PASSED\n[x] Assertion failed in t\n", 0, TB, TB_BAD) == "FAIL (log: [x] Assertion failed in t)"
    assert v("%Error: bad\nREJECTED\n", 0, (r"^REJECTED$",), (), False) == "PASS" and v("%Error: bad\nREJECTED\n", 0, (r"^REJECTED$",)) == "FAIL (log: %Error: bad)"
    assert v("%Warning-LATCH: x.sv:3: latch\n", 0, (), LINT_BAD) == "FAIL (log: %Warning-LATCH: x.sv:3: latch)" and v("%Warning-UNUSED: y\n", 0, (), LINT_BAD) == "PASS"
    ok = "credit lint: 0 warnings, 0 errors\n" + "credit OK: m\n" * CREDIT_OK
    assert SPEC.verdict("Common/credit", ok, 0) == "PASS" and SPEC.verdict("Common/credit", ok.replace("credit OK: m\n", "", 1), 0) == "FAIL (10 of 11 credit checks passed)"
    assert SPEC.verdict("Common/credit", ok + "credit FAIL: STAGES=0 MODE=1\n", 1) == "FAIL (exit 1)"
    assert SPEC.verdict("Common/credit", ok + "credit OK: MODE=8 fired: [0] %Fatal: credit_reg.sv:14: Assertion failed in TB\n", 0) == "FAIL (12 of 11 credit checks passed)"
    assert SPEC.verdict("Adders/FP32/verilator", "SUCCESS: All 30000 vectors passed!\n", 0) == "PASS"
    assert SPEC.verdict("Adders/FP32/verilator", "FAILURE: 3 errors detected.\n", 0).startswith("FAIL")
    assert SPEC.verdict("Multipliers/Karatsuba/verilator", "PASS: Unsigned(10) and Signed(10) vectors passed.\n", 0) == "PASS"
    assert SPEC.verdict("Converters/FP32ToBF16/check", "RESULT: PASSED\n", 0) == "FAIL (no 'fp32ToBf16: \\d+ .* 0 errors')"
    tr = "truth selftest: 126 checks, 0 failures\nRESULT: PASSED\ntest_truth: 97 checks, 0 failures\nRESULT: PASSED\n"
    assert SPEC.verdict("Common/truth", tr, 0) == "PASS" and SPEC.verdict("Common/truth", tr.split("test_truth")[1], 0).startswith("FAIL (no 'truth selftest")  # the selftest must have run
    assert SPEC.verdict("Common/truth", tr.replace("PASSED\ntest", "FAILED\ntest"), 0).startswith("FAIL (log: RESULT: FAILED")
    assert SPEC.verdict("Requantizer/shift_bad", "%Error: int8Requantizer: shift 56 above 55\nFIRED\n", 0) == "PASS"  # its own %Error is the point
    assert SPEC.verdict("Requantizer/shift_bad", "NOT-FIRED\n", 2).startswith("FAIL")  # the assertion did not fire
    assert SPEC.verdict("selftest", "ALL 9 PASSED\n", 0) == "PASS" and SPEC.verdict("selftest", "1 of 9 FAILED\n", 0).startswith("FAIL")
    two = "lint intMultiplier WIDTH=8: 3 warnings, 0 errors\nlint intMultiplier WIDTH=16: 2 warnings, 0 errors\n"
    assert SPEC.verdict("Multipliers/Int/lint", two, 0) == "PASS" and SPEC.verdict("Multipliers/Int/lint", "", 0) == "FAIL (0 of 2 lint runs counted)"  # a clean exit is not a lint
    assert SPEC.verdict("Multipliers/Int/lint", two.split("\n")[0] + "\n", 0) == "FAIL (1 of 2 lint runs counted)"
    assert SPEC.verdict("Multipliers/Int/lint", two.replace("0 errors\nlint intMultiplier WIDTH=16", "1 errors\nlint intMultiplier WIDTH=16"), 0).startswith("FAIL")


@selftest
def test_points_and_commands():
    pts = SPEC.points(False, [])
    assert pts == SPEC.points(True, []) and pts[0] == "selftest" and len(pts) == len(set(pts)) == 1 + len(POINTS), len(pts)
    for name in pts:
        u = name.rsplit("/", 1)[0]
        assert name == "selftest" or os.path.isfile(os.path.join(ROOT, u, "Makefile")), name
    assert SPEC.argv("Requantizer/shift_bad", None) == ["make", "-C", "Requantizer", "shift_bad"]
    for name in pts[1:]:  # every target exists in its unit's Makefile
        u, t = TABLE[name][:2]
        r = subprocess.run(["make", "-n", "-C", os.path.join(ROOT, u), t], capture_output=True, text=True, env={k: v for k, v in os.environ.items() if not k.startswith("MAKE")})
        assert r.returncode == 0, (name, r.stderr[-200:])
        n_bin = r.stdout.count("--binary")
        assert r.stdout.count("--build-jobs 0") >= n_bin and (not n_bin or f"-j {regress._cores()} " in r.stdout), name  # every Verilator build takes every core, in parallel
    for name in [p for p in pts if p.endswith("/lint")]:  # every lint prints its counts, one line per configuration
        r = subprocess.run(["make", "-n", "-C", os.path.join(ROOT, name[:-5]), "lint"], capture_output=True, text=True)
        assert len(re.findall(r"(?m)^bash \S+/Common/lint\.sh ", r.stdout)) == LINT_RUNS[name], (name, r.stdout[-300:])  # through bash: a clone may drop the x bit
    for u in ("Adders/FP32", "Multipliers/FP32", "Multipliers/Karatsuba"):  # the threaded benches take their share under make -j
        r = subprocess.run(["make", "-n", "-C", os.path.join(ROOT, u), "verilator", "SIM_THREADS=3"], capture_output=True, text=True)
        assert "--threads 3" in r.stdout, (u, r.stdout[-300:])
        r = subprocess.run(["make", "-n", "-C", os.path.join(ROOT, u), "verilator"], capture_output=True, text=True, env={k: v for k, v in os.environ.items() if k != "SIM_THREADS" and not k.startswith("MAKE")})
        assert re.search(r"--threads 1(?!\d)", r.stdout), (u, r.stdout[-300:])  # a lone small bench simulates on one thread
    try:
        SPEC.parse("Adders/Int/nosuch")
    except ValueError:
        pass
    else:
        raise AssertionError("parse accepted Adders/Int/nosuch")


NO_POINT_SRC = ("Divider/FP32", "Multipliers/Radix4Booth")  # sources with no bench of their own: fp32Divider (no instance since GPNAE's Taylor lane), R4Booth (in Karatsuba's)


@selftest
def test_every_unit_has_points():
    """Every unit directory with a Makefile or a src/ directory appears in POINTS, so a new unit cannot be left out of make regression."""
    mk = glob.glob(os.path.join(ROOT, "*", "Makefile")) + glob.glob(os.path.join(ROOT, "*", "*", "Makefile"))
    src = glob.glob(os.path.join(ROOT, "*", "src")) + glob.glob(os.path.join(ROOT, "*", "*", "src"))
    units = sorted({os.path.relpath(os.path.dirname(p), ROOT) for p in mk + src} - set(NO_POINT_SRC))
    listed = {u for u, *_ in POINTS}
    missing = [u for u in units if u not in listed]
    assert len(units) >= 17 and not missing, f"units without a make regression point: {missing}"


@selftest
def test_every_new_unit_has_its_bench():
    """Each per-format unit has a direct reference bench point and a lint point, and the bench's need line names the unit."""
    for u, top, t in NEW_UNITS:
        assert f"{u}/{t}" in TABLE and f"{u}/lint" in TABLE, u
        assert SPEC.verdict(f"{u}/{t}", f"{top}: 10 vectors against the reference, 0 errors\nRESULT: PASSED\n", 0) == "PASS", u
        assert SPEC.verdict(f"{u}/{t}", f"{top}: 10 vectors against the reference, 3 errors\nRESULT: FAILED\n", 0) != "PASS", u


@selftest
def test_mutants_are_pinned():
    """Fmt/mutants passes only at the list's full count, and every per-format unit has a planted fault of its own."""
    assert MUTANT_TOTAL >= 30
    assert SPEC.verdict("Fmt/mutants", f"mutants: {MUTANT_TOTAL} of {MUTANT_TOTAL} caught\n", 0) == "PASS"
    assert SPEC.verdict("Fmt/mutants", f"mutants: {MUTANT_TOTAL - 1} of {MUTANT_TOTAL - 1} caught\n", 0) != "PASS"
    for u, *_ in NEW_UNITS:
        assert f"{u}/mutant" in TABLE and os.path.exists(os.path.join(ROOT, u, "testbenches", "mutant.sed")), u
        assert SPEC.verdict(f"{u}/mutant", "mutant x SURVIVED its bench\n", 1) != "PASS", u
    assert SPEC.verdict("Common/pkg_mutant", "mutant x caught by its bench: 1 errors\n", 0) == "PASS"


@selftest
def test_fmt_points_match_the_makefile():
    """FMT_POINTS is Fmt/Makefile's point list (make -C Fmt points), so a point added there cannot be left out of make regression."""
    r = subprocess.run(["make", "-s", "--no-print-directory", "-C", os.path.join(ROOT, "Fmt"), "points"], capture_output=True, text=True,
                       env={k: v for k, v in os.environ.items() if not k.startswith("MAKE")})
    mk = r.stdout.split()
    assert r.returncode == 0 and mk, r.stderr[-200:]
    assert list(FMT_POINTS) == mk, (sorted(set(mk) - set(FMT_POINTS)), sorted(set(FMT_POINTS) - set(mk)))


CONTROL_LINES = """controls OK: FMT=fp16 stops make
controls OK: FMT_INT8 with FMT_BF16 stops the preprocessor
controls OK: FMT_INT8 with FMT_FP32 stops the preprocessor
controls OK: FMT_BF16 with FMT_FP32 stops the preprocessor
controls OK: the elaboration check repeats it
controls OK: no define elaborates fp32
controls OK: a sweep harness missing WRAPPER_DATA_WIDTH does not build
controls OK: a sweep harness missing EXT_DATA_WIDTH does not build
controls OK: a misdecoded sweep fails: FAIL (every gated row is decided by the floor) (n 16777216 miss 0, floor_only 16777216)
controls OK: a warning planted in existing code fails the lint gate: NEW WARNING add_fp32: %Warning-UNUSEDSIGNAL: Adders/FP32/src/fp32Adder.sv:266
controls OK: a warning planted in new code fails the lint gate: NEW WARNING add_fp32: %Warning-UNUSEDSIGNAL: Fmt/src/fmt_add.sv:45
controls OK: a %Warning line with no location fails the lint gate
controls OK: make lint-baseline refuses to re-record over a changed existing file
controls OK: fp32 fmt_mul -GDATA_WIDTH=16 refused
controls OK: bf16 fmt_mul -GEXT_DATA_WIDTH=24 refused
controls OK: int8 fmt_mul -GDATA_WIDTH=16 refused
controls OK: int8 fmt_mul -GEXT_DATA_WIDTH=12 refused
controls OK: bf16 fmt_add -GDATA_WIDTH=8 refused
controls OK: int8 fmt_add -GDATA_WIDTH=8 refused
"""  # make -C Fmt controls (lane C's run rs3_r6_n1_green), the planted-warning lines cut short


@selftest
def test_every_control_is_required():
    """Fmt/controls passes only with every control's OK line, and every 'controls OK' echo in Fmt/Makefile has a line here."""
    v = SPEC.verdict
    assert v("Fmt/controls", CONTROL_LINES, 0) == "PASS"
    lines = CONTROL_LINES.splitlines(keepends=True)
    kept = [ln for i, ln in enumerate(lines) if v("Fmt/controls", "".join(lines[:i] + lines[i + 1:]), 0) == "PASS"]
    assert not kept, f"controls passes without: {kept}"
    other = CONTROL_LINES.replace("FAIL (every gated row is decided by the floor)", "FAIL (3 misses beyond the bound)")
    assert v("Fmt/controls", other, 0) != "PASS", "the misdecode control passes on a FAIL other than its floor-decided one"
    mk = open(os.path.join(ROOT, "Fmt", "Makefile")).read()
    for echo in re.findall(r'echo "controls OK: ([^"$]*)', mk):
        assert any(ln.startswith("controls OK: " + echo) for ln in lines), f"no control line for the echo 'controls OK: {echo}'"
    assert len(re.findall(r"\$\(call bad_width,", mk)) == sum(ln.endswith(" refused\n") for ln in lines)


@selftest
def test_point_drops_unit_variables():
    """A point never sees the caller's RANDOM, which the Requantizer and QuantizedAdder Makefiles take with ?=."""
    names = ("RANDOM",)
    saved = {k: os.environ.get(k) for k in names}
    os.environ.update(RANDOM="10")
    try:
        env = regress.point_env(SPEC, "QuantizedAdder/verilator", "s", 8)
    finally:
        for k, v in saved.items():
            os.environ.pop(k) if v is None else os.environ.__setitem__(k, v)
    assert not set(names) & set(env), sorted(set(names) & set(env))


@selftest
def test_make_echo_does_not_fire_the_scan():
    """No point of a unit with a RUN_CHECKED gate prints a command line that regress.py's firing scan (Assertion failed, %Error) matches: the gate spells them [f] and [E]. (make -n also lists @-silenced lines, so units without a gate are left out.)"""
    bad = []
    for name in SPEC.points(False, [])[1:]:
        u, t = TABLE[name][:2]
        if not re.search(r"(?m)^RUN_CHECKED\s*=", open(os.path.join(ROOT, u, "Makefile")).read()):
            continue
        r = subprocess.run(["make", "-n", "-C", os.path.join(ROOT, u), t], capture_output=True, text=True, env={k: v for k, v in os.environ.items() if not k.startswith("MAKE")})
        m = regress.FIRING.search(r.stdout)
        if m and TABLE[name][4]:  # lint_bad shows its own %Error: its point does not scan
            bad.append((name, m.group(0).strip()[:60]))
    assert not bad, bad


@selftest
def test_point_runs_in_a_copy():
    with tempfile.TemporaryDirectory() as d:
        src, res = os.path.join(d, "tree"), os.path.join(d, "res")
        for f in ("a.txt", "sub/b.txt", "testbenches/results/old.log", "w.vcd", "Verilator/V.mk"):
            os.makedirs(os.path.dirname(os.path.join(src, f)), exist_ok=True)
            open(os.path.join(src, f), "w").write(f)
        spec = FakeSpec(src, res)
        probe = ("import os, sys; print('cwd', os.getcwd()); print('files', sorted(os.path.relpath(os.path.join(r, f)) for r, _, fs in os.walk('.') for f in fs));"
                 "print('env', os.environ.get('TRACE'), os.environ.get('OPT_FAST')); os.makedirs('testbenches/results', exist_ok=True);"
                 "open('testbenches/results/t.log', 'w').write('kept'); print('ok' if '{ok}' == '1' else 'no'); sys.exit(0 if '{ok}' == '1' else 3)")

        def point(name, ok, **k):
            code, out = _exit(regress.run_point, spec, _args(name=name, results=res, run="r9", probe=probe.format(ok=ok), **k))
            return code, open(os.path.join(res, name + ".log")).read(), json.load(open(os.path.join(res, name + ".json"))), out
        code, log, rec, out = point("f1/N8_T2/run", "1")
        assert code == 0 and rec["rc"] == 0 and rec["run"] == "r9" and rec["not_run"] is None and "f1/N8_T2/run: PASS" in out, (code, rec, out)
        cwd = next(x.split(" ", 1)[1] for x in log.splitlines() if x.startswith("cwd "))
        assert os.path.realpath(cwd) != os.path.realpath(src) and not os.path.exists(cwd), cwd  # a private copy, removed afterwards
        files = next(x for x in log.splitlines() if x.startswith("files "))
        assert "a.txt" in files and "sub/b.txt" in files and "w.vcd" not in files and "old.log" not in files and "V.mk" not in files, files
        assert "env 0 None" in log and "# env: TRACE=0\n" in log and not os.path.exists(os.path.join(res, "f1/N8_T2/run.artifacts")), log
        code, log, rec, out = point("f2/N32_T8/run", "0")
        assert code == 1 and rec["rc"] == 3 and "env 0 -O0" in log and "# env: TRACE=0 OPT_FAST=-O0\n" in log and "f2/N32_T8/run: FAIL (exit 3)" in out, (code, rec, out)
        assert open(os.path.join(res, "f2/N32_T8/run.artifacts/testbenches/results/t.log")).read() == "kept"  # a failing point keeps its results
        assert point("f2/N32_T8/run", "0", keep_going=True)[0] == 0  # inside make regression a failure does not stop the other points
        code, log, rec, out = point("f1/N8_T2/mod", "1")
        assert code == 1 and rec["not_run"] == "DIR unset: make regression DIR=<d>" and "cwd" not in log and "f1/N8_T2/mod: NOT RUN (DIR unset" in out, (rec, out)
        assert point("f1/N8_T2/mod", "1", model_dir="/m")[0] == 0
        assert _exit(regress.run_point, spec, _args(name="f9/x", results=res))[0] != 0  # a name the spec does not run
        class DirSpec(FakeSpec):  # the point sees the directory it was given, made absolute where make regression ran
            def argv(self, name, opts):
                return [sys.executable, "-c", f"print('dir ' + {opts.model_dir!r}); print('ok')"]

            def not_run(self, name, opts):
                return None if os.path.isabs(opts.model_dir) else f"relative {opts.model_dir}"
        os.makedirs(os.path.join(d, "models"))
        here = os.getcwd()
        os.chdir(d)
        try:
            code, _ = _exit(regress.main, DirSpec(src, res), ["--action", "point", "--name", "f1/N8_T2/mod", "--results", res, "--model-dir", "models"])
        finally:
            os.chdir(here)
        log = open(os.path.join(res, "f1/N8_T2/mod.log")).read()
        assert code == 0 and f"dir {os.path.join(d, 'models')}" in log, log  # a relative MODEL_DIR would not exist in the private copy


@selftest
def test_point_retries_a_verilator_internal_error():
    with tempfile.TemporaryDirectory() as d:
        src, res, cnt = os.path.join(d, "tree"), os.path.join(d, "res"), os.path.join(d, "count")
        os.makedirs(src)
        open(os.path.join(src, "a.txt"), "w").write("a")
        spec = FakeSpec(src, res)
        # The stub counts its attempts outside the copy; attempt k prints line[k] and exits code[k] (the last entry repeats), both read from a file.
        script = os.path.join(d, "script.json")
        stub = (f"import json, os, sys; p = {cnt!r}; k = int(open(p).read()) if os.path.exists(p) else 0; open(p, 'w').write(str(k + 1));"
                f"lines, codes = json.load(open({script!r})); print(lines[min(k, len(lines) - 1)]); sys.exit(codes[min(k, len(codes) - 1)])")

        def point(name, lines, codes):
            if os.path.exists(cnt):
                os.remove(cnt)
            json.dump([lines, codes], open(script, "w"))
            code, out = _exit(regress.run_point, spec, _args(name=name, results=res, run="r9", probe=stub))
            base = os.path.join(res, name)
            att = open(base + ".attempt1.log").read() if os.path.exists(base + ".attempt1.log") else None
            return code, int(open(cnt).read()), open(base + ".log").read(), json.load(open(base + ".json")), out, att
        ie = "%Error: Internal Error: TB.sv:379:21: ../V3FuncOpt.cpp:228: Inconsistent assignment"
        fault = "%Error: Verilator internal fault, sorry. Suggest trying --debug --gdbbt"
        for what, first in (("Internal Error", ie), ("internal fault", fault), ("V3 abort", "terminate called: ../V3Ast.h:1234: abort")):
            code, n, log, rec, out, att = point("f1/N8_T2/run", [first, "ok"], [2, 0])
            assert code == 0 and n == 2 and rec["rc"] == 0 and rec["retried"] and "f1/N8_T2/run: PASS" in out, (what, code, n, rec, out)
            assert "# retry: Verilator internal error in attempt 1" in log and "%Error" not in log and log.endswith("ok\n# exit 0 after " + f"{rec['secs']} s\n"), (what, log)  # the verdict reads attempt 2
            assert att is not None and first in att and "retrying once" in out, (what, att, out)
        code, n, log, rec, out, att = point("f1/N8_T2/run", [ie], [2])  # an internal error twice: one retry only, and the point fails
        assert code == 1 and n == 2 and rec["retried"] and ie in log and "FAIL" in out, (n, log, out)
        code, n, log, rec, out, att = point("f1/N8_T2/run", ["no"], [3])  # a test failure is never retried
        assert code == 1 and n == 1 and not rec.get("retried") and att is None and "# retry" not in log and "FAIL (exit 3)" in out, (n, rec, out)
        code, n, log, rec, out, att = point("f1/N8_T2/run", ["ok\n%Error: TB.sv:12: the design's own error"], [0])  # a design %Error is no internal error
        assert n == 1 and not rec.get("retried") and code == 1, (n, rec, out)
        _fake_results(spec, os.path.join(d, "t"), ["f1/N8_T2/run"])
        rec = json.load(open(os.path.join(d, "t", "f1/N8_T2/run.json")))
        json.dump(dict(rec, retried="Internal Error: TB.sv:379:21"), open(os.path.join(d, "t", "f1/N8_T2/run.json"), "w"))
        _exit(regress.summary, FakeSpec(src, ""), _args(action="summary", results=os.path.join(d, "t"), formats="f1", small=True, run="r1"))
        row = next(x for x in open(os.path.join(d, "t", "regression.log")).read().splitlines() if x.startswith("f1/N8_T2/run"))
        assert "PASS" in row and "retried once after a Verilator internal error" in row, row  # the table says which points were retried


def _fake_results(spec, d, pts, run="r1", skip=(), stale=(), not_run=(), text=None, rc=None):
    """A result (.json and .log) for each point, as run_point writes them; a passing log unless text gives one."""
    for p in pts:
        if p in skip:
            continue
        base = os.path.join(d, p)
        os.makedirs(os.path.dirname(base), exist_ok=True)
        open(base + ".log", "w").write((text or {}).get(p, "ok\n"))
        json.dump({"name": p, "run": "old" if p in stale else run, "rc": (rc or {}).get(p, 0), "secs": 1.0,
                   "not_run": "DIR unset: make regression DIR=<d>" if p in not_run else None}, open(base + ".json", "w"))


@selftest
def test_summary():
    spec = FakeSpec(ROOT, "")
    pts = spec.points(True, ["f1", "f2"])
    gated = len(pts) - 1
    table = lambda d: open(os.path.join(d, "regression.log")).read() if os.path.exists(os.path.join(d, "regression.log")) else ""
    with tempfile.TemporaryDirectory() as d:
        _fake_results(spec, d, pts, rc={"f2/acc": 1})
        code, _ = _exit(regress.summary, spec, _args(action="summary", results=d, small=True, run="r1"))
        t = table(d)
        assert code == 0 and f"FAKE REGRESSION PASS: {gated} of {gated} gated points passed; 1 reported, not gated" in t and "FAIL (exit 1), reported, not gated" in t, t
        assert "N = 8, 16, every tile size, f1 f2; run r1" in t.splitlines()[0] and all(p in t for p in pts), t
        assert _exit(regress.summary, spec, _args(action="summary", results=d, small=True))[0] == 0  # no --run: any run's results count
        code, _ = _exit(regress.summary, spec, _args(action="summary", results=d, small=True, run="r2"))
        t = table(d)
        assert code == 1 and f"FAIL: 0 of {gated} gated points passed, {gated} NOT RUN" in t and "NOT RUN (stale: result of run r1, not r2)" in t, t
        assert _exit(regress.summary, spec, _args(action="summary", results=d, run="r1"))[0] == 1  # the full list holds N32 points no run made
    for case in ("skip", "stale", "not_run", "fail", "firing"):
        with tempfile.TemporaryDirectory() as d:
            p = "f1/N8_T2/mod"
            _fake_results(spec, d, pts, skip=[p] if case == "skip" else (), stale=[p] if case == "stale" else (), not_run=[p] if case == "not_run" else (),
                          text={p: "no\n" if case == "fail" else "ok\n%Error: z\n"} if case in ("fail", "firing") else None)
            code, _ = _exit(regress.summary, spec, _args(action="summary", results=d, small=True, run="r1"))
            t = table(d)
            want = {"skip": "NOT RUN (no result in", "stale": "NOT RUN (stale: result of run old", "not_run": "NOT RUN (DIR unset: make regression DIR=<d>)",
                    "fail": "FAIL (no 'ok')", "firing": "FAIL (log: %Error: z)"}[case]
            row = next(x for x in t.splitlines() if x.startswith(p))
            assert code == 1 and want in row and f"FAIL: {gated - 1} of {gated} gated points passed" in t, (case, t)
            assert ("1 NOT RUN" if case in ("skip", "stale", "not_run") else "1 FAIL") in t.splitlines()[-1], t
            assert (case == "not_run") == ("not run: DIR unset: make regression DIR=<d>" in t), t  # how to run it, once under the table
    with tempfile.TemporaryDirectory() as d:  # zero points: nothing selected, or nothing ran
        code, out = _exit(regress.summary, spec, _args(action="summary", results=d, formats=""))
        assert code == 1 and "FAKE REGRESSION FAIL: no points selected" in out, out
        code, _ = _exit(regress.summary, spec, _args(action="summary", results=d, small=True))
        assert code == 1 and f"FAIL: 0 of {gated} gated points passed, {gated} NOT RUN (no point ran)" in table(d), table(d)
        assert _exit(regress.summary, spec, _args(action="summary", results=d, formats="f9"))[0] != 0  # a format the repo does not have
        with contextlib.redirect_stderr(io.StringIO()):
            assert _exit(regress.main, spec, ["--action", "points", "--smal"])[0] != 0  # a mistyped option is an error, not the full sweep


@selftest
def test_copy_tree_is_a_clean_checkout():
    git = lambda cwd, *a: subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "protocol.file.allow=always", *a],
                                         cwd=cwd, capture_output=True, text=True, check=True)
    with tempfile.TemporaryDirectory() as d:  # a repo with a submodule, ignored outputs and an untracked file
        top, sub, out = (os.path.join(d, x) for x in ("top", "sub", "out"))
        for repo, files in ((sub, {"s.sv": "s", ".gitignore": "Verilator/\n"}),
                            (top, {"a.py": "a", ".gitignore": "testbenches/stimulus/\n__pycache__/\n", "testbenches/stimulus/stale.mem": "x",
                                   "testbenches/stimulus.mem": "kept", "__pycache__/a.pyc": "c"})):
            for f, text in files.items():
                os.makedirs(os.path.dirname(os.path.join(repo, f)), exist_ok=True)
                open(os.path.join(repo, f), "w").write(text)
            git(repo, "init", "-q")
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "t")
        git(top, "submodule", "add", "-q", sub, "Sub")
        git(top, "commit", "-qm", "sub")
        open(os.path.join(top, "new.txt"), "w").write("untracked")
        os.makedirs(os.path.join(top, "Sub", "Verilator"))
        open(os.path.join(top, "Sub", "Verilator", "old.o"), "w").write("o")  # ignored by the submodule's .gitignore
        regress.copy_tree(top, out)
        have = sorted(os.path.relpath(os.path.join(r, f), out) for r, _, fs in os.walk(out) for f in fs)
        assert have == [".gitignore", ".gitmodules", "Sub/.gitignore", "Sub/s.sv", "a.py", "new.txt", "testbenches/stimulus.mem"], have


@selftest
def test_regression_target():
    env = {k: v for k, v in os.environ.items() if not k.startswith("MAKE")}
    run = lambda *a: subprocess.run(["make", "-s", "-n", *a, f"PYTHON={sys.executable}"], cwd=ROOT, capture_output=True, text=True, env=env)
    r = run("regression")
    lines = r.stdout.splitlines()
    names = [x.split("--name ")[1].split()[0] for x in lines if "--action point " in x]
    assert r.returncode == 0 and names == SPEC.points(False, []), (r.stderr, names[:3])
    assert all("--run " in x and x.rstrip().endswith("--keep-going") for x in lines if "--action point " in x) and "--action summary" in lines[-1] and "--run " in lines[-1], lines[-1]
    one = run("regression/Requantizer/lint").stdout.splitlines()
    assert len(one) == 1 and "--name Requantizer/lint" in one[0] and "--keep-going" not in one[0] and "--run" not in one[0], one
    s = run("regression-summary").stdout.splitlines()
    assert len(s) == 1 and "--action summary" in s[0] and "--run" not in s[0], s


def _vcs_spec():
    spec = ArilSpec(ROOT, "")
    spec.sim = "vcs"
    return spec


@selftest
def test_vcs_points_name_vcs():
    """Under SIM=vcs every point is N/A with a reason, a simulator-free check, or a make whose make -n names vcs and never verilator."""
    spec, env = _vcs_spec(), {k: v for k, v in os.environ.items() if not k.startswith("MAKE") and k != "SIM"}
    na, runs = [], 0
    for name in spec.points(False, []):
        if spec.not_applicable(name):
            na.append(name)
            continue
        argv = spec.argv(name, None)
        if argv[0] != "make":
            continue
        assert argv[-1] == "SIM=vcs", (name, argv)
        r = subprocess.run(argv[:1] + ["-n", "-s"] + argv[1:], cwd=ROOT, capture_output=True, text=True, env=env)
        assert r.returncode == 0, (name, r.stderr[-300:])
        assert not re.search(r"(?m)^\s*verilator ", r.stdout) and "lint.sh" not in r.stdout, (name, r.stdout[-400:])
        runs += bool(re.search(r"(?m)(^|&& )vcs -full64 ", r.stdout) or "vcs_lint.py" in r.stdout)
        if "vcs -full64" in r.stdout:
            assert "-debug" not in r.stdout and "+v2k" not in r.stdout, (name, "VCS builds stay plain")
    assert set(na) == {n for n in TABLE if n.endswith("/vivado_tb")} | {k for k in VERILATOR_ONLY if "/" in k}, na
    assert runs >= 40, runs  # the simulations and VCS lints; the Python-only points (ipu, fpu, truth, truefn, ...) need no simulator
    assert spec.argv("Multipliers/Int/verilator16", None) == ["make", "-C", "Multipliers/Int", "vcs16", "SIM=vcs"]
    assert SPEC.argv("Multipliers/Int/verilator16", None) == ["make", "-C", "Multipliers/Int", "verilator16"]  # Verilator as before
    r = subprocess.run(["make", "-s", "-n", "-C", "Multipliers/BF16", "vcs", "TRACE=1"], cwd=ROOT, capture_output=True, text=True, env=env)
    assert "-debug_access+all +define+ENABLE_TRACE" in r.stdout and "+vcs+dumpvarsoff" not in r.stdout, r.stdout[-300:]  # waveforms only with TRACE=1
    r = subprocess.run(["make", "-s", "-n", "-C", "Multipliers/BF16", "vcs", "RANDINIT=1", "SEED=7", "XPROP=1"], cwd=ROOT, capture_output=True, text=True, env=env)
    assert "+vcs+initreg+random +define+NO_ZERO_INIT" in r.stdout and "./sim +vcs+initreg+7 " in r.stdout and "-xprop=tmerge" in r.stdout, r.stdout[-400:]
    r = subprocess.run(["make", "-s", "-n", "-C", "Multipliers/BF16", "vcs", "SIM=verilator"], cwd=ROOT, capture_output=True, text=True, env=env)
    assert r.returncode != 0 and "contradicts" in r.stderr, r.stderr
    r = subprocess.run(["make", "-s", "-n", "-C", "Multipliers/BF16", "verilator", "SIM=questa"], cwd=ROOT, capture_output=True, text=True, env=env)
    assert r.returncode != 0 and "SIM=questa: not one of verilator vcs" in r.stderr, r.stderr


@selftest
def test_vcs_verdicts():
    """The VCS gates: an x word fails with its line, a VCS assertion fires the scan, a VCS lint reports until its baseline is recorded."""
    spec = _vcs_spec()
    v = spec.verdict
    assert v("Adders/Int/check", "RESULT: PASSED\nFAIL: X in output word 37 of test add (add_int32.txt) ('xxxxxxxx')\nRESULT: FAILED\n", 1) \
        == "FAIL (X in output word 37 of test add (add_int32.txt) ('xxxxxxxx'))"
    assert SPEC.verdict("Adders/Int/check", "FAIL: Z in output word 2 of test t\n", 0).startswith("FAIL (Z in output word 2")  # Verilator's gate too
    assert v("Multipliers/Int8/verilator", "int8Multiplier: 65536 pairs, 0 errors\nRESULT: PASSED\n", 0) == "PASS"
    fired = 'Error: "/t/src/credit_counter.sv", 25: TB.u.a_no_underflow: at time 105 ns\n'
    assert v("Multipliers/Int8/verilator", "int8Multiplier: 65536 pairs, 0 errors\nRESULT: PASSED\n" + fired, 0).startswith("FAIL (log: Error:")
    assert v("Adders/Int/verilator", 'RESULT: PASSED\n"/t/a.sv", 9: TB.a1: started at 5ns failed at 5ns\n', 0).startswith("FAIL (log:")
    assert v("Adders/Int/verilator", "RESULT: PASSED\nError-[DPI-DIFNF] DPI function not found\n", 0).startswith("FAIL (log: Error-[")
    ok = "credit lint: not applicable to VCS (verilator --lint-only -Wall)\n" + "credit OK: m\n" * CREDIT_OK
    assert v("Common/credit", ok, 0) == "PASS" and v("Common/credit", ok.replace("credit OK: m\n", "", 1), 0).startswith("FAIL (10 of 11")
    fmt = "lint mul_fp32: not applicable to VCS (x)\nTB_fmt mul fp32: 200000 vectors, 0 word errors\nRESULT: PASSED\n"
    assert v("Fmt/mul_fp32", fmt, 0) == "PASS" and v("Fmt/mul_fp32", fmt.split("\n", 1)[1], 0).startswith("FAIL (no 'lint mul_fp32")
    lint = "vcs lint intMultiplier W=8: 3 warnings, 0 errors\nvcs lint intMultiplier W=16: 2 warnings, 0 errors\n"
    assert v("Multipliers/Int/lint", lint, 0) == "PASS" and v("Multipliers/Int/lint", lint.split("\n")[0] + "\n", 0).startswith("FAIL (1 of 2")
    assert v("Multipliers/Int/lint", lint + "vcs lint intMultiplier W=8: NEW WARNING PCWM-L in intMultiplier.sv: 2 against 1 recorded\n", 1).startswith("FAIL")
    with tempfile.TemporaryDirectory() as d:
        b = os.path.join(d, "b.txt")
        assert not vcs_lint_recorded(("intAdder",), b)
        open(b, "w").write("# header\nintAdder\t-\t-\t0\n")
        assert vcs_lint_recorded(("intAdder",), b) and not vcs_lint_recorded(("intMultiplier W=8",), b)
    assert spec.gated("Adders/Int/check") and (spec.gated("Adders/Int/lint") == vcs_lint_recorded(("intAdder",))) and SPEC.gated("Adders/Int/lint")


@selftest
def test_vcs_summary_and_skips():
    """The table under SIM=vcs: N/A rows listed and not gated, a Verilator result stale, skipped points listed and not failing."""
    class S(FakeSpec):
        def not_applicable(self, name):
            return "Verilator-only" if self.sim == "vcs" and name.endswith("/mod") else None

        def skipped(self, name, opts):
            return "no MODEL_DIR" if name == "f2/N8_T2/run" and not opts.model_dir else None
    spec = S(ROOT, "")
    pts = spec.points(True, ["f1", "f2"])
    with tempfile.TemporaryDirectory() as d:
        _fake_results(spec, d, pts)
        spec.sim = "vcs"
        code, _ = _exit(regress.summary, spec, _args(action="summary", results=d, small=True, run="r1"))
        t = open(os.path.join(d, "regression.log")).read()
        assert code == 1 and "NOT RUN (stale: a verilator result, not vcs)" in t and "N/A (Verilator-only)" in t and "simulator vcs" in t.splitlines()[0], t
        assert "; 2 not applicable to vcs" in t.splitlines()[-1], t.splitlines()[-1]
        for p in pts:
            if not p.endswith("/mod"):
                rec = json.load(open(os.path.join(d, p + ".json")))
                json.dump(dict(rec, sim="vcs"), open(os.path.join(d, p + ".json"), "w"))
        code, _ = _exit(regress.summary, spec, _args(action="summary", results=d, small=True, run="r1"))
        t = open(os.path.join(d, "regression.log")).read()
        assert code == 0 and "FAKE REGRESSION PASS: 2 of 2 gated points passed; 1 reported, not gated; 2 not applicable to vcs" in t, t
        open(os.path.join(d, "f1/N8_T2/run.log"), "a").write("  skipped: model kws: marvin.wav not in /m (copy it)\n")
        _exit(regress.summary, spec, _args(action="summary", results=d, small=True, run="r1"))
        t = open(os.path.join(d, "regression.log")).read()
        assert t.splitlines()[-2] == "skipped inside passing points: model kws: marvin.wav not in /m (copy it)", t  # what a point left out is listed
    with tempfile.TemporaryDirectory() as d:
        src = os.path.join(d, "tree")
        os.makedirs(src)
        spec = S(src, d)
        code, out = _exit(regress.run_point, spec, _args(name="f2/N8_T2/run", results=d, run="r1", probe="print('ok')"))
        rec = json.load(open(os.path.join(d, "f2/N8_T2/run.json")))
        assert code == 0 and rec["skipped"] == "no MODEL_DIR" and "SKIPPED (no MODEL_DIR)" in out, (code, rec, out)
        assert "skipped: no MODEL_DIR" in open(os.path.join(d, "f2/N8_T2/run.log")).read()
        spec.sim = "vcs"
        code, out = _exit(regress.run_point, spec, _args(name="f1/N8_T2/mod", results=d, run="r1", probe="print('ok')"))
        rec = json.load(open(os.path.join(d, "f1/N8_T2/mod.json")))
        assert code == 0 and rec["na"] == "Verilator-only" and rec["sim"] == "vcs" and "N/A (Verilator-only)" in out, (rec, out)


def selftest_main() -> None:
    """Runs every self-test: PASS or FAIL each, exit 1 if any fails."""
    bad = 0
    for t in TESTS:
        try:
            t()
            print(f"PASS {t.__name__}")
        except (Exception, SystemExit) as e:  # noqa: BLE001
            bad += 1
            print(f"FAIL {t.__name__}: {e!r}")
    print(f"ALL {len(TESTS)} PASSED" if bad == 0 else f"{bad} of {len(TESTS)} FAILED")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    if sys.argv[1:3] == ["--action", "selftest"]:
        selftest_main()
    regress.main(SPEC)
