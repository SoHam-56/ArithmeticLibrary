#!/usr/bin/env python3
"""One VCS lint: runs the vcs command after '--' (+lint=all) in a scratch directory, counts its Lint-/Warning- and Error- messages and prints
'vcs lint <label>: W warnings, E errors' with the gate's verdict. Fails on any error (a license failure included). Once the baseline file holds
the label, also on any (message id, file) counted more often than recorded; until then the counts are reported only. --record writes the
label's counts into the baseline instead. --selftest checks the parser and the gate on canned VCS output (no VCS needed)."""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

HEAD = re.compile(r"^(Lint|Warning|Error)-\[([A-Za-z0-9_-]+)\]")  # VCS: '<Kind>-[ID] title', its location on the next line
WHERE = re.compile(r'^\s*"?([^",]+?)"?,\s*(\d+)')


def messages(text):
    """[(kind, id, file)]: each Lint-, Warning- or Error- message and the base name of the file on the line after it ('-' when none)."""
    lines, out = text.splitlines(), []
    for i, ln in enumerate(lines):
        m = HEAD.match(ln)
        if m:
            w = WHERE.match(lines[i + 1]) if i + 1 < len(lines) else None
            out.append((m.group(1), m.group(2), os.path.basename(w.group(1)) if w else "-"))
    return out


def counts(msgs):
    """{(id, file): n} of the warnings (Lint- and Warning-)."""
    c = {}
    for kind, mid, f in msgs:
        if kind != "Error":
            c[(mid, f)] = c.get((mid, f), 0) + 1
    return c


def read_baseline(path, label):
    """{(id, file): n} recorded for label, or None when the file or the label is missing."""
    if not os.path.exists(path):
        return None
    rows = [ln.rstrip("\n").split("\t") for ln in open(path) if ln.strip() and not ln.startswith("#")]
    mine = [r for r in rows if r[0] == label]
    return None if not mine else {(r[1], r[2]): int(r[3]) for r in mine if r[1] != "-"}


def write_baseline(path, label, c):
    """Replaces label's rows (one '-' row when it has no warning, so the label counts as recorded)."""
    rows = [ln for ln in (open(path).read().splitlines() if os.path.exists(path) else []) if ln.split("\t")[0] != label]
    rows += [f"{label}\t{k[0]}\t{k[1]}\t{n}" for k, n in sorted(c.items())] or [f"{label}\t-\t-\t0"]
    with open(path, "w") as fh:
        fh.write("# vcs_lint.py baseline: label, message id, file, count (written by make ... RECORD=1 SIM=vcs on a real VCS run)\n")
        fh.write("\n".join(r for r in rows if not r.startswith("#")) + "\n")


def gate(label, text, rc, base):
    """(ok, lines): the count line and every message beyond the baseline."""
    msgs = messages(text)
    errs = [m for m in msgs if m[0] == "Error"]
    c = counts(msgs)
    w = sum(c.values())
    lines = [f"vcs lint {label}: {w} warnings, {len(errs)} errors"]
    ok = not errs and rc == 0
    if rc and not errs:
        lines.append(f"vcs lint {label}: FAIL, vcs exited {rc} with no Error- message (a license or start-up failure?)")
    for e in errs[:10]:
        lines.append(f"vcs lint {label}: ERROR {e[1]} in {e[2]}")
    if base is None:
        lines.append(f"vcs lint {label}: REPORTED ONLY, no baseline recorded yet (make ... RECORD=1 SIM=vcs records it)")
    else:
        over = [(k, n, base.get(k, 0)) for k, n in sorted(c.items()) if n > base.get(k, 0)]
        for k, n, b in over:
            lines.append(f"vcs lint {label}: NEW WARNING {k[0]} in {k[1]}: {n} against {b} recorded")
        ok &= not over
        lines.append(f"vcs lint {label}: {'PASS' if ok else 'FAIL'} against the baseline ({len(over)} beyond it)")
    return ok, lines


