#!/usr/bin/env python3
"""Checks a float-unit dump (a b result flags per line; flags are ov un inv as binary digits) against fpu.py, bit for bit."""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fpu  # noqa: E402


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("dump")
    p.add_argument("--unit", choices=["mul", "add"], required=True)
    p.add_argument("--format", choices=sorted(fpu.FORMATS), required=True)
    p.add_argument("--fp32-unit", action="store_true", help="the dump came from fp32Adder (its overflow flag, D-1)")
    a = p.parse_args()
    f = fpu.FORMATS[a.format]
    rows = [ln.split() for ln in open(a.dump) if ln.strip()]
    A = np.array([int(r[0], 16) for r in rows], dtype=np.int64)
    B = np.array([int(r[1], 16) for r in rows], dtype=np.int64)
    R = np.array([int(r[2], 16) for r in rows], dtype=np.int64)
    FL = np.array([int(r[3], 2) for r in rows], dtype=np.int64)
    if a.unit == "mul":
        res, ov, un, inv = fpu.mul(f, A, B)
    else:
        res, ov, un, inv = fpu.add(f, A, B, fp32_overflow_quirk=a.fp32_unit)
    flags = (ov.astype(np.int64) << 2) | (un.astype(np.int64) << 1) | inv.astype(np.int64)
    bad = np.nonzero((res != R) | (flags != FL))[0]
    d = (f.w + 3) // 4
    print(f"{a.unit} {a.format}: {len(rows)} results checked against fpu.py, {len(bad)} mismatches")
    for i in bad[:20]:
        print(f"  {A[i]:0{d}x} {B[i]:0{d}x}: rtl {R[i]:0{d}x} {FL[i]:03b}, model {res[i]:0{d}x} {flags[i]:03b}")
    sys.exit(1 if len(bad) or not rows else 0)


if __name__ == "__main__":
    main()
