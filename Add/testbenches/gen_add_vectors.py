#!/usr/bin/env python3
"""tfliteAdd's vectors and constant sets from ipu.tflite_add (and G0b's models): the one (q1, q2) order, corners, output- and input-stage rounding discriminators, random."""
import argparse
import hashlib
import itertools
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Common", "models"))
import ipu  # noqa: E402

PAIRS = 1 << 16
Q1 = (np.arange(PAIRS, dtype=np.int64) >> 8) - 128  # q1 outer
Q2 = (np.arange(PAIRS, dtype=np.int64) & 255) - 128  # q2 inner: the oracle's, the TB's exhaustive mode's and the checker's order
FIELDS = ("zp1", "zp2", "m1", "s1", "m2", "s2", "mo", "so", "zpo", "amin", "amax")  # a constant set, in the consts file's column order
LOG2_LO, LOG2_HI, LOG2_SPAN = -10.0, 2.0, 10.0  # scales 2^-10 to 2^2, ratios up to 2^10 (the spec's G0b ranges)
MIN, MAX = ipu.INT32_MIN, ipu.INT32_MAX


def act_range(act: str, scale, zp: int):
    """TFLite CalculateActivationRangeQuantized, int8: zp + round(f / scale), f / scale in float32."""
    q = lambda f: int(zp) + ipu.round_half_away(float(np.float32(f) / np.float32(scale)))
    return {"none": (-128, 127), "relu": (max(-128, q(0.0)), 127), "relu6": (max(-128, q(0.0)), min(127, q(6.0)))}[act]


def draw_scales(rng):
    """s1, s2, s_out log-uniform in [2^-10, 2^2] with max / min <= 2^10, as float32 values."""
    while True:
        e = rng.uniform(LOG2_LO, LOG2_HI, 3)
        if e.max() - e.min() <= LOG2_SPAN:
            return [float(np.float32(2.0 ** v)) for v in e]


def oracle_manifest(d: str) -> dict:
    return json.load(open(os.path.join(d, "manifest.json")))


def oracle_consts(d: str) -> list:
    """Every G0b model's ADD words, in manifest order: add_params of its scales, its zero points and its clamp."""
    return [m["add"] for m in oracle_manifest(d)["models"]]


def oracle_outputs(d: str, n=None) -> np.ndarray:
    """Every G0b model's interpreter outputs (BUILTIN_REF), one row of PAIRS per model, in manifest order; each file's sha256 and the model count verified."""
    models = oracle_manifest(d)["models"]
    on_disk = sorted(f for f in os.listdir(d) if f.startswith("g0b_") and f.endswith(".npz"))
    if on_disk != sorted(m["file"] for m in models) or (n is not None and len(models) != n):
        raise ValueError(f"{d}: the manifest lists {len(models)} models, the directory holds {len(on_disk)} model files"
                         + (f", expected {n}" if n is not None else ""))
    ys = []
    for m in models:
        y = np.load(os.path.join(d, m["file"]))["y"]
        if y.dtype != np.int8 or y.shape != (PAIRS,) or hashlib.sha256(y.tobytes()).hexdigest() != m["sha256"]:
            raise ValueError(f"{d}/{m['file']}: its outputs ({y.dtype}, {y.shape}) do not match the manifest's sha256")
        ys.append(y.astype(np.int64))
    return np.stack(ys)


COLS = ("q1", "q2") + FIELDS  # a vector file's columns, before the expected result
WIDE = ("m1", "m2", "mo")  # the 32-bit words; every other column is 8 bits
BASE = dict(zp1=0, zp2=0, m1=1 << 30, s1=0, m2=1 << 30, s2=0, mo=1 << 30, so=-20, zpo=0, amin=-128, amax=127)  # y = (d1 + d2) / 4


def write_consts(path: str, rows) -> None:
    with open(path, "w") as f:
        f.write("".join(" ".join(f"{int(r[k]) & 0xFFFFFFFF:08x}" if k in WIDE else f"{int(r[k]) & 0xFF:02x}" for k in FIELDS) + "\n"
                        for r in rows))


