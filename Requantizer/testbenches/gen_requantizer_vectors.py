#!/usr/bin/env python3
"""Writes int8Requantizer vectors: hex rows (acc mult shift zp act_min act_max [expected]) and an .npz with each row's real scale S.

Rows: word corners, requant_sat's saturation corners, dense real scales 1e-12..2^31 with accumulators aimed at |acc S| <= 400 and at
output ties, and random raw (mult, shift) words; every row's scale is real, so every row is gated on the true function.
"""
import argparse
import itertools
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Common", "models"))
import int8_vectors  # noqa: E402
import ipu  # noqa: E402

MIN, MAX = ipu.INT32_MIN, ipu.INT32_MAX
ACC = [MIN, MIN + 1, -(1 << 30), -(1 << 24), -65536, -257, -256, -129, -128, -3, -2, -1, 0, 1, 2, 3, 127, 128, 255, 256, 65536,
       1 << 24, 1 << 30, MAX - 1, MAX]
MULT = [0, 1, 1 << 23, (1 << 23) + 1, 0xAAAAAA, 0x555555, (1 << 24) - 2, (1 << 24) - 1]
SHIFTS = [0, 1, 2, 15, 16, 17, 23, 24, 31, 32, 40, 47, 54, 55]
ZP_SETS = [(0, -128, 127), (-128, -128, 127), (127, -128, 127), (-5, -5, 127), (10, 10, 60), (-1, 3, 3)]  # the study's six


def raw_rows(m, e, acc, zp, lo, hi):
    """Rows of words whose real scale is exactly m 2^-e."""
    return [np.asarray(v, dtype=np.int64) for v in (acc, m, e, zp, lo, hi)], np.ldexp(np.asarray(m, dtype=np.float64), -np.asarray(e))


def corners():
    rows = [(a, m, e) + z for a, m, e, z in itertools.product(ACC, MULT, SHIFTS, ZP_SETS[:1])]
    rows += [(a, m, e) + z for a, m, e, z in itertools.product(ACC, [1 << 23, (1 << 24) - 1], [16, 23, 55], ZP_SETS[1:])]
    a, m, e, zp, lo, hi = zip(*rows)
    return raw_rows(m, e, a, zp, lo, hi)


def from_scales(acc, s, zp, lo, hi):
    """Rows for real scales s, encoded by ipu.encode_scale."""
    codes = [ipu.encode_scale(float(x)) for x in s]
    cols = [np.asarray(v, dtype=np.int64) for v in (acc, [c[0] for c in codes], [c[1] for c in codes], zp, lo, hi)]
    return cols, np.asarray(s, dtype=np.float64)


def saturation():
    rows = int8_vectors.saturation_corners()
    return from_scales(*zip(*[(a, s, z, lo, hi) for a, s, z, lo, hi in rows]))


def dense(rng, n_scales, per):
    """Real scales log-uniform over [1e-12, 2^31] plus every power of two 2^-45..2^31 and its neighbours; per scale, accumulators aimed
    at |acc S| <= 400 and at output ties k + 1/2, under the six zero-point sets."""
    s = np.concatenate([int8_vectors.log_uniform(rng, 1e-12, 2.0 ** 31, n_scales),
                        [2.0 ** k * f for k in range(-45, 32) for f in (1.0, 1 - 2.0 ** -25, 1 + 2.0 ** -24)]])
    acc, ss, zp, lo, hi = [], [], [], [], []
    for x in s:
        lim = int(min(MAX, max(1, 400.0 / x)))
        a = rng.integers(-lim, lim + 1, per)
        k = rng.integers(-400, 400, per // 4)
        tie = np.round((k + 0.5) / x)
        a = np.clip(np.concatenate([a, tie, tie - 1, tie + 1]).astype(np.float64), MIN, MAX).astype(np.int64)
        z = ZP_SETS[rng.integers(0, len(ZP_SETS))]
        acc += a.tolist()
        ss += [x] * a.size
        zp += [z[0]] * a.size
        lo += [z[1]] * a.size
        hi += [z[2]] * a.size
    return from_scales(acc, ss, zp, lo, hi)


def random_words(rng, n):
    """Raw mult in [0, 2^24) and shift in [0, 55], accumulators uniform or aimed so the result lies within +-600, any in-contract clamp."""
    m = rng.integers(0, 1 << 24, n)
    e = rng.integers(0, 56, n)
    s = np.ldexp(np.maximum(m, 1).astype(np.float64), -e)
    acc = rng.integers(MIN, MAX + 1, n)
    aim = rng.integers(0, 4, n) > 0
    acc = np.where(aim, np.clip(np.round(rng.uniform(-600, 600, n) / s), MIN, MAX), acc).astype(np.int64)
    zp = rng.integers(-128, 128, n)
    a, b = rng.integers(-128, 128, n), rng.integers(-128, 128, n)
    return raw_rows(m, e, acc, zp, np.minimum(a, b), np.maximum(a, b))


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("out", help="the hex row file; OUT with .npz for the scales")
    p.add_argument("--random", type=int, default=1000000, help="random raw-word rows")
    p.add_argument("--scales", type=int, default=2000, help="dense real scales")
    p.add_argument("--per", type=int, default=64, help="aimed accumulators per dense scale")
    p.add_argument("--expected", action="store_true", help="append ipu.requantize's word to each row (the committed, DPI-free vectors)")
    p.add_argument("--seed", type=int, default=1)
    a = p.parse_args()
    rng = np.random.default_rng(a.seed)
    parts = {"corners": corners(), "saturation": saturation(), "dense": dense(rng, a.scales, a.per), "random": random_words(rng, a.random)}
    cols = [np.concatenate([v[0][i] for v in parts.values()]) for i in range(6)]
    s = np.concatenate([v[1] for v in parts.values()])
    kind = np.concatenate([np.full(v[1].size, i, dtype=np.int8) for i, v in enumerate(parts.values())])
    want = ipu.requantize(*cols)
    widths = [32, 24, 6, 8, 8, 8] + ([8] if a.expected else [])
    table = np.stack([ipu.bits(v, w) for v, w in zip(cols + ([want] if a.expected else []), widths)], axis=1)
    np.savetxt(a.out, table, fmt=" ".join(["%08x", "%06x", "%02x", "%02x", "%02x", "%02x"] + (["%02x"] if a.expected else [])))
    np.savez(a.out + ".npz", acc=cols[0], mult=cols[1], shift=cols[2], zp=cols[3], lo=cols[4], hi=cols[5], scale=s, kind=kind,
             kinds=np.array(list(parts)))
    print(f"{a.out}: {len(table)} rows ({', '.join(f'{len(v[1])} {k}' for k, v in parts.items())}), "
          f"{int(np.sum((want == cols[4]) | (want == cols[5])))} at a clamp bound")


if __name__ == "__main__":
    main()
