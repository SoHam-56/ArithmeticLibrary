#!/usr/bin/env python3
"""Checks an integer-unit dump (hex operands then result per line) or a TB_fxMac sweep digest against ipu.py, bit for bit."""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ipu  # noqa: E402

UNITS = {"mul": (2, 8, 16), "mul16": (2, 16, 32), "add": (2, 32, 32), "fx": (3, 16, 16)}  # operand count, operand width, result width
BLOCK = 256  # outer values per numpy evaluation of a digest (16.7 M results)


def signed(u, w: int):
    """w-bit patterns as signed int64 values."""
    u = np.asarray(u, dtype=np.int64)
    return np.where(u >= (1 << (w - 1)), u - (1 << w), u)


def model(unit: str, ops):
    """ipu.py's result for the unit, as result-width bit patterns."""
    if unit in ("mul", "mul16"):
        r = ipu.int_mul(ops[0], ops[1], w=UNITS[unit][1])
    elif unit == "add":
        r = ipu.int_add(ops[0], ops[1], w=32)
    else:
        r = ipu.fx_mac(ops[0], ops[1], ops[2], w=16, frac=11)
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


def check_digest(path: str) -> int:
    """Per outer value, TB_fxMac writes s1 = sum of result patterns and s2 = sum of result pattern * inner pattern."""
    with open(path) as fh:
        head = fh.readline().split()
    if head[:3] != ["#", "fxMac", "digest"]:
        print(f"{path}: not a TB_fxMac digest")
        return 1
    kv = dict(t.split("=", 1) for t in head[3:])
    mode, lo, hi = kv["MODE"], int(kv["LO"]), int(kv["HI"])
    fixed = int(signed(int(kv["FIXED"], 16), 16))
    rows = np.loadtxt(path, dtype=np.int64, comments="#", ndmin=2)
    outer = rows[:, 0]
    if len(outer) != hi - lo or not np.array_equal(outer, np.arange(lo, hi)):
        print(f"fx digest MODE={mode} FIXED={fixed}: {len(outer)} outer values, expected every one of [{lo}, {hi})")
        return 1
    inner_u = np.arange(1 << 16, dtype=np.int64)
    inner = signed(inner_u, 16)
    bad = []
    for i0 in range(0, len(outer), BLOCK):
        o = signed(outer[i0:i0 + BLOCK], 16)
        n = len(o)
        big_o, big_i = np.repeat(o, 1 << 16), np.tile(inner, n)
        fix = np.full(big_o.shape, fixed, dtype=np.int64)
        args = (big_o, big_i, fix) if mode == "AX" else (fix, big_o, big_i)
        r = (np.asarray(ipu.fx_mac(*args, w=16, frac=11), dtype=np.int64) & 0xFFFF).reshape(n, 1 << 16)
        m1, m2 = r.sum(axis=1), (r * inner_u).sum(axis=1)
        for k in np.nonzero((m1 != rows[i0:i0 + n, 1]) | (m2 != rows[i0:i0 + n, 2]))[0]:
            bad.append(int(outer[i0 + k]))
    print(f"fx digest MODE={mode} FIXED={fixed}: {len(outer)} outer values x 65536 against ipu.py, "
          f"{len(bad)} mismatching outer values")
    for b in bad[:20]:
        print(f"  outer {b:04x}")
    return 1 if bad else 0


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("file")
    p.add_argument("--unit", choices=sorted(UNITS))
    p.add_argument("--digest", action="store_true", help="the file is a TB_fxMac sweep digest")
    p.add_argument("--exhaustive", action="store_true", help="also require every operand combination to appear")
    a = p.parse_args()
    if a.digest == (a.unit is not None):
        p.error("give --unit for a dump or --digest for a digest")
    rc = check_digest(a.file) if a.digest else check_dump(a.file, a.unit, a.exhaustive)
    print(f"RESULT: {'PASSED' if rc == 0 else 'FAILED'}")
    sys.exit(rc)


if __name__ == "__main__":
    main()
