#!/usr/bin/env python3
"""Fmt's lint gate: new code (the wrappers, the package's define map, the per-format units, Fmt's test tops) has no warning; the existing units
and the old package functions may keep only the warnings recorded in testbenches/top/lint_baseline.txt for that point (no new warning).
Every %Warning line counts: one without a file:line:col location fails. Args: LOG POINT TOP; --record writes the point's existing-file
warnings to the baseline instead of checking them (refused when an existing file changed since the last record, unless --force); --as DIR
reads paths under DIR as if DIR were the ArithmeticLibrary root (a control's copied tree)."""
import argparse
import hashlib
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
BASELINE = os.path.join(ROOT, "testbenches", "top", "lint_baseline.txt")  # --baseline and --root override these (the controls' copies)
NEW = ("src/fmt/fmt_", "src/multipliers/bf16Multiplier.sv", "src/adders/bf16Adder.sv", "src/multipliers/bf16WideMultiplier.sv", "src/converters/",
       "src/multipliers/int8Multiplier.sv", "src/multipliers/int16Multiplier.sv", "src/multipliers/int24Multiplier.sv", "src/adders/int32Adder.sv")  # the restructure's new files: no warning at all
PKG = "src/fmt/sienna_fmt_pkg.sv"
MAP_MARK = "// ── define map"  # the package's lines from this comment on are new code; the old functions above it are existing code


def map_line(root=None):
    """The package's first define-map line (1-based) in the tree at root; past the end when there is no map."""
    own = os.path.normpath(os.path.join(HERE, "..", PKG))  # a control's copied tree may hold no package: this tree's then
    path = next((p for p in (os.path.join(root or ROOT, PKG), os.path.join(ROOT, PKG), own) if os.path.exists(p)))
    lines = open(path, errors="replace").read().splitlines()
    return next((i + 1 for i, ln in enumerate(lines) if MAP_MARK in ln), len(lines) + 1)


def is_new(w, first_map_line):
    """A warning in new code: a new file, or the package's define map."""
    return w[1].startswith(NEW) or (w[1] == PKG and w[2] >= first_map_line)


WARN = re.compile(r"^%Warning-([A-Z0-9_]+): ([^:\s]+):(\d+):\d+: (.*)$")


def rel(path, alias=None):
    """A warning's file relative to the ArithmeticLibrary root (or to alias, a copied tree)."""
    p = os.path.normpath(path)
    if alias and os.path.isabs(p) and p.startswith(os.path.normpath(alias) + os.sep):
        p = os.path.relpath(p, alias)
    elif os.path.isabs(p):
        p = os.path.relpath(p, ROOT)
    return p


def warnings(log, alias=None):
    """(located warnings, unlocated %Warning lines): every %Warning line is one or the other."""
    out, unplaced = [], []
    for ln in open(log, errors="replace"):
        ln = ln.rstrip("\n")
        if not ln.startswith("%Warning"):
            continue
        m = WARN.match(ln)
        if m:
            kind, path, line, msg = m.groups()
            out.append((kind, rel(path, alias), int(line), msg))
        else:
            unplaced.append(ln)
    return out, unplaced


def digest(path):
    """sha256 of an existing file; of the package, only its old functions (the lines above the define map)."""
    data = open(os.path.join(ROOT, path), "rb").read()
    if path == PKG:
        data = b"\n".join(data.split(b"\n")[:map_line() - 1])
    return hashlib.sha256(data).hexdigest()[:16]


def load():
    base, hashes = {}, {}
    if os.path.exists(BASELINE):
        for ln in open(BASELINE):
            if ln.startswith("#sha256|"):
                _, path, h = ln.rstrip("\n").split("|")
                hashes[path] = h
            elif ln.strip() and not ln.startswith("#"):
                point, kind, path, line, msg = ln.rstrip("\n").split("|", 4)
                base.setdefault(point, set()).add((kind, path, int(line), msg))
    return base, hashes


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("log")
    ap.add_argument("point")
    ap.add_argument("top")
    ap.add_argument("--record", action="store_true")
    ap.add_argument("--force", action="store_true", help="re-record although an existing file changed")
    ap.add_argument("--as", dest="alias", help="read paths under this directory as if it were the root")
    ap.add_argument("--baseline", help="the baseline file (default testbenches/top/lint_baseline.txt)")
    ap.add_argument("--root", help="the tree whose existing files the recorded sha256 values are checked against")
    a = ap.parse_args()
    global BASELINE, ROOT
    BASELINE = a.baseline or BASELINE
    ROOT = os.path.normpath(a.root) if a.root else ROOT
    text = open(a.log, errors="replace").read()
    errors = len(re.findall(r"(?m)^%Error", text))
    ws, unplaced = warnings(a.log, a.alias)
    first_map = map_line(a.alias)
    new = [w for w in ws if is_new(w, first_map)]
    old = sorted({w for w in ws if not is_new(w, first_map)})
    if a.record:
        base, hashes = load()
        changed = [p for p, h in hashes.items() if os.path.exists(os.path.join(ROOT, p)) and digest(p) != h]
        if changed and not a.force:
            print(f"lint {a.top} {a.point}: refusing to re-record: existing files changed since the baseline: {', '.join(changed)}")
            return 1
        base[a.point] = set(old)
        for w in old:
            hashes[w[1]] = digest(w[1])
        with open(BASELINE, "w") as f:
            f.write("# point|warning|file|line|message: the existing files' -Wall warnings each Fmt point's lint may keep (recorded on unchanged files)\n")
            for path in sorted(hashes):
                f.write(f"#sha256|{path}|{hashes[path]}\n")
            for point in sorted(base):
                for kind, path, line, msg in sorted(base[point]):
                    f.write(f"{point}|{kind}|{path}|{line}|{msg}\n")
        print(f"lint {a.top} {a.point}: recorded {len(old)} existing-file warnings")
        return 0
    allowed = load()[0].get(a.point, set())
    fresh = [w for w in old if w not in allowed]
    for w in new + fresh:
        print(f"NEW WARNING {a.point}: %Warning-{w[0]}: {w[1]}:{w[2]}: {w[3]}")
    for ln in unplaced:
        print(f"UNPLACED WARNING {a.point}: {ln[:160]}")
    print(f"lint {a.top} {a.point}: {len(new)} library warnings, {len(fresh)} new unit warnings ({len(old) - len(fresh)} in the recorded baseline), "
          f"{len(unplaced)} unplaced warnings, {errors} errors")
    return 0 if not new and not fresh and not unplaced and errors == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