def read_consts(path: str) -> list:
    rows = [[int(x, 16) for x in ln.split()] for ln in open(path) if ln.strip()]
    return [{k: int(ipu.sx(v, 32 if k in WIDE else 8)) for k, v in zip(FIELDS, r)} for r in rows]


def corner_consts() -> list:
    """The exhaustive sweep's 154 distinct sets: every shift of each input and the output, the extreme multipliers, the zero-point corners, tight and inverted clamps, flushed multipliers, 32 from add_params."""
    rows = [dict(BASE, **{k: s}) for k in ("s1", "s2", "so") for s in range(-31, 1) if k == "s1" or s != BASE[k]]  # BASE once
    rows += [dict(BASE, m1=a, m2=b, mo=c) for a, b, c in itertools.product((1 << 30, MAX), repeat=3) if (a, b, c) != (1 << 30,) * 3]
    rows.append(dict(BASE, m1=MAX, s1=-31, m2=MAX, s2=-31, mo=MAX, so=-31))  # the largest multiplier at the deepest shift in every stage
    rows += [dict(BASE, zp1=z, zp2=z, zpo=z, amin=lo, amax=hi) for z, lo, hi in ((127, 100, 120), (-128, -120, -100))]  # extreme zero points, a tight clamp met on both sides
    rows += [dict(BASE, zp1=a, zp2=b, zpo=c) for a, b, c in itertools.product((-128, 127), repeat=3)]
    rows += [dict(BASE, amin=lo, amax=hi) for lo, hi in ((0, 0), (-1, 0), (5, 6), (127, 127), (-128, -128), (10, -10), (0, 127))]
    rows += [dict(BASE, **{k: 0}) for k in WIDE]
    rng = np.random.default_rng(11)
    for _ in range(32):
        s = draw_scales(rng)
        z = [int(v) for v in rng.integers(-128, 128, 3)]
        lo, hi = act_range(("none", "relu", "relu6")[int(rng.integers(0, 3))], s[2], z[2])
        rows.append(dict(zp1=z[0], zp2=z[1], **ipu.add_params(*s), zpo=z[2], amin=lo, amax=hi))
    return rows


def corner_rows() -> dict:
    """Every corner set at 49 (q1, q2) pairs of extreme and zero codes."""
    qx = (-128, -127, -1, 0, 1, 126, 127)
    cols = {k: [] for k in COLS}
    for c in corner_consts():
        for a, b in itertools.product(qx, qx):
            cols["q1"].append(a)
            cols["q2"].append(b)
            for k in FIELDS:
                cols[k].append(c[k])
    return {k: np.array(v, dtype=np.int64) for k, v in cols.items()}


def random_rows(n: int, rng) -> dict:
    """Uniform codes and zero points; half the constants from add_params on random scales, half raw (normalized, any int32 or 0 multipliers, any shift in [-31, 0]); mostly full clamps."""
    c = {k: rng.integers(-128, 128, n) for k in ("q1", "q2", "zp1", "zp2", "zpo")}
    for m in WIDE:
        kind = rng.integers(0, 16, n)
        c[m] = np.where(kind < 13, rng.integers(1 << 30, MAX + 1, n), np.where(kind < 15, rng.integers(MIN, MAX + 1, n), 0))
    for s in ("s1", "s2", "so"):
        c[s] = rng.integers(-31, 1, n)
    real = np.flatnonzero(rng.integers(0, 2, n))
    for i in real:
        p = ipu.add_params(*draw_scales(rng))
        for k, v in p.items():
            c[k][i] = v
    sel, r1, r2 = rng.integers(0, 8, n), rng.integers(-128, 128, n), rng.integers(-128, 128, n)
    c["amin"] = np.select([sel < 5, sel == 5], [-128, c["zpo"]], default=np.minimum(r1, r2))
    c["amax"] = np.select([sel < 5, sel == 5], [127, 127], default=np.maximum(r1, r2))
    return {k: np.asarray(c[k], dtype=np.int64) for k in COLS}


