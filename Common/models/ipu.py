"""Bit-exact numpy models of AriL's integer units and TFLite's int8 requantize; int64 arrays, int32 intermediates wrap as TFLite's C does."""
import math
import os

import numpy as np

INT32_MIN, INT32_MAX = -(1 << 31), (1 << 31) - 1
ROUNDINGS = ("SINGLE", "DOUBLE")

_ROUNDING_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "testbenches", "tflite_int8", "rounding.txt")
REQ_ROUNDING = open(_ROUNDING_FILE).read().strip() if os.path.exists(_ROUNDING_FILE) else None  # G0's variant, from the SIENNA tree around this checkout


def sx(x, w):
    """The low w bits of x as a signed w-bit value (1 <= w <= 62)."""
    x = np.asarray(x, dtype=np.int64)
    h = np.int64(1 << (w - 1))
    return ((x & np.int64((1 << w) - 1)) ^ h) - h


def bits(x, w):
    """x as an unsigned w-bit pattern, for vector files and dumps."""
    return np.asarray(x, dtype=np.int64) & np.int64((1 << w) - 1)


def int_mul(a, b, w=8):
    """intMultiplier: the full signed 2w-bit product."""
    return sx(a, w) * sx(b, w)


def int_add(a, b, w=32):
    """intAdder: a + b mod 2^w, signed."""
    return sx(sx(a, w) + sx(b, w), w)


def fx_mac(a, x, c, w=16, frac=11):
    """fxMac, one Horner step: the 2w-bit product shifted right by frac with floor (D-1), plus c, saturated to w bits."""
    p = (sx(a, w) * sx(x, w)) >> frac
    return np.clip(p + sx(c, w), -(1 << (w - 1)), (1 << (w - 1)) - 1)


def srdhm(a, b):
    """gemmlowp SaturatingRoundingDoublingHighMul: (a*b + nudge) / 2^31 with C's truncating divide; INT32_MIN * INT32_MIN saturates."""
    a, b = sx(a, 32), sx(b, 32)
    ab = a * b
    n = ab + np.where(ab >= 0, np.int64(1 << 30), np.int64(1 - (1 << 30)))
    q = np.where(n >= 0, n >> 31, -((-n) >> 31))
    return np.where((a == INT32_MIN) & (b == INT32_MIN), np.int64(INT32_MAX), q)


def rdbpot(x, exp):
    """gemmlowp RoundingDivideByPOT: x / 2^exp to nearest, ties away from zero; exp in [0, 31]."""
    x = sx(x, 32)
    e = np.asarray(exp, dtype=np.int64)
    assert np.all((e >= 0) & (e <= 31)), "RoundingDivideByPOT needs 0 <= exp <= 31"
    mask = (np.int64(1) << e) - 1
    threshold = (mask >> 1) + (x < 0).astype(np.int64)
    return (x >> e) + ((x & mask) > threshold).astype(np.int64)


def mbqm(acc, mult, shift, rounding):
    """TFLite MultiplyByQuantizedMultiplier in either rounding; shift in [-31, 30], positive shifts left."""
    acc, mult = sx(acc, 32), sx(mult, 32)
    shift = np.asarray(shift, dtype=np.int64)
    assert np.all((shift >= -31) & (shift <= 30)), "shift outside [-31, 30]"
    if rounding == "DOUBLE":
        left, right = np.maximum(shift, 0), np.maximum(-shift, 0)
        return rdbpot(srdhm(sx(acc << left, 32), mult), right)
    if rounding == "SINGLE":
        total = 31 - shift
        return sx((acc * mult + (np.int64(1) << (total - 1))) >> total, 32)
    raise ValueError(f"rounding must be SINGLE or DOUBLE, not {rounding!r}")


def requant(acc, mult, shift, zp, amin, amax, rounding):
    """tfliteRequant, TFLite's conv / FC epilogue: y = mbqm + zp in int32, then max(y, amin), then min(y, amax)."""
    y = sx(mbqm(acc, mult, shift, rounding) + sx(zp, 8), 32)
    return np.minimum(np.maximum(y, sx(amin, 8)), sx(amax, 8))


def round_half_away(v: float) -> int:
    """TfLiteRound (std::round) on a double: nearest, ties away from zero, exact (a - floor(a) is exact, unlike floor(a + 0.5))."""
    a = abs(v)
    f = math.floor(a)
    r = f + (1 if a - f >= 0.5 else 0)
    return -r if v < 0 else r


def quantize_multiplier(real: float, rounding: str = "DOUBLE"):
    """TFLite QuantizeMultiplier: real = mult * 2^(shift - 31), mult in [2^30, 2^31); below 2^-32 flushes to (0, 0)."""
    if real == 0.0:
        return 0, 0
    q, shift = math.frexp(real)
    q_fixed = round_half_away(q * (1 << 31))
    assert q_fixed <= (1 << 31)
    if q_fixed == (1 << 31):
        q_fixed //= 2
        shift += 1
    if shift < -31:
        return 0, 0
    if rounding == "SINGLE" and shift > 30:  # TFLITE_SINGLE_ROUNDING saturates the shift
        return (1 << 31) - 1, 30
    return q_fixed, shift
