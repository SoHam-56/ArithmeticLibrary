"""Bit-exact numpy models of AriL's integer units (int64 arrays) and the affine int8 host encoders, framework-neutral."""
import math

import numpy as np

INT32_MIN, INT32_MAX = -(1 << 31), (1 << 31) - 1


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


# ── Affine int8, framework-neutral: the host encoders and bit-exact models of int8Requantizer and int8QuantizedAdder ──

REQ_MANTISSA_WIDTH = 24  # int8Requantizer's mult_i
REQ_MAX_SHIFT = REQ_MANTISSA_WIDTH + 31
ADD_MANTISSA_WIDTH = 32  # int8QuantizedAdder's m1_i and m2_i
ADD_MAX_SHIFT = ADD_MANTISSA_WIDTH + 9
ADD_MAX_RATIO_LOG2 = ADD_MANTISSA_WIDTH - 9  # encode_add refuses max(s1, s2) / s_out >= 2^23: past it no 32-bit code holds one step
ACTIVATIONS = ("none", "relu", "relu6", "relu_n1_to_1")


def _positive(name, v) -> float:
    """v as a float64 real scale, or ValueError when it is not finite and positive."""
    v = float(v)
    if not (math.isfinite(v) and v > 0.0):
        raise ValueError(f"{name} must be a finite real > 0, got {v!r}")
    return v


def encode_scale(s: float, width: int = REQ_MANTISSA_WIDTH):
    """(m, e) with m 2^-e within s 2^-width of s: m normalized to [2^(width-1), 2^width); s >= 2^8 saturates to (2^width - 1, width - 8)
    (any nonzero acc then clamps), s < 2^-32 flushes to (0, width + 31) (|acc s| < 1/2)."""
    s = _positive("scale", s)
    sat, flush = ((1 << width) - 1, width - 8), (0, width + 31)
    if s >= 2.0 ** 8:
        return sat
    if s < 2.0 ** -32:
        return flush
    e = width - 1 - (math.frexp(s)[1] - 1)
    m = round(math.ldexp(s, e))  # exact scaling by a power of two, then nearest with ties to even
    if m == 1 << width:
        m, e = m >> 1, e - 1
    return sat if math.ldexp(m, -e) >= 2.0 ** 8 else (m, e)


def encode_add(r1: float, r2: float, width: int = ADD_MANTISSA_WIDTH):
    """(m1, m2, e): r_i = s_i / s_out as m_i 2^-e on one shared shift, normalized to the larger ratio; both below 2^-10 flush to
    (0, 0, width + 9). ValueError when max(r1, r2) reaches 2^(width - 9) or rounds up to it: int8QuantizedAdder's domain."""
    r1, r2 = _positive("ADD ratio s1 / s_out", r1), _positive("ADD ratio s2 / s_out", r2)
    big = max(r1, r2)
    top = width - 9
    if big >= 2.0 ** top:
        raise ValueError(f"ADD scale ratio max(s1, s2) / s_out = {big!r} >= 2^{top} is outside int8QuantizedAdder's domain")
    if big < 2.0 ** -10:
        return 0, 0, width + 9
    e = width - 1 - (math.frexp(big)[1] - 1)
    if round(math.ldexp(big, e)) == 1 << width:
        e -= 1
    if e < 9:
        raise ValueError(f"ADD scale ratio max(s1, s2) / s_out = {big!r} rounds up to 2^{top}, outside int8QuantizedAdder's domain")
    return round(math.ldexp(r1, e)), round(math.ldexp(r2, e)), e


def activation_clamp(kind: str, s_out: float, zp: int):
    """(lo, hi) of a fused activation on an int8 output of scale s_out and zero point zp, in float64 with ties rounded up."""
    s_out, zp = _positive("output scale", s_out), int(zp)
    code = lambda v: zp + math.floor(v / s_out + 0.5)
    lims = {"none": (-128, 127), "relu": (zp, 127), "relu6": (zp, code(6.0)), "relu_n1_to_1": (code(-1.0), code(1.0))}
    if kind not in lims:
        raise ValueError(f"activation {kind!r}: not one of {', '.join(ACTIVATIONS)}")
    lo, hi = lims[kind]
    return max(-128, min(127, lo)), max(-128, min(127, hi))


def _round_shift(x, e):
    """floor((x + 2^(e - 1)) / 2^e) on int64 arrays, 0 at e = 0 adds nothing: round half up."""
    e = np.asarray(e, dtype=np.int64)
    half = np.where(e > 0, np.left_shift(np.int64(1), np.maximum(e - 1, 0)), 0)
    return np.right_shift(x + half, e)


def _clamp8(r, zp, lo, hi):
    """sat10(r) + zp, then max lo and min hi: the units' last two stages."""
    y = np.clip(r, -512, 511) + sx(zp, 8)
    return np.minimum(np.maximum(y, sx(lo, 8)), sx(hi, 8))


def requantize(acc, m, e, zp, lo, hi):
    """int8Requantizer, bit-exact: clamp(sat10(round_half_up(acc m 2^-e)) + zp, lo, hi); m < 2^24, e <= 55, or ValueError."""
    m, e = np.asarray(m, dtype=np.int64), np.asarray(e, dtype=np.int64)
    if np.any((m < 0) | (m >= 1 << REQ_MANTISSA_WIDTH)) or np.any((e < 0) | (e > REQ_MAX_SHIFT)):
        raise ValueError(f"requantize: m must be in [0, 2^{REQ_MANTISSA_WIDTH}) and e in [0, {REQ_MAX_SHIFT}]")
    return _clamp8(_round_shift(sx(acc, 32) * m, e), zp, lo, hi)


def qadd(q1, q2, z1, z2, m1, m2, e, zo, lo, hi):
    """int8QuantizedAdder, bit-exact: clamp(sat10(round_half_up(((q1 - z1) m1 + (q2 - z2) m2) 2^-e)) + zo, lo, hi); m_i < 2^32,
    e <= 41, or ValueError."""
    m1, m2, e = (np.asarray(v, dtype=np.int64) for v in (m1, m2, e))
    if np.any((m1 < 0) | (m1 >= 1 << ADD_MANTISSA_WIDTH) | (m2 < 0) | (m2 >= 1 << ADD_MANTISSA_WIDTH)) or np.any((e < 0) | (e > ADD_MAX_SHIFT)):
        raise ValueError(f"qadd: m1 and m2 must be in [0, 2^{ADD_MANTISSA_WIDTH}) and e in [0, {ADD_MAX_SHIFT}]")
    s = (sx(q1, 8) - sx(z1, 8)) * m1 + (sx(q2, 8) - sx(z2, 8)) * m2
    return _clamp8(_round_shift(s, e), zo, lo, hi)