def expected(cols: dict, rounding: str) -> np.ndarray:
    return np.asarray(ipu.tflite_add(cols["q1"], cols["q2"], *[cols[k] for k in FIELDS], rounding), np.int64)


def tie_rows(n: int, rng) -> dict:
    """Constants whose outputs land on exact halves (m 2^30, s1 = s2 in {0, -1}, so in {-19, -20, -21}): random constants almost never separate the roundings."""
    c = {k: rng.integers(-128, 128, n) for k in ("q1", "q2", "zp1", "zp2", "zpo")}
    s = rng.integers(-1, 1, n)
    c.update(m1=np.full(n, 1 << 30), m2=np.full(n, 1 << 30), mo=np.full(n, 1 << 30), s1=s, s2=s, so=rng.integers(-21, -18, n),
             amin=np.full(n, -128), amax=np.full(n, 127))
    return {k: np.asarray(c[k], dtype=np.int64) for k in COLS}


def discriminators(rng, want: int = 2000) -> dict:
    """Vectors where DOUBLE and SINGLE disagree, so both RTL variants see their difference: from random and tie-structured constants."""
    pool = {k: np.concatenate([a, b]) for (k, a), b in zip(random_rows(100000, rng).items(), tie_rows(50000, rng).values())}
    d = np.flatnonzero(expected(pool, "DOUBLE") != expected(pool, "SINGLE"))
    d = rng.permutation(d)[:want]
    if d.size != want:
        raise ValueError(f"only {d.size} discriminating vectors in the pool, {want} wanted")
    return {k: v[np.sort(d)] for k, v in pool.items()}


def other(rounding: str) -> str:
    return "SINGLE" if rounding == "DOUBLE" else "DOUBLE"


def staged(cols: dict, r1: str, r2: str, ro: str) -> np.ndarray:
    """The ADD on ipu.mbqm with each stage in its own rounding (input 1, input 2, output): a per-stage reference for the swap discriminators."""
    a1 = ipu.mbqm((ipu.sx(cols["q1"], 8) - ipu.sx(cols["zp1"], 8)) << ipu.ADD_LEFT_SHIFT, cols["m1"], cols["s1"], r1)
    a2 = ipu.mbqm((ipu.sx(cols["q2"], 8) - ipu.sx(cols["zp2"], 8)) << ipu.ADD_LEFT_SHIFT, cols["m2"], cols["s2"], r2)
    raw = ipu.sx(ipu.mbqm(ipu.sx(a1 + a2, 32), cols["mo"], cols["so"], ro) + ipu.sx(cols["zpo"], 8), 32)
    return np.minimum(np.maximum(raw, ipu.sx(cols["amin"], 8)), ipu.sx(cols["amax"], 8))


SWAPS = {"input 1": (True, False), "input 2": (False, True), "both inputs": (True, True)}  # which input stages take the other rounding


def cancel_rows(n: int, rng) -> dict:
    """Input 2 cancels input 1 (d2 = -d1, a quarter one code off), m2 within 2^14 of m1, input shifts -1 to -6, a near-unity output: one input's rounding shows."""
    c = {k: rng.integers(-128, 128, n) for k in ("q1", "zp1", "zpo")}
    d = c["q1"] - c["zp1"]
    c["zp2"] = rng.integers(np.maximum(-128, d - 128), np.minimum(127, d + 127) + 1)  # so that q2 = zp2 - d is a code
    q2 = c["zp2"] - d + np.where(rng.integers(0, 4, n) == 0, rng.integers(-1, 2, n), 0)
    c["q2"] = np.where((q2 >= -128) & (q2 <= 127), q2, c["zp2"] - d)
    c["m1"] = rng.integers(1 << 30, MAX + 1, n) * np.where(rng.integers(0, 4, n) == 0, -1, 1)
    c["m2"] = np.clip(c["m1"] + rng.integers(-(1 << 14), (1 << 14) + 1, n), MIN, MAX)
    c["s1"] = -rng.integers(1, 7, n)
    c["s2"] = np.clip(np.where(rng.integers(0, 4, n) == 0, c["s1"] + rng.integers(-1, 2, n), c["s1"]), -31, 0)
    c.update(mo=rng.integers(1 << 30, MAX + 1, n), so=-rng.integers(0, 3, n), amin=np.full(n, -128), amax=np.full(n, 127))
    return {k: np.asarray(c[k], dtype=np.int64) for k in COLS}


