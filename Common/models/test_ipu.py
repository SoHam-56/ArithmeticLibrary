#!/usr/bin/env python3
"""Checks ipu.py: hand-derived TFLite values, then the vectorized models against scalar big-integer transcriptions of the C."""
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
H = 1 << 30  # 0.5 in Q0.31
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
SRDHM = [  # a, b, SaturatingRoundingDoublingHighMul(a, b)
    (MIN, MIN, MAX),  # (-1) * (-1) = +1 does not fit Q0.31: the one saturating case
    (H, H, 1 << 29),  # 0.5 * 0.5 = 0.25
    (MAX, MAX, MAX - 1),  # (2^31 - 1)^2 / 2^31 = 2^31 - 2 + 2^-31, + 0.5 truncates to 2^31 - 2
    (MIN, MAX, MIN + 1),  # -(2^31 - 1) exactly; nudge 1 - 2^30 and truncation leave it
    (MIN, H, -H),  # -1 * 0.5
    (1, H, 1),  # +0.5 LSB rounds up
    (-1, H, 0),  # -0.5 LSB: (-2^30 + 1 - 2^30) / 2^31 truncates to 0, a tie toward +inf
    (3, H, 2),  # 1.5 -> 2
    (-3, H, -1),  # -1.5 -> -1 (toward +inf)
    (5, MAX, 5),  # 4.9999999977 -> 5
    (-5, MAX, -5),  # -4.9999999977 -> -5
]
RDBPOT = [  # x, exponent, RoundingDivideByPOT(x, exponent): nearest, ties away from zero
    (5, 1, 3),  # 2.5 -> 3
    (-5, 1, -3),  # -2.5 -> -3: remainder 1 is not above threshold 0 + 1
    (-3, 1, -2),  # -1.5 -> -2
    (6, 2, 2),  # 1.5 -> 2
    (-6, 2, -2),  # -1.5 -> -2: remainder 2, threshold 1 + 1
    (-7, 2, -2),  # -1.75 -> -2
    (-5, 2, -1),  # -1.25 -> -1: remainder 3 above threshold 2
    (-7, 0, -7),  # exponent 0: unchanged
    (MIN, 31, -1),  # exactly -1
    (MAX, 31, 1),  # 0.99999999953 -> 1
    (H, 31, 1),  # +0.5 -> 1
    (-H, 31, -1),  # -0.5 -> -1
    (-H + 1, 31, 0),  # -0.49999999953 -> 0
]
MBQM = [  # acc, mult, shift, DOUBLE, SINGLE
    (100, H, 0, 50, 50),  # 100 * 0.5
    (3, H, -1, 1, 1),  # 0.75
    (5, H, -1, 2, 1),  # 1.25: DOUBLE rounds 2.5 up to 3, then 1.5 away to 2; SINGLE rounds 1.25 once
    (6, H, -1, 2, 2),  # +1.5 tie: both up
    (-6, H, -1, -2, -1),  # -1.5 tie: DOUBLE away from zero, SINGLE toward +inf
    (-3, H, -1, -1, -1),  # -0.75
    (-1, H, 0, 0, 0),  # -0.5: both toward +inf (SRDHM, and SINGLE's floor)
    (1000, H, -3, 63, 63),  # +62.5
    (-1000, H, -3, -63, -62),  # -62.5
    (MAX, MAX, -31, 1, 1),  # just under 1.0
    (MIN, MAX, -31, -1, -1),  # just above -1.0
    (MIN, MAX, 0, MIN + 1, MIN + 1),
    (MAX, MAX, 0, MAX - 1, MAX - 1),
    (100, H, 8, 12800, 12800),  # 100 * 2^8 * 0.5
    (-(1 << 23), H, 8, -H, -H),  # acc << 8 is exactly INT32_MIN
    (1 << 24, H, 8, 1 << 30, MIN),  # outside TFLite's range: DOUBLE's acc << 8 saturates to INT32_MAX (TFLite's wraps to 0), SINGLE's 2^31 wraps to INT32_MIN
    (-(1 << 24) - 1, H, 8, -(1 << 30), MAX - 127),  # DOUBLE saturates to INT32_MIN (TFLite's wraps to -256); SINGLE's -2^31 - 128 wraps
    (1 << 23, MAX, 8, MAX - 1, MAX),  # acc << 8 = 2^31: DOUBLE saturates to INT32_MAX (TFLite's wraps to INT32_MIN); SINGLE fits
    (1, H, 30, 1 << 29, 1 << 29),  # the largest shift
    (1 << 30, H, -30, 1, 1),  # +0.5: away (DOUBLE) and up (SINGLE) agree
    (1 << 30, H, -31, 0, 0),  # 0.25
]
MBQM += [((1 << (1 - s)) if s <= 0 else 1, H, s, 1 if s <= 0 else 1 << (s - 1), 1 if s <= 0 else 1 << (s - 1))
         for s in range(-29, 9)]  # exact powers of two at every shift -29..8
