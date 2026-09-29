#!/usr/bin/env python3
"""Writes tfliteRequant vectors from ipu.requant in hex (acc mult shift zp act_min act_max expected): corners, discriminators, random."""
import argparse
import itertools
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Common", "models"))
import ipu  # noqa: E402

MIN, MAX = ipu.INT32_MIN, ipu.INT32_MAX
ACC = [MIN, MIN + 1, -(1 << 30) - 1, -(1 << 30), -(1 << 24), -65536, -32769, -257, -256, -255, -129, -128, -127, -3, -2,
       -1, 0, 1, 2, 3, 127, 128, 255, 256, 32768, 65536, 1 << 24, 1 << 30, (1 << 30) + 1, MAX - 1, MAX]
MULT = [0, 1, (1 << 30) - 1, 1 << 30, (1 << 30) + 1, 3 << 29, MAX - 1, MAX, MIN, MIN + 1, -1, -(1 << 30)]
SHIFTS = list(range(-31, 31))
ZPS = [-128, -1, 1, 127]


def clamps(zp):
    """Full range, ReLU at the zero point, pinned low, pinned high, a ReLU6-like window, and act_min > act_max."""
    return [(-128, 127), (zp, 127), (-128, -128), (127, 127), (0, 6), (5, -5)]


def corners():
    rows = [(a, m, s, 0, -128, 127) for a, m, s in itertools.product(ACC, MULT, SHIFTS)]
    for a, m, s, z in itertools.product(ACC, [1 << 30, MAX], [-31, -8, -1, 0, 1, 8, 30], ZPS):
        rows += [(a, m, s, z, lo, hi) for lo, hi in clamps(z)]
    for s in range(-31, 1):  # exact halves at the output: +-k << -s times 0.5 * 2^s is +-k/2
        for k in (1, 3, 5, 7):
            if k << (-s) <= MAX:
                rows += [(sg * (k << (-s)), 1 << 30, s, 0, -128, 127) for sg in (1, -1)]
    return [np.array(c, dtype=np.int64) for c in zip(*rows)]


def random_rows(n, rng):
    """Uniform int32 accumulators and shifts, three quarters replaced by ones aimed at |y| <= 160; an eighth with any int32 multiplier."""
    acc = rng.integers(MIN, MAX + 1, n, dtype=np.int64)
    mult = rng.integers(1 << 30, MAX + 1, n, dtype=np.int64)
    shift = rng.integers(-31, 31, n, dtype=np.int64)
    kind = rng.integers(0, 8, n)
    aim = kind < 6
    s_aim = rng.integers(-24, 9, n, dtype=np.int64)
    a_aim = np.clip(np.round(rng.uniform(-160, 160, n) * 2.0 ** 31 / mult * 2.0 ** (-s_aim)), MIN, MAX).astype(np.int64)
    acc, shift = np.where(aim, a_aim, acc), np.where(aim, s_aim, shift)
    mult = np.where(kind == 7, rng.integers(MIN, MAX + 1, n, dtype=np.int64), mult)
    zp = rng.integers(-128, 128, n, dtype=np.int64)
    c = rng.integers(0, 8, n)
    r1, r2 = rng.integers(-128, 128, n, dtype=np.int64), rng.integers(-128, 128, n, dtype=np.int64)
    lo = np.select([c < 5, c == 5], [-128, zp], default=np.minimum(r1, r2))
    hi = np.select([c < 5, c == 5], [127, 127], default=np.maximum(r1, r2))
    return [acc, mult, shift, zp, lo.astype(np.int64), hi.astype(np.int64)]


def discriminators(rng, want=2000):
    """Vectors where DOUBLE and SINGLE disagree, so both RTL variants see their difference."""
    rows = random_rows(200000, rng)
    d = ipu.requant(*rows, "DOUBLE") != ipu.requant(*rows, "SINGLE")
    return [r[d][:want] for r in rows]


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("out")
    p.add_argument("--rounding", choices=ipu.ROUNDINGS, required=True)
    p.add_argument("--random", type=int, default=1000000)
    p.add_argument("--seed", type=int, default=1)
    a = p.parse_args()
    rng = np.random.default_rng(a.seed)
    c, d, r = corners(), discriminators(rng), random_rows(a.random, rng)
    cols = [np.concatenate([c[i], d[i], r[i]]) for i in range(6)]
    want = ipu.requant(*cols, a.rounding)
    other = ipu.requant(*cols, "SINGLE" if a.rounding == "DOUBLE" else "DOUBLE")
    table = np.stack([ipu.bits(v, w) for v, w in zip(cols + [want], [32, 32, 8, 8, 8, 8, 8])], axis=1)
    np.savetxt(a.out, table, fmt="%08x %08x %02x %02x %02x %02x %02x")
    at_bound = float(np.mean((want == cols[4]) | (want == cols[5])))
    print(f"{a.out}: {len(table)} vectors ({len(c[0])} corners, {len(d[0])} rounding discriminators, {a.random} random), "
          f"rounding {a.rounding}, {int(np.sum(want != other))} differ from the other rounding, "
          f"{100 * at_bound:.1f}% at a clamp bound")


if __name__ == "__main__":
    main()