def run(label, top, baseline, record, cmd):
    work = tempfile.mkdtemp(prefix="vcs_lint.")
    try:
        r = subprocess.run(cmd + ["-top", top, f"-Mdir={work}/csrc", "-o", f"{work}/simv"], cwd=work, capture_output=True, text=True)
    except OSError as e:
        print(f"vcs lint {label}: 0 warnings, 1 errors\nvcs lint {label}: FAIL, {cmd[0]} did not start ({e})")
        shutil.rmtree(work, ignore_errors=True)
        return 1
    text = r.stdout + r.stderr
    shutil.rmtree(work, ignore_errors=True)
    print(text, end="" if text.endswith("\n") or not text else "\n")
    if record:
        if [m for m in messages(text) if m[0] == "Error"] or r.returncode:
            print(f"vcs lint {label}: not recorded, the run failed (exit {r.returncode})")
            return 1
        write_baseline(baseline, label, counts(messages(text)))
        print(f"vcs lint {label}: recorded in {baseline}")
        return 0
    ok, lines = gate(label, text, r.returncode, read_baseline(baseline, label))
    print("\n".join(lines))
    return 0 if ok else 1


CANNED = """Lint-[PCWM-L] Port connection width mismatch
"/t/src/unit.sv", 45
"u_a"
  The following 8-bit expression is connected to 16-bit port
Lint-[PCWM-L] Port connection width mismatch
"/t/src/unit.sv", 52
Warning-[TFIPC] Too few instance port connections
/t/src/top.sv, 12
Lint-[IWNF] Implicit wire has no fanin
"/t/src/unit.sv", 60
"""


def selftest():
    n = 0

    def check(c, what):
        nonlocal n
        n += 1
        assert c, what
    m = messages(CANNED)
    check(m == [("Lint", "PCWM-L", "unit.sv"), ("Lint", "PCWM-L", "unit.sv"), ("Warning", "TFIPC", "top.sv"), ("Lint", "IWNF", "unit.sv")], m)
    check(counts(m) == {("PCWM-L", "unit.sv"): 2, ("TFIPC", "top.sv"): 1, ("IWNF", "unit.sv"): 1}, counts(m))
    ok, lines = gate("u", CANNED, 0, None)
    check(ok and lines[0] == "vcs lint u: 4 warnings, 0 errors" and "REPORTED ONLY" in lines[-1], lines)
    ok, lines = gate("u", CANNED + 'Error-[SE] Syntax error\n"/t/src/unit.sv", 3\n', 1, None)
    check(not ok and lines[0] == "vcs lint u: 4 warnings, 1 errors", lines)  # an error fails before any baseline exists
    check(not gate("u", "", 1, None)[0], "a failing vcs with no message must fail")  # e.g. no license
    base = counts(m)
    check(gate("u", CANNED, 0, base)[0], "the recorded warnings pass")
    ok, lines = gate("u", CANNED + 'Lint-[IWNF] x\n"/t/src/unit.sv", 70\n', 0, base)
    check(not ok and any("NEW WARNING IWNF in unit.sv: 2 against 1" in x for x in lines), lines)
    check(gate("u", CANNED.split("Lint-[IWNF]")[0], 0, base)[0], "fewer warnings than recorded pass")
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "b.txt")
        check(read_baseline(p, "u") is None, "no file: not recorded")
        write_baseline(p, "u", base)
        write_baseline(p, "v", {})
        check(read_baseline(p, "u") == base and read_baseline(p, "v") == {} and read_baseline(p, "w") is None, open(p).read())
        write_baseline(p, "u", {("X", "y.sv"): 3})
        check(read_baseline(p, "u") == {("X", "y.sv"): 3} and read_baseline(p, "v") == {}, open(p).read())
    print(f"vcs_lint selftest: {n} checks, 0 failures")


def main():
    if sys.argv[1:] == ["--selftest"]:
        try:
            selftest()
        except AssertionError as e:
            print(f"vcs_lint selftest: FAIL {e}")
            sys.exit(1)
        print("RESULT: PASSED")
        return
    if "--" not in sys.argv:
        sys.exit("usage: vcs_lint.py LABEL --top TOP --baseline FILE [--record] -- vcs ...")
    k = sys.argv.index("--")
    ap = argparse.ArgumentParser(allow_abbrev=False)
    ap.add_argument("label")
    ap.add_argument("--top", required=True)
    ap.add_argument("--baseline", required=True)
    ap.add_argument("--record", action="store_true")
    a = ap.parse_args(sys.argv[1:k])
    sys.exit(run(a.label, a.top, a.baseline, a.record, sys.argv[k + 1:]))


if __name__ == "__main__":
    main()
