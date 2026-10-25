#!/usr/bin/env python3
"""Writes int8QuantizedAdder stimulus: a consts file (z1 z2 m1 m2 shift zo lo hi per set; the bench runs every (q1, q2) under each) and a
row file (q1 q2 z1 z2 m1 m2 shift zo lo hi [expected]), with each set's and row's real ratios s1 / s_out and s2 / s_out in OUT.npz.

Sets: the corner ratio pairs of int8_vectors under its four zero-point sets, encoded by ipu.encode_add. Rows: real ratio pairs
log-uniform over 2^-14 .. 2^22.9 (a third near cancellation, r2 = r1 (1 + delta)) through encode_add, and raw random (m1, m2, shift)
words whose ratios are exactly m 2^-shift; every set and row is gated on the true function.
"""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Common", "models"))
import int8_vectors  # noqa: E402
import ipu  # noqa: E402

FIELDS = ("z1", "z2", "m1", "m2", "shift", "zo", "lo", "hi")
WIDTHS = (8, 8, 32, 32, 6, 8, 8, 8)
FMT = ("%02x", "%02x", "%08x", "%08x", "%02x", "%02x", "%02x", "%02x")


def corner_sets():
    rows = []
    for r1, r2, z1, z2, zo, lo, hi in int8_vectors.add_corner_sets():
        m1, m2, e = ipu.encode_add(r1, r2)
        rows.append((z1, z2, m1, m2, e, zo, lo, hi, r1, r2))
    return rows


def random_rows(rng, n):
    """Half real ratio pairs through encode_add, half raw words; random codes, zero points and in-contract clamps."""
    h = n // 2
    r1 = 2.0 ** rng.uniform(-14, 22.9, h)
    r2 = 2.0 ** rng.uniform(-14, 22.9, h)
    near = rng.integers(0, 3, h) == 0
    r2 = np.where(near, r1 * (1 + rng.choice([0.0, 2.0 ** -30, -2.0 ** -24, 2.0 ** -20, -2.0 ** -12, 2.0 ** -8], h)), r2)
    keep = np.maximum(r1, r2) < 2.0 ** 23 * (1 - 2.0 ** -20)
    r1, r2 = r1[keep], r2[keep]
    codes = np.array([ipu.encode_add(float(a), float(b)) for a, b in zip(r1, r2)], dtype=np.int64).reshape(-1, 3)
    m1 = np.concatenate([codes[:, 0], rng.integers(0, 1 << 32, n - h)])
    m2 = np.concatenate([codes[:, 1], rng.integers(0, 1 << 32, n - h)])
    e = np.concatenate([codes[:, 2], rng.integers(0, 42, n - h)])
    raw = np.arange(m1.size) >= r1.size
    k = m1.size
    q1, q2 = rng.integers(-128, 128, k), rng.integers(-128, 128, k)
    near_cancel = rng.integers(0, 4, k) == 0  # q2 - z2 = -(q1 - z1): the outputs that do not saturate at large ratios
    z1, z2, zo = rng.integers(-128, 128, k), rng.integers(-128, 128, k), rng.integers(-128, 128, k)
    q2 = np.where(near_cancel, np.clip(z2 - (q1 - z1) + rng.integers(-1, 2, k), -128, 127), q2)
    a, b = rng.integers(-128, 128, k), rng.integers(-128, 128, k)
    lo, hi = np.minimum(a, b), np.maximum(a, b)
    rr1 = np.where(raw, np.ldexp(m1.astype(np.float64), -e), np.concatenate([r1, np.zeros(n - h)]))
    rr2 = np.where(raw, np.ldexp(m2.astype(np.float64), -e), np.concatenate([r2, np.zeros(n - h)]))
    return [q1, q2, z1, z2, m1, m2, e, zo, lo, hi], rr1, rr2, raw


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("out", help="the row file; OUT.consts for the sets and OUT.npz for the real ratios")
    p.add_argument("--random", type=int, default=1000000)
    p.add_argument("--seed", type=int, default=1)
    a = p.parse_args()
    rng = np.random.default_rng(a.seed)
    sets = corner_sets()
    cols, r1, r2, raw = random_rows(rng, a.random)
    widths = [8, 8] + list(WIDTHS)
    table = np.stack([ipu.bits(v, w) for v, w in zip(cols, widths)], axis=1)
    np.savetxt(a.out, table, fmt=" ".join(["%02x", "%02x"] + list(FMT)))
    st = np.array([s[:8] for s in sets], dtype=np.int64)
    np.savetxt(a.out + ".consts", np.stack([ipu.bits(st[:, i], w) for i, w in enumerate(WIDTHS)], axis=1), fmt=" ".join(FMT))
    np.savez(a.out + ".npz", sets=st, set_r1=np.array([s[8] for s in sets]), set_r2=np.array([s[9] for s in sets]),
             rows=np.stack(cols, axis=1), r1=r1, r2=r2, raw=raw)
    print(f"{a.out}: {len(sets)} exhaustive sets, {len(table)} rows ({int(raw.sum())} raw words)")


if __name__ == "__main__":
    main()