def input_discriminators(rng, want: int = 200) -> dict:
    """Distinct vectors where swapping input 1's, input 2's or both inputs' rounding changes the output: want for each swap in each build."""
    pool = cancel_rows(50000, rng)
    taken = np.zeros(pool["q1"].size, dtype=bool)
    for b in ipu.ROUNDINGS:
        ref = staged(pool, b, b, b)
        for name, (i1, i2) in SWAPS.items():
            hit = np.flatnonzero((staged(pool, other(b) if i1 else b, other(b) if i2 else b, b) != ref) & ~taken)
            if hit.size < want:
                raise ValueError(f"only {hit.size} vectors in the pool where swapping the rounding of {name} changes a {b} result, {want} wanted")
            taken[rng.permutation(hit)[:want]] = True
    return {k: v[taken] for k, v in pool.items()}


N_DISC, N_IDISC = 2000, 200  # output-stage discriminators; input-stage ones per swap and build (6 x 200)


def vector_parts(n_random: int, seed: int) -> list:
    """A vector file's rows in file order: corners, output-stage and input-stage rounding discriminators, random."""
    rng = np.random.default_rng(seed)
    corners, disc, rand = corner_rows(), discriminators(rng, N_DISC), random_rows(n_random, rng)
    return [corners, disc, input_discriminators(rng, N_IDISC), rand]  # input-stage ones drawn last, so the others keep their draws


def vector_count(n_random: int) -> int:
    return len(corner_consts()) * 49 + N_DISC + len(ipu.ROUNDINGS) * len(SWAPS) * N_IDISC + n_random


def write_vectors(path: str, cols: dict, rounding: str) -> None:
    want = expected(cols, rounding)
    table = np.stack([ipu.bits(cols[k], 32 if k in WIDE else 8) for k in COLS] + [ipu.bits(want, 8)], axis=1)
    np.savetxt(path, table, fmt=" ".join("%08x" if k in WIDE else "%02x" for k in COLS) + " %02x")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("out", nargs="?")
    p.add_argument("--rounding", choices=ipu.ROUNDINGS)
    p.add_argument("--random", type=int, default=1000000)
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--consts", choices=("corners", "oracle"), help="write a constant-set file for the exhaustive or oracle mode")
    p.add_argument("--oracle", help="G0b's output directory (with --consts oracle)")
    p.add_argument("--count", action="store_true", help="print only how many rows (vectors or constant sets) the file holds, for TB_tfliteAdd's +N=")
    a = p.parse_args()
    if a.count:
        print(len(corner_consts() if a.consts == "corners" else oracle_consts(a.oracle)) if a.consts else vector_count(a.random))
        return
    if not a.out:
        p.error("give the output file")
    if a.consts:
        rows = corner_consts() if a.consts == "corners" else oracle_consts(a.oracle)
        write_consts(a.out, rows)
        print(f"{a.out}: {len(rows)} constant sets ({a.consts})")
        return
    if not a.rounding:
        p.error("a vector file needs --rounding")
    parts = vector_parts(a.random, a.seed)
    cols = {k: np.concatenate([x[k] for x in parts]) for k in COLS}
    write_vectors(a.out, cols, a.rounding)
    w, o = expected(cols, a.rounding), expected(cols, other(a.rounding))
    print(f"{a.out}: {w.size} vectors ({parts[0]['q1'].size} corners, {parts[1]['q1'].size} rounding discriminators, "
          f"{parts[2]['q1'].size} input-rounding discriminators, {a.random} random), "
          f"rounding {a.rounding}, {int(np.sum(w != o))} differ from the other rounding, "
          f"{100 * float(np.mean((w == cols['amin']) | (w == cols['amax']))):.1f}% at a clamp bound")


if __name__ == "__main__":
    main()