MBQM += [(-(3 << (-s)), H, s, -2 if s < 0 else -1, -1)
         for s in range(-29, 1)]  # -1.5 at every right shift: DOUBLE -2 (s = 0: SRDHM already gave -1), SINGLE -1
REQUANT = [  # acc, mult, shift, zp, act_min, act_max, DOUBLE, SINGLE
    (1000, H, -3, -5, -128, 127, 58, 58),  # 62.5 -> 63, + zp -5
    (-1000, H, -3, -5, -5, 127, -5, -5),  # ReLU: -68 / -67 clamp at the zero point
    (10 ** 6, MAX, 0, 0, -128, 127, 127, 127),
    (MAX, MAX, 0, 127, -128, 127, -128, -128),  # 2^31 - 2 + 127 wraps in int32, as TFLite's acc += output_offset does
    (-6, H, -1, 0, -128, 127, -2, -1),
    (5, H, -1, 0, -128, 127, 2, 1),
    (0, H, 0, 0, 5, -5, -5, -5),  # act_min > act_max: max then min gives act_max
    (1 << 24, H, 8, 0, -128, 127, 127, -128),  # DOUBLE saturates the left shift (TFLite's wraps to 0); SINGLE wraps
    (0x80, H, 0, 0x80, 0x80, 0x7F, -64, -64),  # 8-bit patterns: zp and act_min read as -128; 64 - 128
]
INT_MUL = [(-128, -128, 16384), (-128, 127, -16256), (127, 127, 16129), (0x80, 0x80, 16384), (0xFF, 1, -1), (0, -128, 0)]
INT_ADD = [(MAX, 1, MIN), (MIN, -1, MAX), (-5, 3, -2), (0xFFFFFFFF, 1, 0), (MIN, MIN, 0)]
FX_MAC = [  # a, x, c, floor((a * x) / 2^11) + c saturated to int16 (Q4.11, 1.0 = 2048)
    (2048, 2048, 0, 2048), (-1, 1, 0, -1), (1, 1, 0, 0), (-2048, 3, 0, -3), (-2049, 1, 0, -2), (1024, 1024, -100, 412),
    (32767, 32767, 0, 32767), (-32768, 32767, 0, -32768), (-32768, -32768, 0, 32767), (2048, 2048, 32767, 32767),
    (-2048, 2048, -32768, -32768),
]
QM = [  # real -> (mult, shift): frexp, then the mantissa * 2^31 rounded half away from zero
    (0.5, (1 << 30, 0)),
    (1.0, (1 << 30, 1)),
    (0.75, (1610612736, 0)),
    (0.1, (1717986918, -3)),  # 0.8 * 2^31 = 1717986918.4
    (2.0 ** -32, (1 << 30, -31)),  # shift -31 is kept
    (2.0 ** -33, (0, 0)),  # shift -32 flushes to zero
    (0.0, (0, 0)),
    (1.0 - 2.0 ** -40, (1 << 30, 1)),  # the mantissa rounds to 2^31: halved, shift + 1
    (1.0 / 255.0, (1077952576, -7)),
    (0.5 + 2.0 ** -32, ((1 << 30) + 1, 0)),  # 2^30 + 0.5 rounds away from zero; numpy.round would give 2^30
]

