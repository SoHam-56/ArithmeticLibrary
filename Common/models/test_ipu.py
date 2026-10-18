#!/usr/bin/env python3
"""Checks ipu.py: the integer units on hand values and exhaustively, and the affine int8 encoders and models against their definitions and the true function."""
import math
import os
import random
import sys
from fractions import Fraction

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ipu  # noqa: E402
import int8_vectors  # noqa: E402
import truth  # noqa: E402

MIN, MAX = -(1 << 31), (1 << 31) - 1
fails = checks = 0


def check(what, got, want):
    global fails, checks
    checks += 1
    g, w = np.asarray(got), np.asarray(want)
    if g.shape != w.shape or np.any(g != w):
        fails += 1
        if fails <= 30:
            print(f"[FAIL] {what}: got {g.ravel()[:8].tolist()}, want {w.ravel()[:8].tolist()}")


# Hand-derived values; each comment is the derivation.

INT_MUL = [(-128, -128, 16384), (-128, 127, -16256), (127, 127, 16129), (0x80, 0x80, 16384), (0xFF, 1, -1), (0, -128, 0)]
INT_ADD = [(MAX, 1, MIN), (MIN, -1, MAX), (-5, 3, -2), (0xFFFFFFFF, 1, 0), (MIN, MIN, 0)]
FX_MAC = [  # a, x, c, floor((a * x) / 2^11) + c saturated to int16 (Q4.11, 1.0 = 2048)
    (2048, 2048, 0, 2048), (-1, 1, 0, -1), (1, 1, 0, 0), (-2048, 3, 0, -3), (-2049, 1, 0, -2), (1024, 1024, -100, 412),
    (32767, 32767, 0, 32767), (-32768, 32767, 0, -32768), (-32768, -32768, 0, 32767), (2048, 2048, 32767, 32767),
    (-2048, 2048, -32768, -32768),
]


def wrap32(v):
    return ((v + (1 << 31)) & 0xFFFFFFFF) - (1 << 31)


def raises(fn, *a):
    try:
        fn(*a)
    except ValueError:
        return True
    return False


def def_round(num: Fraction) -> int:  # round half up of an exact rational, from its definition
    return math.floor(num + Fraction(1, 2))


def def_requantize(acc, m, e, zp, lo, hi):  # int8Requantizer's function on Python integers: no intermediate width
    return min(hi, max(lo, def_round(Fraction(acc * m, 1 << e)) + zp))


def def_qadd(q1, q2, z1, z2, m1, m2, e, zo, lo, hi):  # int8QuantizedAdder's function on Python integers
    return min(hi, max(lo, def_round(Fraction((q1 - z1) * m1 + (q2 - z2) * m2, 1 << e)) + zo))


