#!/usr/bin/env python3
"""Declare-before-use check of an RTL file list with slang (pip install pyslang): every identifier declared before its first use, as
IEEE 1800 requires and as VCS (Error-[IND]) and Design Compiler (VER-954, VER-956) enforce; Verilator accepts the other order, so its
lint cannot catch it. Prints one line, 'declared-first <label>: N errors', every slang error above it, and exits 1 on any error.

  declared_first.py --label "mesh int8" --top SystolicMesh -D FMT_INT8 -D SYNTHESIS [-I dir] [-f list.f] file.sv ...

A -f list takes Verilator/VCS file-list syntax: one path per line, relative to the list's directory (or --root), +incdir+ lines, // comments.
Without pyslang the check prints 'SKIPPED' and exits 0, so a tree without it still lints; the regression points count the line.
"""
import argparse
import os
import shlex
import sys


def read_list(path, root):
    base = root or os.path.dirname(os.path.abspath(path))
    files, incs = [], []
    for line in open(path):
        line = line.split("//")[0].strip()
        if not line:
            continue
        if line.startswith("+incdir+"):
            incs.append(os.path.join(base, line[len("+incdir+"):]))
        elif line.startswith("+"):
            continue
        else:
            files.append(os.path.join(base, line))
    return files, incs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", default="")
    ap.add_argument("--top", action="append", default=[])
    ap.add_argument("-D", dest="defines", action="append", default=[])
    ap.add_argument("-I", dest="incdirs", action="append", default=[])
    ap.add_argument("-f", dest="lists", action="append", default=[])
    ap.add_argument("--root", default=None, help="the directory a -f list's paths are relative to (default: the list's own)")
    ap.add_argument("files", nargs="*")
    a = ap.parse_args()
    try:
        import pyslang as ps
        from pyslang.driver import Driver
    except ImportError:
        print(f"declared-first {a.label}: SKIPPED (pyslang not installed: pip install pyslang)")
        return 0
    files, incs = list(a.files), list(a.incdirs)
    for l in a.lists:
        f, i = read_list(l, a.root)
        files += f
        incs += i
    args = ["slang", "--allow-toplevel-iface-ports"] + [f"--top={t}" for t in a.top] + [f"-D{d}" for d in a.defines] + [f"-I{i}" for i in incs] + files
    d = Driver()
    d.addStandardArgs()
    if not d.parseCommandLine(shlex.join(args)) or not d.processOptions() or not d.parseAllSources():
        print(f"declared-first {a.label}: slang could not read the sources")
        return 1
    diags = d.createCompilation().getAllDiagnostics()
    client = ps.TextDiagnosticClient()
    engine = ps.DiagnosticEngine(d.sourceManager)
    engine.addClient(client)
    errors = 0
    for g in diags:
        if engine.getSeverity(g.code, g.location) == ps.DiagnosticSeverity.Error:
            engine.issue(g)
            errors += 1
    if errors:
        print(client.getString(), end="")
    print(f"declared-first {a.label}: {errors} errors")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