QMS = [  # real -> QuantizeMultiplierSmallerThanOneExp: QuantizeMultiplier with shift <= 0
    (0.5, (1 << 30, 0)),
    (0.25, (1 << 30, -1)),
    (0.75, (1610612736, 0)),
    (2.0 ** -31, (1 << 30, -30)),
    (2.0 ** -33, (0, 0)),  # shift -32 flushes to (0, 0), which TFLite accepts (shift 0 <= 0)
]
QMS_BAD = [1.0, 0.0, -0.5, 2.0, 1.0 - 2.0 ** -40]  # the last rounds to 2^31: halved, shift 1 > 0, TFLite's CHECK fails
P_EQ = dict(m1=1 << 30, s1=0, m2=1 << 30, s2=0, mo=1 << 30, so=-19)  # add_params(0.5, 0.5, 1.0): 0.5, 0.5, 2^-20
P_UN = dict(m1=1 << 30, s1=-1, m2=1 << 30, s2=0, mo=1431655765, so=-19)  # add_params(0.25, 0.5, 0.75): 0.25, 0.5, 1/(0.75 * 2^20)
P_WIDE = dict(m1=1 << 30, s1=-10, m2=1 << 30, s2=0, mo=1 << 30, so=-15)  # add_params(2^-10, 1, 2^-3): scale ratio 2^10
P_F32 = dict(m1=1717986944, s1=-2, m2=1 << 30, s2=0, mo=1342177260, so=-17)  # add_params(0.1, 0.25, 0.1), f = float32(0.1) = 13421773 * 2^-27: f / 0.5 -> 13421773 * 2^7, shift -2; 0.5 / (2^20 f) -> round(2^54 / 13421773) = 1342177260, shift -17 (double 0.1 gives 1717986918 and 1342177280)
ADD = [  # q1, q2, zp1, zp2, words, zpo, amin, amax, DOUBLE, SINGLE; P_EQ gives y = (d1 + d2) / 2
    (10, 6, 0, 0, P_EQ, 0, -128, 127, 8, 8),
    (1, 0, 0, 0, P_EQ, 0, -128, 127, 1, 1),  # +0.5: away (DOUBLE) and up (SINGLE) agree
    (-1, 0, 0, 0, P_EQ, 0, -128, 127, -1, 0),  # -0.5: DOUBLE away from zero, SINGLE toward +inf
    (3, 0, 0, 0, P_EQ, 0, -128, 127, 2, 2),  # +1.5
    (-3, 0, 0, 0, P_EQ, 0, -128, 127, -2, -1),  # -1.5
    (127, -128, -128, 127, P_EQ, 5, -128, 127, 5, 5),  # d1 = 255, d2 = -255: 0 + zpo
    (127, 127, 0, 0, P_EQ, 0, -128, 100, 100, 100),  # 127 clamped to act_max
    (-128, -128, 0, 0, P_EQ, 0, -128, 127, -128, -128),
    (0, 0, 0, 0, P_EQ, 0, 20, 10, 10, 10),  # act_min > act_max: max then min gives act_max
    (100, 50, 0, 0, dict(P_EQ, m1=0), 3, -128, 127, 28, 28),  # a flushed multiplier drops input 1: 50 / 2 + 3
    (12, 3, 0, 0, P_UN, 0, -128, 127, 6, 6),  # (0.25 * 12 + 0.5 * 3) / 0.75 = 6
    (-12, -3, 0, 0, P_UN, 0, -128, 127, -6, -6),
    (0x80, 0x7F, 0, 0, P_EQ, 0, 0x80, 0x7F, -1, 0),  # 8-bit patterns: -128 + 127 = -1, so -0.5; clamp patterns read signed
    (-128, -128, 0, 0, P_EQ, 0, -20, 127, -20, -20),  # -128 below act_min: saturates to -20
    (-128, -128, 0, 0, P_EQ, -100, -128, 127, -128, -128),  # -128 - 100 = -228, below the int8 range: -128
    (-10, -6, 0, 0, P_EQ, 127, -128, 127, 119, 119),  # zp_o 127: -8 + 127
    (10, 6, 0, 0, P_EQ, 127, -128, 127, 127, 127),  # zp_o 127: 8 + 127 = 135 saturates
    (10, 6, 0, 0, P_EQ, -128, -128, 127, -120, -120),  # zp_o -128: 8 - 128
    (-10, -6, 0, 0, P_EQ, -128, -128, 127, -128, -128),  # zp_o -128: -8 - 128 = -136 saturates
    (127, 127, -128, -128, P_EQ, -128, -128, 127, 127, 127),  # same-sign maximal d = 255 on both: (255 + 255) / 2 - 128
    (127, 127, -128, -128, P_EQ, 0, -128, 127, 127, 127),  # d = 255 on both, zp_o 0: 255 saturates
    (-128, -128, 127, 127, P_EQ, 127, -128, 127, -128, -128),  # d = -255 on both: -255 + 127
]