def affine() -> None:
    rng = np.random.default_rng(7)
    # encode_scale, hand-derived: s = m 2^-e
    for s0, want in ((1.0, (1 << 23, 23)), (0.5, (1 << 23, 24)), (0.75, (12582912, 24)), (2.0 ** 8, ((1 << 24) - 1, 16)), (300.0, ((1 << 24) - 1, 16)),
                     (256.0 - 2.0 ** -20, ((1 << 24) - 1, 16)), (2.0 ** -32, (1 << 23, 55)), (2.0 ** -33, (0, 55)), (1e-12, (0, 55)),
                     (1.0 + 2.0 ** -24, (1 << 23, 23)), (1.0 + 3 * 2.0 ** -24, ((1 << 23) + 2, 23)), (2.0 - 2.0 ** -30, (1 << 23, 22))):
        check(f"encode_scale({s0!r})", ipu.encode_scale(s0), want)
    for bad in (0.0, -1.0, float("nan"), float("inf")):
        check(f"encode_scale({bad!r}) raises", raises(ipu.encode_scale, bad), True)
    ss = np.concatenate([10.0 ** rng.uniform(-12, np.log10(2.0 ** 31), 20000), [2.0 ** k for k in range(-45, 32)],
                         [2.0 ** k * (1 + d) for k in range(-34, 10) for d in (2.0 ** -25, -2.0 ** -25, 2.0 ** -24 * 1.5)]])
    codes = [ipu.encode_scale(float(x)) for x in ss]
    m, e = np.array([c[0] for c in codes]), np.array([c[1] for c in codes])
    r = truth.gate_scale(ss, m, e)
    check(f"encode_scale on {ss.size} scales passes gate_scale", (r.ok, r.over), (True, 0))
    check("encode_scale's shifts lie in [16, 55]", bool(np.all((e >= 16) & (e <= 55))), True)
    check("gate_scale fails m one high", truth.gate_scale([0.75], [12582913], [24]).ok, False)
    check("gate_scale fails the shift one low", truth.gate_scale([0.75], [12582912], [23]).ok, False)
    check("gate_scale fails an unnormalized m", truth.gate_scale([0.75], [6291456], [23]).ok, False)
    check("gate_scale fails a nonzero m past the flush", truth.gate_scale([1e-12], [1], [55]).ok, False)
    check("gate_scale fails an empty set", truth.gate_scale([], [], []).ok, False)
    # encode_add, hand-derived: r_i = m_i 2^-e
    for (a, b), want in (((1.0, 1.0), (1 << 31, 1 << 31, 31)), ((0.5, 0.25), (1 << 31, 1 << 30, 32)), ((2.0 ** 22, 1.0), (1 << 31, 1 << 9, 9)),
                         ((2.0 ** -11, 2.0 ** -12), (0, 0, 41)), ((2.0 ** -10, 3.0), (1 << 20, 3 << 30, 30))):
        check(f"encode_add({a!r}, {b!r})", ipu.encode_add(a, b), tuple(int(x) for x in want))
    for a, b in ((2.0 ** 23, 1.0), (1.0, 2.0 ** 23 * (1 - 2.0 ** -40)), (0.0, 1.0), (1.0, -1.0), (float("inf"), 1.0)):
        check(f"encode_add({a!r}, {b!r}) raises", raises(ipu.encode_add, a, b), True)
    try:
        ipu.encode_add(2.0 ** 24, 1.0)
    except ValueError as x:
        check("encode_add's refusal names the domain", "outside int8QuantizedAdder's domain" in str(x), True)
    # activation_clamp
    for args, want in ((("none", 0.1, 5), (-128, 127)), (("relu", 0.1, -5), (-5, 127)), (("relu6", 0.05, -128), (-128, -8)),
                       (("relu6", 0.01, 0), (0, 127)), (("relu_n1_to_1", 1 / 64, 0), (-64, 64)), (("relu6", 0.04, 10), (10, 127))):
        check(f"activation_clamp{args}", ipu.activation_clamp(*args), want)
    check("activation_clamp('gelu') raises", raises(ipu.activation_clamp, "gelu", 0.1, 0), True)
    # requantize and qadd against their definitions on Python integers
    n = 20000
    acc = np.concatenate([rng.integers(MIN, MAX + 1, n), [MIN, MIN + 1, -1, 0, 1, MAX - 1, MAX]])
    mm = np.concatenate([rng.integers(0, 1 << 24, n), [0, 1, (1 << 23), (1 << 24) - 1, (1 << 24) - 1, 1 << 23, (1 << 24) - 1]])
    ee = np.concatenate([rng.integers(0, 56, n), [0, 55, 16, 16, 55, 23, 0]])
    zz, lo = rng.integers(-128, 128, mm.size), rng.integers(-128, 128, mm.size)
    hi = np.maximum(lo, rng.integers(-128, 128, mm.size))
    got = ipu.requantize(acc, mm, ee, zz, lo, hi)
    want = [def_requantize(*(int(v[i]) for v in (acc, mm, ee, zz, lo, hi))) for i in range(mm.size)]
    check(f"requantize equals its definition on {mm.size} rows", got.tolist(), want)
    check("requantize raises on m = 2^24", raises(ipu.requantize, 1, 1 << 24, 20, 0, -128, 127), True)
    check("requantize raises on e = 56", raises(ipu.requantize, 1, 1, 56, 0, -128, 127), True)
    q1, q2 = rng.integers(-128, 128, n), rng.integers(-128, 128, n)
    z1, z2, zo = rng.integers(-128, 128, n), rng.integers(-128, 128, n), rng.integers(-128, 128, n)
    m1, m2, ea = rng.integers(0, 1 << 32, n), rng.integers(0, 1 << 32, n), rng.integers(0, 42, n)
    alo = rng.integers(-128, 128, n)
    ahi = np.maximum(alo, rng.integers(-128, 128, n))
    got = ipu.qadd(q1, q2, z1, z2, m1, m2, ea, zo, alo, ahi)
    want = [def_qadd(*(int(v[i]) for v in (q1, q2, z1, z2, m1, m2, ea, zo, alo, ahi))) for i in range(n)]
    check(f"qadd equals its definition on {n} rows", got.tolist(), want)
    check("qadd raises on m1 = 2^32", raises(ipu.qadd, 1, 1, 0, 0, 1 << 32, 1, 20, 0, -128, 127), True)
    check("qadd raises on e = 42", raises(ipu.qadd, 1, 1, 0, 0, 1, 1, 42, 0, -128, 127), True)
    # the true function: encode_scale + requantize on dense scales and the saturation corners, encode_add + qadd on ratio pairs
    s_rows = 10.0 ** rng.uniform(-12, np.log10(2.0 ** 31), 4000)
    s_all, a_all, z_all, lo_all, hi_all = [], [], [], [], []
    for s0 in s_rows:
        lim = max(1, min(MAX, int(400 / s0)))
        a = np.clip(rng.integers(-lim, lim + 1, 64), MIN, MAX)
        z = int(rng.integers(-128, 128))
        s_all += [s0] * a.size
        a_all += a.tolist()
        z_all += [z] * a.size
        lo_all += [-128] * a.size
        hi_all += [127] * a.size
    for a, s0, z, l, h in int8_vectors.saturation_corners():
        s_all.append(s0); a_all.append(a); z_all.append(z); lo_all.append(l); hi_all.append(h)
    codes = [ipu.encode_scale(x) for x in s_all]
    q = ipu.requantize(a_all, [c[0] for c in codes], [c[1] for c in codes], z_all, lo_all, hi_all)
    r = truth.gate_requantize(a_all, s_all, z_all, lo_all, hi_all, q)
    print(truth.stage_line(r))
    check(f"requantize(encode_scale) on {len(s_all)} rows passes the true function", (r.ok, r.over, r.n > 0), (True, 0, True))
    nov = len(int8_vectors.saturation_corners())
    r = truth.gate_requantize(a_all[-nov:], s_all[-nov:], z_all[-nov:], lo_all[-nov:], hi_all[-nov:], q[-nov:])
    check(f"the {nov} saturation corners pass the true function", (r.ok, r.n), (True, nov))
    check("lane C's example clamps to -128", int(q[-nov]), -128)
    check("gate_requantize fails the corners with each output's sign flipped", truth.gate_requantize(
        a_all[-nov:], s_all[-nov:], z_all[-nov:], lo_all[-nov:], hi_all[-nov:], -1 - q[-nov:]).ok, False)
    check("gate_requantize fails an empty set (no vacuous pass)", truth.gate_requantize([], [], [], [], [], []).ok, False)
    check("gate_requantize fails one code off by two", truth.gate_requantize([100], [0.5], [0], [-128], [127], [52]).ok, False)
    check("gate_requantize passes one code from the true value", truth.gate_requantize([101], [0.5], [0], [-128], [127], [51]).ok, True)
    check("gate_requantize: 1% of |t| = 150.5 steps passes 1.5 codes", truth.gate_requantize([301], [0.5], [-128], [-128], [127], [24]).ok, True)
    check("gate_requantize: and fails 2.5", truth.gate_requantize([301], [0.5], [-128], [-128], [127], [25]).ok, False)
    rr = 2.0 ** rng.uniform(-14, 22.9, (3000, 2))
    rr[:1000, 1] = rr[:1000, 0] * (1 + rng.choice([0.0, 2.0 ** -30, -2.0 ** -24, 2.0 ** -12], 1000))
    s_out = 2.0 ** rng.uniform(-12, -4, 3000)
    qq1, qq2 = rng.integers(-128, 128, (2, 3000, 32))
    bad = n_add = 0
    for i, (r1, r2) in enumerate(rr):
        if max(r1, r2) >= 2.0 ** 23:
            continue
        c1, c2, ce = ipu.encode_add(r1, r2)
        z = rng.integers(-128, 128, 3)
        y = ipu.qadd(qq1[i], qq2[i], z[0], z[1], c1, c2, ce, z[2], -128, 127)
        g = truth.gate_quantized_add(qq1[i], qq2[i], r1 * s_out[i], z[0], r2 * s_out[i], z[1], s_out[i], z[2], -128, 127, y)
        bad += g.over
        n_add += g.n
    check(f"qadd(encode_add) on {n_add} ADDs passes the true function", (bad, n_add > 0), (0, True))
    check("gate_quantized_add fails an empty set", truth.gate_quantized_add([], [], 1, 0, 1, 0, 1, 0, -128, 127, []).ok, False)
    check("gate_quantized_add: (10 + 10) / 4", truth.gate_quantized_add([10], [10], 0.25, 0, 0.25, 0, 1.0, 0, -128, 127, [5]).ok, True)
    check("gate_quantized_add fails 3 for 5", truth.gate_quantized_add([10], [10], 0.25, 0, 0.25, 0, 1.0, 0, -128, 127, [3]).ok, False)
    check("gate_quantized_add reads z1", truth.gate_quantized_add([13], [10], 0.25, 3, 0.25, 0, 1.0, 0, -128, 127, [5]).ok, True)
    check("gate_quantized_add clamps at lo", truth.gate_quantized_add([-100], [-100], 0.5, 0, 0.5, 0, 1.0, 3, 3, 127, [3]).ok, True)


