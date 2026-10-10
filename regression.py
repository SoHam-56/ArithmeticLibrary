#!/usr/bin/env python3
"""ArithmeticLibrary's make regression: every unit bench and model check once (the benches fix their own formats), then one table."""

import contextlib
import io
import json
import os
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
    ("Common", "pkg", TB, TB_BAD, True), ("Common", "dump32", TB, TB_BAD, True), ("Common", "ipu", TB, TB_BAD, True),
    ("Common", "fpu", TB, TB_BAD, True),
    ("Common", "credit", (r"^credit lint: 0 warnings, 0 errors$",), (r"credit FAIL",), False),  # and CREDIT_OK 'credit OK' lines; the fault modes' lines quote the assertions they fire
    ("Adders/FP", "eq", TB, TB_BAD, True), ("Adders/FP", "check", TB + (r"checked against fpu\.py, 0 mismatches",), TB_BAD, True),
    ("Adders/FP", "vivado_tb", TB, TB_BAD, True), ("Adders/FP", "lint", (), LINT_BAD, True),
    ("Adders/FP32", "verilator", (r"^SUCCESS: All \d+ vectors passed",), TB_BAD, True),
    ("Adders/Int", "verilator", TB, TB_BAD, True), ("Adders/Int", "check", TB, TB_BAD, True), ("Adders/Int", "vivado_tb", TB, TB_BAD, True),
    ("Adders/Int", "lint", (), LINT_BAD, True),
    ("Multipliers/FP", "eq", TB, TB_BAD, True), ("Multipliers/FP", "check", TB + (r"checked against fpu\.py, 0 mismatches",), TB_BAD, True),
    ("Multipliers/FP", "vivado_tb", TB, TB_BAD, True), ("Multipliers/FP", "lint", (), LINT_BAD, True),
    ("Multipliers/FP32", "verilator", (r"^SUCCESS: All \d+ vectors passed",), TB_BAD, True),
    ("Multipliers/Karatsuba", "verilator", (r"^PASS: Unsigned\(\d+\) and Signed\(\d+\) vectors passed",), (r"^FAIL:",), True),
    ("Multipliers/FPWiden", "bf16", TB, TB_BAD, True), ("Multipliers/FPWiden", "fp16", TB, TB_BAD, True),
    ("Multipliers/Int", "verilator", TB, TB_BAD, True), ("Multipliers/Int", "check", TB, TB_BAD, True),
    ("Multipliers/Int", "verilator16", TB, TB_BAD, True), ("Multipliers/Int", "check16", TB, TB_BAD, True),
    ("Multipliers/Int", "vivado_tb", TB, TB_BAD, True), ("Multipliers/Int", "lint", (), LINT_BAD, True),
    ("Multipliers/Fx", "verilator", TB, TB_BAD, True), ("Multipliers/Fx", "check", TB, TB_BAD, True),  # sweep takes a slice's plusargs, not a check alone
    ("Multipliers/Fx", "vivado_tb", TB, TB_BAD, True), ("Multipliers/Fx", "lint", (), LINT_BAD, True),
    ("Requant", "both", TB, TB_BAD, True), ("Requant", "vivado_tb", TB, TB_BAD, True), ("Requant", "lint", (), LINT_BAD, True),
    ("Requant", "lint_bad", (r"^REJECTED$",), (r"^NOT-REJECTED$",), False),  # its log shows the %Error it provokes
    ("Converters/FPNarrow", "all", TB + (r"^bad_format OK:", r"^fpNarrow lint \(MAN_W 7, 23\): 0 warnings, 0 errors$"), TB_BAD, True),
]
CREDIT_OK = 11  # TB_credit_link: 8 (STAGES, MODE) runs and 3 $fatal modes, one 'credit OK' line each
TABLE = {f"{u}/{t}": (u, t, need, bad, firing) for u, t, need, bad, firing in POINTS}


class ArilSpec(regress.Spec):
    title = "ARITHMETICLIBRARY REGRESSION"
    artifacts = ()  # each bench's dumps stay in its Verilator directory

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
        if u == "Multipliers/FPWiden":
            return ["make", "-C", u, "verilator", f"FORMAT={t}"]
        return ["make", "-C", u, t]

    def verdict(self, name, text, rc):
        if name == "selftest":
            return regress.marker_verdict(text, rc, need=(r"^ALL \d+ PASSED$",))
        _, t, need, bad, firing = TABLE[name]
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
def test_pow2_tiles_and_threads():
    assert [regress.pow2_tiles(n) for n in (8, 16, 64)] == [[2, 4, 8], [2, 4, 8, 16], [2, 4, 8, 16, 32, 64]]
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
    assert SPEC.verdict("Multipliers/FP/check", "RESULT: PASSED\nmul bf16: 0 results checked\n", 0) == "FAIL (no 'checked against fpu\\.py, 0 mismatches')"
    assert SPEC.verdict("selftest", "ALL 9 PASSED\n", 0) == "PASS" and SPEC.verdict("selftest", "1 of 9 FAILED\n", 0).startswith("FAIL")


@selftest
def test_points_and_commands():
    pts = SPEC.points(False, [])
    assert pts == SPEC.points(True, []) and pts[0] == "selftest" and len(pts) == len(set(pts)) == 1 + len(POINTS), len(pts)
    for name in pts:
        u = name.rsplit("/", 1)[0]
        assert name == "selftest" or os.path.isfile(os.path.join(ROOT, u, "Makefile")), name
    assert SPEC.argv("Multipliers/FPWiden/fp16", None) == ["make", "-C", "Multipliers/FPWiden", "verilator", "FORMAT=fp16"]
    assert SPEC.argv("Requant/lint_bad", None) == ["make", "-C", "Requant", "lint_bad"]
    for name in pts[1:]:  # every target exists in its unit's Makefile
        u, t = TABLE[name][:2]
        t = "verilator" if u == "Multipliers/FPWiden" else t
        r = subprocess.run(["make", "-n", "-C", os.path.join(ROOT, u), t], capture_output=True, text=True, env={k: v for k, v in os.environ.items() if not k.startswith("MAKE")})
        assert r.returncode == 0, (name, r.stderr[-200:])
    for u in ("Adders/FP32", "Multipliers/FP32", "Multipliers/Karatsuba"):  # the threaded benches take their share under make -j
        r = subprocess.run(["make", "-n", "-C", os.path.join(ROOT, u), "verilator", "SIM_THREADS=3"], capture_output=True, text=True)
        assert "--threads 3" in r.stdout, (u, r.stdout[-300:])
    try:
        SPEC.parse("Adders/FP/nosuch")
    except ValueError:
        pass
    else:
        raise AssertionError("parse accepted Adders/FP/nosuch")


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
    one = run("regression/Requant/lint").stdout.splitlines()
    assert len(one) == 1 and "--name Requant/lint" in one[0] and "--keep-going" not in one[0] and "--run" not in one[0], one
    s = run("regression-summary").stdout.splitlines()
    assert len(s) == 1 and "--action summary" in s[0] and "--run" not in s[0], s


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