def wrap32(v):
    return ((v + (1 << 31)) & 0xFFFFFFFF) - (1 << 31)


def c_srdhm(a, b):  # fixedpoint.h, line for line
    overflow = a == b == MIN
    ab = a * b
    n = ab + ((1 << 30) if ab >= 0 else 1 - (1 << 30))
    q = (n >> 31) if n >= 0 else -((-n) >> 31)  # C++ '/' truncates toward zero
    return MAX if overflow else q


def c_rdbpot(x, e):  # fixedpoint.h RoundingDivideByPOT
    mask = (1 << e) - 1
    return (x >> e) + (1 if (x & mask) > (mask >> 1) + (1 if x < 0 else 0) else 0)


def c_mbqm(x, m, s, rounding, sat=False):  # common.cc, both builds; sat: tfliteRequant's saturating left shift in place of the int32 wrap
    if rounding == "DOUBLE":
        xs = x * (1 << max(s, 0))
        return c_rdbpot(c_srdhm(max(MIN, min(MAX, xs)) if sat else wrap32(xs), m), max(-s, 0))
    t = 31 - s
    return wrap32((x * m + (1 << (t - 1))) >> t)


def c_requant(x, m, s, zp, lo, hi, rounding, sat=False):
    return min(max(wrap32(c_mbqm(x, m, s, rounding, sat) + zp), lo), hi)


def c_add(q1, q2, zp1, zp2, m1, s1, m2, s2, mo, so, zpo, lo, hi, rounding, ls=20):  # reference integer_ops/add.h AddFunc, line for line; ls is params.left_shift
    a1 = c_mbqm(wrap32((q1 - zp1) * (1 << ls)), m1, s1, rounding)
    a2 = c_mbqm(wrap32((q2 - zp2) * (1 << ls)), m2, s2, rounding)
    raw = wrap32(c_mbqm(wrap32(a1 + a2), mo, so, rounding) + zpo)
    return min(hi, max(lo, raw))


def half_away(num, den):  # exact nearest of num / den, ties away from zero
    q, r = divmod(abs(num), den)
    q += 2 * r >= den
    return q if num >= 0 else -q