def main() -> None:
    for a, b, w in INT_MUL:
        check(f"int_mul({a}, {b})", ipu.int_mul(a, b), w)
    for a, b, w in INT_ADD:
        check(f"int_add({a}, {b})", ipu.int_add(a, b), w)
    for a, x, c, w in FX_MAC:
        check(f"fx_mac({a}, {x}, {c})", ipu.fx_mac(a, x, c), w)
    # Exhaustive int8 products, as values and as 8-bit patterns.
    g = np.arange(-128, 128, dtype=np.int64)
    ga, gb = np.meshgrid(g, g)
    check("int_mul exhaustive", ipu.int_mul(ga, gb), ga * gb)
    check("int_mul exhaustive, bit patterns", ipu.int_mul(ga & 0xFF, gb & 0xFF), ga * gb)
    # Random: the vectorized models against Python integers.
    rng = random.Random(7)
    edge = [MIN, MIN + 1, -(1 << 30), -1, 0, 1, 1 << 30, MAX - 1, MAX]
    n = 20000
    A = [rng.choice(edge) if rng.random() < 0.1 else rng.randint(MIN, MAX) for _ in range(n)]
    B = [rng.choice(edge) if rng.random() < 0.1 else rng.randint(MIN, MAX) for _ in range(n)]
    X = [rng.randint(-32768, 32767) for _ in range(n)]
    C = [rng.randint(-32768, 32767) for _ in range(n)]
    Y = [rng.randint(-32768, 32767) for _ in range(n)]
    check("fx_mac random", ipu.fx_mac(np.array(X), np.array(Y), np.array(C)),
          [max(-32768, min(32767, ((x * y) >> 11) + c)) for x, y, c in zip(X, Y, C)])
    check("int_add random", ipu.int_add(np.array(A, dtype=np.int64), np.array(B, dtype=np.int64)), [wrap32(a + b) for a, b in zip(A, B)])
    affine()

    print(f"test_ipu: {checks} checks, {fails} failures")
    print(f"RESULT: {'PASSED' if fails == 0 else 'FAILED'}")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
