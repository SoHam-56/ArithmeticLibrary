#!/usr/bin/env python3
"""Checks an integer-unit dump (hex operands then result per line) against ipu.py, bit for bit."""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ipu  # noqa: E402

UNITS = {"mul": (2, 8, 16), "mul16": (2, 16, 32), "add": (2, 32, 32)}  # operand count, operand width, result width


def signed(u, w: int):
    """w-bit patterns as signed int64 values."""
    u = np.asarray(u, dtype=np.int64)
    return np.where(u >= (1 << (w - 1)), u - (1 << w), u)


def model(unit: str, ops):
    """ipu.py's result for the unit, as result-width bit patterns."""
    if unit in ("mul", "mul16"):
        r = ipu.int_mul(ops[0], ops[1], w=UNITS[unit][1])
    else:
        r = ipu.int_add(ops[0], ops[1], w=32)
    return np.asarray(r, dtype=np.int64) & ((1 << UNITS[unit][2]) - 1)


def check_dump(path: str, unit: str, exhaustive: bool) -> int:
    n_ops, w, rw = UNITS[unit]
    rows = [ln.split() for ln in open(path) if ln.strip()]
    ops = [signed([int(r[i], 16) for r in rows], w) for i in range(n_ops)]
    got = np.array([int(r[n_ops], 16) for r in rows], dtype=np.int64)
    want = model(unit, ops)
    bad = np.nonzero(got != want)[0]
    ok = len(rows) > 0 and len(bad) == 0
    msg = f"check_ipu {unit}: {len(rows)} results against ipu.py, {len(bad)} mismatches"
    if exhaustive:
        seen = len(set(zip(*(o.tolist() for o in ops))))
        msg += f", {seen} distinct operand combinations of {1 << (n_ops * w)}"
        ok = ok and seen == 1 << (n_ops * w)
    print(msg)
    d, rd = (w + 3) // 4, (rw + 3) // 4
    for i in bad[:20]:
        opnd = " ".join(f"{int(o[i]) & ((1 << w) - 1):0{d}x}" for o in ops)
        print(f"  {opnd}: rtl {got[i]:0{rd}x}, model {want[i]:0{rd}x}")
    return 0 if ok else 1


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("file")
    p.add_argument("--unit", choices=sorted(UNITS), required=True)
    p.add_argument("--exhaustive", action="store_true", help="also require every operand combination to appear")
    a = p.parse_args()
    rc = check_dump(a.file, a.unit, a.exhaustive)
    print(f"RESULT: {'PASSED' if rc == 0 else 'FAILED'}")
    sys.exit(rc)


if __name__ == "__main__":
    main()