# ── affine int8: the neutral encoders, the bit-exact unit models against their definitions, and the true function ──


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
    for a, b, w in SRDHM:
        check(f"srdhm({a}, {b})", ipu.srdhm(a, b), w)
    for x, e, w in RDBPOT:
        check(f"rdbpot({x}, {e})", ipu.rdbpot(x, e), w)
    for x, m, s, d, sg in MBQM:
        check(f"mbqm({x}, {m}, {s}, DOUBLE)", ipu.mbqm(x, m, s, "DOUBLE"), d)
        check(f"mbqm({x}, {m}, {s}, SINGLE)", ipu.mbqm(x, m, s, "SINGLE"), sg)
    for x, m, s, z, lo, hi, d, sg in REQUANT:
        check(f"requant({x}, {m}, {s}, {z}, {lo}, {hi}, DOUBLE)", ipu.requant(x, m, s, z, lo, hi, "DOUBLE"), d)
        check(f"requant({x}, {m}, {s}, {z}, {lo}, {hi}, SINGLE)", ipu.requant(x, m, s, z, lo, hi, "SINGLE"), sg)
    for a, b, w in INT_MUL:
        check(f"int_mul({a}, {b})", ipu.int_mul(a, b), w)
    for a, b, w in INT_ADD:
        check(f"int_add({a}, {b})", ipu.int_add(a, b), w)
    for a, x, c, w in FX_MAC:
        check(f"fx_mac({a}, {x}, {c})", ipu.fx_mac(a, x, c), w)
    for real, want in QM:
        check(f"quantize_multiplier({real!r})", ipu.quantize_multiplier(real), want)
    check("quantize_multiplier(2^31, SINGLE)", ipu.quantize_multiplier(2.0 ** 31, "SINGLE"), ((1 << 31) - 1, 30))
    check("quantize_multiplier(2^31, DOUBLE)", ipu.quantize_multiplier(2.0 ** 31, "DOUBLE"), (1 << 30, 32))
    check("round_half_away", [ipu.round_half_away(v) for v in (2.5, -2.5, 0.49999999999999994, -0.5)], [3, -3, 0, -1])  # 0.5 - 2^-54: floor(v + 0.5) would give 1

    # Exhaustive int8 products, as values and as 8-bit patterns.
    g = np.arange(-128, 128, dtype=np.int64)
    ga, gb = np.meshgrid(g, g)
    check("int_mul exhaustive", ipu.int_mul(ga, gb), ga * gb)
    check("int_mul exhaustive, bit patterns", ipu.int_mul(ga & 0xFF, gb & 0xFF), ga * gb)

    # Random: the vectorized models against the scalar transcriptions; every shift appears.
    rng = random.Random(7)
    edge = [MIN, MIN + 1, -H, -1, 0, 1, H, MAX - 1, MAX]
    n = 20000

    def r32():
        return rng.choice(edge) if rng.random() < 0.1 else rng.randint(MIN, MAX)

    A = [r32() for _ in range(n)]
    B = [r32() for _ in range(n)]
    S = list(range(-31, 31)) + [rng.randint(-31, 30) for _ in range(n - 62)]
    E = list(range(32)) + [rng.randint(0, 31) for _ in range(n - 32)]
    Z = [rng.randint(-128, 127) for _ in range(n)]
    LO = [rng.randint(-128, 127) for _ in range(n)]
    HI = [rng.randint(-128, 127) for _ in range(n)]
    npa = [np.array(v, dtype=np.int64) for v in (A, B, S, E, Z, LO, HI)]
    na, nb, ns, ne, nz, nlo, nhi = npa
    check("srdhm random", ipu.srdhm(na, nb), [c_srdhm(a, b) for a, b in zip(A, B)])
    check("srdhm = floor((a*b + 2^30) / 2^31), the RTL's form",
          [c_srdhm(a, b) for a, b in zip(A, B)], [MAX if a == b == MIN else (a * b + H) >> 31 for a, b in zip(A, B)])
    check("rdbpot random", ipu.rdbpot(na, ne), [c_rdbpot(x, e) for x, e in zip(A, E)])
    check("rdbpot = nearest, ties away", [c_rdbpot(x, e) for x, e in zip(A, E)], [half_away(x, 1 << e) for x, e in zip(A, E)])
    # Where TFLite's int32 left shift is defined, ipu is TFLite's common.cc bit for bit; where it overflows, DOUBLE saturates instead of wrapping.
    ovf = np.array([not MIN <= x * (1 << max(s, 0)) <= MAX for x, s in zip(A, S)])
    check("random draws overflow DOUBLE's left shift, and others do not", (int(ovf.sum()) > 1000, int((~ovf).sum()) > 1000), (True, True))
    for r in ipu.ROUNDINGS:
        tfl = np.array([c_mbqm(x, m, s, r) for x, m, s in zip(A, B, S)])
        check(f"mbqm random {r}, TFLite's defined range: TFLite's", ipu.mbqm(na, nb, ns, r)[~ovf], tfl[~ovf])
        check(f"mbqm random {r}, overflowing left shift: {'saturated' if r == 'DOUBLE' else 'TFLite'}", ipu.mbqm(na, nb, ns, r)[ovf],
              np.array([c_mbqm(x, m, s, r, sat=True) for x, m, s in zip(A, B, S)])[ovf])
        tflr = np.array([c_requant(*t, r) for t in zip(A, B, S, Z, LO, HI)])
        check(f"requant random {r}, TFLite's defined range: TFLite's", ipu.requant(na, nb, ns, nz, nlo, nhi, r)[~ovf], tflr[~ovf])
        check(f"requant random {r}, overflowing left shift", ipu.requant(na, nb, ns, nz, nlo, nhi, r)[ovf],
              np.array([c_requant(*t, r, sat=True) for t in zip(A, B, S, Z, LO, HI)])[ovf])
    sat_d, tfl_d = ipu.mbqm(na[ovf], nb[ovf], ns[ovf], "DOUBLE"), np.array([c_mbqm(x, m, s, "DOUBLE") for x, m, s in zip(A, B, S)])[ovf]
    check("DOUBLE's saturation differs from TFLite's wrap on most overflowing draws", int(np.sum(sat_d != tfl_d)) > int(ovf.sum()) // 2, True)
    # Against exact arithmetic where TFLite defines the result: SINGLE within 1/2, DOUBLE within 1.
    bad = {"DOUBLE": 0, "SINGLE": 0}
    for x, m, s in zip(A, B, S):
        xs = x * (1 << max(s, 0))
        if m < 0 or xs > MAX or xs < MIN:
            continue
        exact = Fraction(x * m, 1 << 31) * Fraction(2) ** s
        if abs(exact) >= MAX:
            continue
        bad["SINGLE"] += abs(Fraction(c_mbqm(x, m, s, "SINGLE")) - exact) > Fraction(1, 2)
        bad["DOUBLE"] += abs(Fraction(c_mbqm(x, m, s, "DOUBLE")) - exact) > 1
    check("SINGLE within 1/2 of exact", bad["SINGLE"], 0)
    check("DOUBLE within 1 of exact", bad["DOUBLE"], 0)
    # Broadcasting as the goldens use it: a (rows, channels) accumulator against per-channel multipliers and shifts.
    acc = na[:80].reshape(5, 16)
    mult, shift = (np.abs(nb[:16]) & (H - 1)) | H, ns[:16]  # normalized, as QuantizeMultiplier gives
    for r in ipu.ROUNDINGS:
        check(f"requant broadcast {r}", ipu.requant(acc, mult, shift, 3, -128, 127, r),
              [[c_requant(int(acc[i, c]), int(mult[c]), int(shift[c]), 3, -128, 127, r) for c in range(16)] for i in range(5)])
    X = [rng.randint(-32768, 32767) for _ in range(n)]
    C = [rng.randint(-32768, 32767) for _ in range(n)]
    Y = [rng.randint(-32768, 32767) for _ in range(n)]
    check("fx_mac random", ipu.fx_mac(np.array(X), np.array(Y), np.array(C)),
          [max(-32768, min(32767, ((x * y) >> 11) + c)) for x, y, c in zip(X, Y, C)])
    check("int_add random", ipu.int_add(na, nb), [wrap32(a + b) for a, b in zip(A, B)])

    for real, want in QMS:
        check(f"quantize_multiplier_smaller_than_one_exp({real!r})", ipu.quantize_multiplier_smaller_than_one_exp(real), want)
    for real in QMS_BAD:
        try:
            ipu.quantize_multiplier_smaller_than_one_exp(real)
            check(f"quantize_multiplier_smaller_than_one_exp({real!r}) raises", "returned", "ValueError")
        except ValueError:
            check(f"quantize_multiplier_smaller_than_one_exp({real!r}) raises", "ValueError", "ValueError")
    check("add_params(0.5, 0.5, 1.0)", sorted(ipu.add_params(0.5, 0.5, 1.0).items()), sorted(P_EQ.items()))
    check("add_params(0.25, 0.5, 0.75)", sorted(ipu.add_params(0.25, 0.5, 0.75).items()), sorted(P_UN.items()))
    check("add_params(2^-10, 1, 2^-3)", sorted(ipu.add_params(2.0 ** -10, 1.0, 2.0 ** -3).items()), sorted(P_WIDE.items()))
    check("add_params(float32(0.1), 0.25, float32(0.1))", sorted(ipu.add_params(0.1, 0.25, 0.1).items()), sorted(P_F32.items()))
    check("add_params is symmetric", sorted(ipu.add_params(0.5, 0.25, 0.75).items()),
          sorted(dict(P_UN, m1=P_UN["m2"], s1=P_UN["s2"], m2=P_UN["m1"], s2=P_UN["s1"]).items()))
    check("ADD_LEFT_SHIFT", ipu.ADD_LEFT_SHIFT, 20)
    for q1, q2, z1, z2, p, zo, lo, hi, d, sg in ADD:
        for r, w in (("DOUBLE", d), ("SINGLE", sg)):
            check(f"tflite_add({q1}, {q2}, {z1}, {z2}, {p}, {zo}, {lo}, {hi}, {r})",
                  ipu.tflite_add(q1, q2, z1, z2, p["m1"], p["s1"], p["m2"], p["s2"], p["mo"], p["so"], zo, lo, hi, r), w)
    # Every (q1, q2) pair at three constant sets against the transcription, both roundings.
    g1, g2 = (np.arange(1 << 16) >> 8) - 128, (np.arange(1 << 16) & 255) - 128
    sets = [(0, 0, P_EQ, 0, -128, 127), (-7, 33, P_UN, 12, 12, 127), (127, -128, P_WIDE, -100, -128, 6)]
    for z1, z2, p, zo, lo, hi in sets:
        for r in ipu.ROUNDINGS:
            got = ipu.tflite_add(g1, g2, z1, z2, p["m1"], p["s1"], p["m2"], p["s2"], p["mo"], p["so"], zo, lo, hi, r)
            want = [c_add(int(a), int(b), z1, z2, p["m1"], p["s1"], p["m2"], p["s2"], p["mo"], p["so"], zo, lo, hi, r)
                    for a, b in zip(g1, g2)]
            check(f"tflite_add exhaustive {r} zp {z1} {z2} {zo}", got, want)
    # left_shift as a parameter (G0b's negative control uses 19): every pair at P_UN against the transcription, a hand value, the default.
    w_un = [P_UN[k] for k in ("m1", "s1", "m2", "s2", "mo", "so")]
    for r in ipu.ROUNDINGS:
        got = ipu.tflite_add(g1, g2, -7, 33, *w_un, 12, -128, 127, r, left_shift=19)
        want = [c_add(int(a), int(b), -7, 33, *w_un, 12, -128, 127, r, ls=19) for a, b in zip(g1, g2)]
        check(f"tflite_add exhaustive {r} left_shift 19", got, want)
        check(f"tflite_add left_shift 19 {r}", ipu.tflite_add(10, 6, 0, 0, *[P_EQ[k] for k in ("m1", "s1", "m2", "s2", "mo", "so")],
                                                              0, -128, 127, r, left_shift=19), 4)  # (10 + 6) / 4
        check(f"tflite_add left_shift 20 is the default {r}", ipu.tflite_add(g1, g2, -7, 33, *w_un, 12, -128, 127, r, left_shift=20),
              ipu.tflite_add(g1, g2, -7, 33, *w_un, 12, -128, 127, r))
    # Random constants (any int32 multiplier, every shift in [-31, 0]) against the transcription.
    Q = [rng.randint(-128, 127) for _ in range(n)]
    Q2 = [rng.randint(-128, 127) for _ in range(n)]
    SH = [[rng.randint(-31, 0) for _ in range(n)] for _ in range(3)]
    M3 = [[r32() for _ in range(n)] for _ in range(3)]
    Z2, ZO = ([rng.randint(-128, 127) for _ in range(n)] for _ in range(2))  # zp2 and zp_o drawn on their own
    C1, C2 = ([rng.randint(-128, 127) for _ in range(n)] for _ in range(2))
    CLO, CHI = [min(a, b) for a, b in zip(C1, C2)], [max(a, b) for a, b in zip(C1, C2)]  # a clamp with lo <= hi
    for r in ipu.ROUNDINGS:
        got = ipu.tflite_add(np.array(Q), np.array(Q2), nz, np.array(Z2), np.array(M3[0]), np.array(SH[0]), np.array(M3[1]),
                             np.array(SH[1]), np.array(M3[2]), np.array(SH[2]), np.array(ZO), np.array(CLO), np.array(CHI), r)
        want = [c_add(*t, r) for t in zip(Q, Q2, Z, Z2, M3[0], SH[0], M3[1], SH[1], M3[2], SH[2], ZO, CLO, CHI)]
        check(f"tflite_add random {r}", got, want)
    for k in range(3):  # a positive shift is outside MultiplyByQuantizedMultiplierSmallerThanOneExp
        sh = [0, 0, 0]
        sh[k] = 1
        try:
            ipu.tflite_add(0, 0, 0, 0, H, sh[0], H, sh[1], H, sh[2], 0, -128, 127, "DOUBLE")
            check(f"tflite_add shift {sh} raises", "returned", "ValueError")
        except ValueError:
            check(f"tflite_add shift {sh} raises", "ValueError", "ValueError")
    # tfliteAdd's stage-1 forms: DOUBLE SRDHM(d << 20, m) = (d m + 2^10) >> 11; SINGLE MBQM(d << 20, m, s) = (d m + 2^(10 - s)) >> (11 - s).
    ms = [0, 1, H - 1, H, H + 1, MAX - 1, MAX, MIN, MIN + 1, -1, -H] + [r32() for _ in range(40)]
    d = np.arange(-255, 256)
    bad = 0
    for m in ms:
        bad += int(np.sum(ipu.srdhm(d << 20, m) != (d * m + 1024) >> 11))
        for s in range(-31, 1):
            bad += int(np.sum(ipu.mbqm(d << 20, m, s, "SINGLE") != (d * m + (1 << (10 - s))) >> (11 - s)))
    check("tfliteAdd stage-1 forms", bad, 0)
    # The value bounds the RTL's widths rest on: |scaled| < 2^28, so |sum| < 2^29.
    worst = max(abs(int(ipu.mbqm(dd << 20, m, s, r))) for dd in (255, -255) for m in (MIN, MAX) for s in (0, -1) for r in ipu.ROUNDINGS)
    check("|scaled| < 2^28", worst < (1 << 28), True)
    # The ADD is symmetric: swapping the inputs with their constants gives the same codes.
    for r in ipu.ROUNDINGS:
        a = ipu.tflite_add(g1, g2, -7, 33, 1 << 30, -1, 1610612736, 0, 1431655765, -19, 12, -128, 127, r)
        b = ipu.tflite_add(g2, g1, 33, -7, 1610612736, 0, 1 << 30, -1, 1431655765, -19, 12, -128, 127, r)
        check(f"tflite_add symmetric {r}", a, b)

    affine()

    print(f"test_ipu: {checks} checks, {fails} failures")
    print(f"RESULT: {'PASSED' if fails == 0 else 'FAILED'}")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
