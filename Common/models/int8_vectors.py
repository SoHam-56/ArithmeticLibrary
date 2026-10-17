"""Shared affine int8 test vectors: requantize saturation corners (carried from requant_sat) and ADD corner scale sets, in real scales."""
import itertools

import numpy as np

INT32_MIN, INT32_MAX = -(1 << 31), (1 << 31) - 1
ZPS = (-128, -1, 1, 127)  # requant_sat's four zero points


def clamps(zp):
    """requant_sat's clamps, in contract (lo <= hi): the int8 range, a ReLU at zp, a ReLU6-like window around zp."""
    return [(-128, 127), (zp, 127), (max(-128, zp - 3), min(127, zp + 60))]


def saturation_corners():
    """(acc, s, zp, lo, hi) rows: lane C's example, acc s aimed just inside and outside +-384, +-512 and far beyond at S near 1, 2^8 and the
    saturating code, and acc at +-2^31 with S near 1, 2^8, the flush edge 2^-32 and below, under the four zero points and three clamps."""
    rows = [(-(1 << 20), INT32_MAX * 2.0 ** -20, -128, -128, 127)]  # lane C's example: S near 2^11, the true value clamps to -128
    for s0 in (1.0, 1.0 - 2.0 ** -20, 2.0 ** 8 - 2.0 ** -10, 2.0 ** 8, 3.0e5):
        for tgt, sg in itertools.product((383.4, 384.6, 511.4, 512.6, 1.0e4, 1.0e9), (1, -1)):
            acc = max(INT32_MIN, min(INT32_MAX, round(sg * tgt / s0)))
            rows += [(acc, s0, z, lo, hi) for z in ZPS for lo, hi in clamps(z)]
    for acc, s0, z in itertools.product((INT32_MIN, INT32_MIN + 1, INT32_MAX - 1, INT32_MAX), (1.0, 2.0 ** 8, 2.0 ** -31, 2.0 ** -32, 2.0 ** -33, 1e-12), ZPS):
        rows += [(acc, s0, z, lo, hi) for lo, hi in clamps(z)]
    return rows


ADD_ZP_SETS = [(0, 0, 0, -128, 127), (-128, 127, -3, -128, 127), (37, -90, 127, -128, 127), (5, -7, -20, -20, 127)]  # (z1, z2, zo, lo, hi)


def add_corner_scales():
    """(r1, r2) ratio pairs s_i / s_out for the exhaustive ADD sets: identity and halves, powers of two at both ends of the 32-bit domain,
    the flush below 2^-10, a ratio rounding to the top mantissa, and near-cancellation pairs at the top of the domain."""
    top = 2.0 ** 23 * (1 - 2.0 ** -12)
    return [(1.0, 1.0), (0.5, 0.25), (1.0, 2.0 ** -20), (2.0 ** 22, 1.0), (2.0 ** -10, 2.0 ** -10), (2.0 ** -11, 2.0 ** -12),
            (1.0 - 2.0 ** -33, 0.75), (0.0123, 0.0456), (top, top), (top, top * (1 - 2.0 ** -24)), (7.62e6, 7.62e6 * (1 + 2.0 ** -20)),
            (3.0, 2.0 ** -9)]


def add_corner_sets():
    """Every ratio pair of add_corner_scales under every zero-point set of ADD_ZP_SETS, as (r1, r2, z1, z2, zo, lo, hi)."""
    return [(r1, r2) + z for (r1, r2), z in itertools.product(add_corner_scales(), ADD_ZP_SETS)]


def log_uniform(rng, lo, hi, n):
    """n reals spread evenly in log between lo and hi."""
    return np.exp(rng.uniform(np.log(lo), np.log(hi), n))
