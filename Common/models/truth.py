#!/usr/bin/env python3
"""True-function gate: float64 numpy references for the activations, and the pass rule every activation run gates on.

The reference is the function of the input, with a subnormal input read as zero (the formats flush to zero, Soham 2026-10-11);
a bit-exact model of the hardware is never the gate.
Floats pass when |out - t| <= bound |t|, or when |out| and |t| are both <= F_FLOOR; a NaN or Inf output where t is finite fails.
Overflow rule: where t is above the format's max, the output passes only as max or Inf of t's sign (an exact value above max
rounds to either).
int8 passes when |q_out - q_true| <= I8_FLOOR, q_true = round(t / s_out) + z_out clamped, or when the dequantized output is within
bound of t clamped to the output's range.
"""
import argparse
import sys
from collections import namedtuple

import numpy as np

TARGET = 0.01  # the accuracy the lanes must reach (the restructure spec's REL)
BOUND = 0.10  # the activation waiver in force (Soham, 2026-10-11); every run also reports TARGET
REL = TARGET  # the restructure spec's name for the target
F_FLOOR = 2.0 ** -126  # floats: an output and a true value both at or below it pass
I8_FLOOR = 1  # int8: an output within one LSB of the rounded true value passes
SELU_LAMBDA = 1.0507009873554804934193349852946  # Klambauer et al.
SELU_ALPHA = 1.6732632423543772848170429916717
FUNCS = ("selu", "sigmoid", "tanh", "relu", "linear")
CODES = {"selu": 1, "sigmoid": 2, "tanh": 3, "relu": 4, "linear": 5}  # GPNAE's control words
FLOATS = {"fp32": 23, "bf16": 7}  # mantissa bits; both have 8 exponent bits
FORMATS = tuple(FLOATS) + ("int8",)
FIRST = 8  # misses listed in a result

Result = namedtuple("Result", "ok fmt func n worst at idx over over_target worst_lsb n_floor n_ovf first")


def sigmoid(x):
    """1 / (1 + e^-x), from e^-|x| so neither side overflows."""
    x = np.asarray(x, dtype=np.float64)
    e = np.exp(-np.abs(x))
    return np.where(x >= 0, 1.0 / (1.0 + e), e / (1.0 + e))


def selu(x):
    x = np.asarray(x, dtype=np.float64)
    with np.errstate(over="ignore"):
        return np.where(x > 0, SELU_LAMBDA * x, SELU_LAMBDA * SELU_ALPHA * np.expm1(np.minimum(x, 0.0)))


def relu(x):
    return np.maximum(np.asarray(x, dtype=np.float64), 0.0)


def linear(x):
    return np.asarray(x, dtype=np.float64).copy()


def tanh(x):
    return np.tanh(np.asarray(x, dtype=np.float64))


REFS = {"selu": selu, "sigmoid": sigmoid, "tanh": tanh, "relu": relu, "linear": linear}


def ref(func, x):
    """The float64 true value of func at x (real numbers)."""
    return REFS[func](x)


def fmax(fmt):
    """The largest finite value of a float format."""
    return (2.0 - 2.0 ** -FLOATS[fmt]) * 2.0 ** 127


def decode(fmt, w):
    """Bit patterns of fp32 or bf16 as float64, exactly (subnormals kept)."""
    w = np.asarray(w, dtype=np.int64)
    u = (w & 0xFFFFFFFF) if fmt == "fp32" else ((w & 0xFFFF) << 16)
    with np.errstate(invalid="ignore"):  # a signalling NaN pattern widens quietly
        return u.astype(np.uint32).view(np.float32).astype(np.float64)


def encode(fmt, v):
    """float64 values as the format's bit patterns, rounded to nearest even (test helper)."""
    with np.errstate(over="ignore"):
        u = np.asarray(v, dtype=np.float64).astype(np.float32).view(np.uint32).astype(np.int64)
    if fmt == "fp32":
        return u
    nan = (u & 0x7FFFFFFF) > 0x7F800000
    return np.where(nan, 0x7FC0, (u + 0x7FFF + ((u >> 16) & 1)) >> 16) & 0xFFFF


def int8_codes(q):
    """Codes as signed -128..127, from signed values or 8-bit words."""
    return ((np.asarray(q, dtype=np.int64) + 128) & 0xFF) - 128


def ftz(x):
    """Subnormal values read as zero of the same sign, as the formats' units read them."""
    x = np.asarray(x, dtype=np.float64)
    return np.where(np.abs(x) < F_FLOOR, np.copysign(0.0, x), x)


def _float_err(fmt, t, o):
    """Per-element error: 0 where a floor or the overflow rule passes, inf where a rule fails outright, else |o - t| / |t|."""
    big = np.abs(t) > fmax(fmt)  # the true value overflows the format
    top = (np.abs(o) == fmax(fmt)) | np.isinf(o)
    ovf_ok = big & top & (np.sign(o) == np.sign(t))
    floor = (np.abs(o) <= F_FLOOR) & (np.abs(t) <= F_FLOOR)
    with np.errstate(divide="ignore", invalid="ignore"):
        rel = np.where(t != 0, np.abs(o - t) / np.abs(t), np.inf)
    rel = np.where(np.isfinite(o), rel, np.inf)  # NaN or Inf where the true value is finite
    e = np.where(floor, 0.0, rel)
    return np.where(big, np.where(ovf_ok, 0.0, np.inf), e), floor & ~big, big


def _int8_err(func, q, out, s_in, z_in, s_out, z_out):
    """Per-element error and LSB distance: 0 within I8_FLOOR, else the dequantized output against t clamped to the output's range."""
    with np.errstate(divide="ignore", invalid="ignore", over="ignore"):  # s_out = inf: a zero multiplier, q_true is the zero point
        return _int8_err_body(func, q, out, s_in, z_in, s_out, z_out)


def _int8_err_body(func, q, out, s_in, z_in, s_out, z_out):
    t = ref(func, s_in * (q - z_in))
    lo, hi = s_out * (-128 - z_out), s_out * (127 - z_out)
    qt = np.clip(np.floor(t / s_out + 0.5) + z_out, -128, 127)
    lsb = np.abs(out - qt)
    tc = np.clip(t, lo, hi)
    deq = s_out * (out - z_out)
    rel = np.where(tc != 0, np.abs(deq - tc) / np.abs(tc), np.where(deq == 0, 0.0, np.inf))
    rel = np.where(np.isnan(rel), np.inf, rel)
    floor = lsb <= I8_FLOOR
    return np.where(floor, 0.0, rel), lsb, floor, t, qt


def gate(fmt, func, x_in, out, bound=None, target=None, quant=None) -> Result:
    """Judge outputs against the true function; fp32/bf16 take bit patterns, int8 takes codes and quant = (s_in, z_in, s_out, z_out)."""
    bound = BOUND if bound is None else bound
    target = TARGET if target is None else target
    if func not in REFS:
        raise ValueError(f"{func}: not one of {', '.join(FUNCS)}")
    if fmt in FLOATS:
        x, o = decode(fmt, x_in), decode(fmt, out)
        if np.isnan(x).any():
            raise ValueError("NaN inputs are not gated")
        t = ref(func, ftz(x))  # a subnormal input reads as zero
        e, floor, big = _float_err(fmt, t, o)
        lsb = np.zeros(x.shape, dtype=np.int64)
        show = lambda i: (int(i), float(x[i]), float(o[i]), float(t[i]))
    elif fmt == "int8":
        if quant is None:
            raise ValueError("int8 needs quant = (s_in, z_in, s_out, z_out)")
        q, o = int8_codes(x_in), int8_codes(out)
        s_in, z_in, s_out, z_out = (np.broadcast_to(np.asarray(v, dtype=np.float64), q.shape) for v in quant)
        e, lsb, floor, t, qt = _int8_err(func, q.astype(np.float64), o.astype(np.float64), s_in, z_in, s_out, z_out)
        big = np.zeros(q.shape, dtype=bool)
        x = s_in * (q - z_in)
        show = lambda i: (int(i), int(q[i]), int(o[i]), int(qt[i]))
    else:
        raise ValueError(f"{fmt}: not one of {', '.join(FORMATS)}")
    if x.size == 0:
        raise ValueError("no inputs")
    i = int(np.argmax(e))
    miss = np.flatnonzero(e > bound)
    over_t = int((e > target).sum())
    return Result(miss.size == 0, fmt, func, int(x.size), float(e[i]), float(x[i]), i, int(miss.size), over_t,
                  int(lsb.max()), int(floor.sum()), int(big.sum()), [show(k) for k in miss[:FIRST]])


def worst_text(worst) -> str:
    """A worst error as text; an unbounded one is a NaN, Inf or overflow miss, or a nonzero output where the true value is 0."""
    return f"{100 * worst:.3f}%" if np.isfinite(worst) else "unbounded (NaN, Inf, overflow, or nonzero where the true value is 0)"


def line(r: Result, bound=None, target=None) -> str:
    """One report line for a result."""
    bound = BOUND if bound is None else bound
    target = TARGET if target is None else target
    lsb = f"  worst {r.worst_lsb} LSB" if r.fmt == "int8" else ""
    w = worst_text(r.worst)
    return (f"TRUTH {r.fmt} {r.func}: {'PASS' if r.ok else 'FAIL'}  n {r.n}  worst {w} at x = {r.at:.6g}{lsb}  "
            f"over {100 * bound:g}%: {r.over}  over {100 * target:g}%: {r.over_target}  (floor {r.n_floor}, overflow {r.n_ovf})")


# ── per-stage gates (mesh and pipeline): each stage against the true function of its own actual inputs ──

MM_BOUND = 0.01  # matmul and accumulate: |err| <= max(1% of sum|a b|, 2^-126) per element (Soham, 2026-10-11)
STAGES = ("matmul", "narrow", "requant", "multiplier", "activation", "maxpool", "dropout")


def values(fmt, w):
    """Words as float64 values: fp32 or bf16 bit patterns (a subnormal reads as zero), int8 codes, or int32 words ('int32')."""
    if fmt in FLOATS:
        return ftz(decode(fmt, w))
    if fmt == "int8":
        return int8_codes(w).astype(np.float64)
    if fmt == "int32":
        return ((((np.asarray(w, dtype=np.int64) & 0xFFFFFFFF) + 2**31) & 0xFFFFFFFF) - 2**31).astype(np.float64)
    raise ValueError(f"{fmt}: not one of {', '.join(FORMATS)}, int32")


def acc_fmt(fmt):
    """The accumulator's words: fp32 in every float format, int32 in int8."""
    return "int32" if fmt == "int8" else "fp32"


def matmul_ref(passes, bias=None):
    """The float64 sum over passes of A @ B plus the bias row, and sum|a b| over the products (the bias is not a product); values in."""
    t = s = 0.0
    for A, B in passes:
        A, B = np.asarray(A, dtype=np.float64), np.asarray(B, dtype=np.float64)
        t, s = t + A @ B, s + np.abs(A) @ np.abs(B)
    if bias is not None:
        b = np.asarray(bias, dtype=np.float64)[None, :]
        t = t + b
    return np.asarray(t, dtype=np.float64), np.asarray(s, dtype=np.float64)


def _exact_result(fmt, func, ok_el, err, at, first):
    """A Result for an exact stage: worst is the largest |out - want| (0 when every element matches)."""
    miss = np.flatnonzero(~ok_el)
    e = np.where(ok_el, 0.0, err)
    i = int(np.argmax(e)) if e.size else 0
    return Result(miss.size == 0, fmt, func, int(ok_el.size), float(e[i]) if e.size else 0.0, float(at[i]) if e.size else 0.0, i,
                  int(miss.size), int(miss.size), 0, 0, 0, [first(k) for k in miss[:FIRST]])


def gate_matmul(fmt, passes, out, bias=None, bound=None) -> Result:
    """Mesh sums against the true sum of the operands it received, per element.

    fp32 and bf16 (fp32 sums): |out - t| <= max(bound sum|a b|, 2^-126); a true sum above fp32's max passes only as max or Inf of
    its sign (gate()'s overflow rule).
    int8 (int32 sums): exact. Integer arithmetic has one right answer, the int32 accumulator's contract as TFLite's int32
    accumulation (Soham, 2026-10-11): the exact sum where it fits int32, its two's-complement wrap (sum mod 2^32 as signed int32)
    where it does not. The error is the distance modulo 2^32; n_ovf counts the sums that wrap.

    fmt is the operands' format (passes of (A, B) words); out and bias are accumulator words (fp32, or int32 in int8).
    worst is |out - t| / sum|a b| (unbounded where sum|a b| is 0 and the floor fails), worst_lsb the largest |out - t| in int8."""
    bound = MM_BOUND if bound is None else bound
    vals = [(values(fmt, A), values(fmt, B)) for A, B in passes]
    if not vals:
        raise ValueError("no passes")
    b = None if bias is None else values(acc_fmt(fmt), bias)
    t, s = matmul_ref(vals, b)
    o = values(acc_fmt(fmt), out).reshape(t.shape)
    lim = np.maximum(bound * s, F_FLOOR)
    big = np.zeros(t.shape, dtype=bool) if fmt == "int8" else np.abs(t) > fmax("fp32")  # the true sum overflows the fp32 accumulator
    ovf_ok = big & ((np.abs(o) == fmax("fp32")) | np.isinf(o)) & (np.sign(o) == np.sign(t))  # as gate(): only max or Inf of t's sign
    wraps = ((t > 2**31 - 1) | (t < -2**31)) if fmt == "int8" else np.zeros(t.shape, dtype=bool)  # int32 sums that wrap
    with np.errstate(invalid="ignore", divide="ignore"):
        err = np.abs(np.mod(o - t + 2**31, 2**32) - 2**31) if fmt == "int8" else np.abs(o - t)  # int32: the distance modulo 2^32
        ok_el = np.where(big, ovf_ok, (err == 0) if fmt == "int8" else (err <= lim))  # NaN or Inf outputs compare False
        e = np.where(s > 0, err / s, np.where(err <= F_FLOOR, 0.0, np.inf))
    e = np.where(big, np.where(ovf_ok, 0.0, np.inf), np.where(np.isfinite(o), e, np.inf)).ravel()
    miss = np.flatnonzero(~ok_el.ravel())
    i = int(np.argmax(e))
    tl, ol, sl = t.ravel(), o.ravel(), s.ravel()
    lsb = int(np.max(np.where(np.isfinite(err), err, 0.0))) if fmt == "int8" else 0
    return Result(miss.size == 0, fmt, "matmul", int(t.size), float(e[i]), float(tl[i]), i, int(miss.size), int(miss.size), lsb,
                  int((bound * s < F_FLOOR).sum()), int((big | wraps).sum()), [(int(k), float(ol[k]), float(tl[k]), float(sl[k])) for k in miss[:FIRST]])


def narrow_ref(fmt, pre):
    """fp32 words rounded to nearest even in fmt: a subnormal reads as zero, NaN stays NaN, past max rounds to Inf."""
    return encode(fmt, ftz(decode("fp32", pre)))


def _order(fmt, w):
    """Words as integers in value order (sign-magnitude to two's complement), for ULP distances."""
    top = 31 if fmt == "fp32" else 15
    w = np.asarray(w, dtype=np.int64) & ((1 << (top + 1)) - 1)
    mag = w & ((1 << top) - 1)
    return np.where((w >> top) & 1, -mag, mag)


def gate_narrow(fmt, pre, post) -> Result:
    """Narrowing is exact: each output equals the round-to-nearest-even fmt word of its fp32 input (as values; NaN matches NaN).

    worst and worst_lsb are the largest distance in ULPs of fmt."""
    pre, post = np.asarray(pre, dtype=np.int64).ravel(), np.asarray(post, dtype=np.int64).ravel()
    want = narrow_ref(fmt, pre)
    vw, vp = decode(fmt, want), decode(fmt, post)
    ok_el = (vw == vp) | (np.isnan(vw) & np.isnan(vp))
    ulp = np.abs(_order(fmt, post) - _order(fmt, want)).astype(np.float64)
    r = _exact_result(fmt, "narrow", ok_el, ulp, decode("fp32", pre), lambda k: (int(k), int(pre[k]), int(post[k]), int(want[k])))
    return r._replace(worst_lsb=int(r.worst))


def requant_ref(acc, mult, shift, zp, amin, amax):
    """(q_true, real): real = acc mult 2^(shift - 31) + zp clamped to [amin, amax], q_true its round to nearest (half up), exactly."""
    acc = (((np.asarray(acc, dtype=np.int64) & 0xFFFFFFFF) + 2**31) & 0xFFFFFFFF) - 2**31
    acc, mult, shift = np.broadcast_arrays(acc, np.asarray(mult, dtype=np.int64), np.asarray(shift, dtype=np.int64))
    d = 31 - shift
    if np.any((d < 1) | (d > 62)) or np.any((mult < 0) | (mult >= 2**31)):
        raise ValueError("requant_ref: shift must be in [-31, 30] and mult in [0, 2^31)")
    prod = acc * mult  # below 2^62 in magnitude, so int64 holds it exactly
    q = np.right_shift(prod + np.left_shift(np.int64(1), d - 1), d)  # floor((prod + 2^(d-1)) / 2^d): round half up
    zp, amin, amax = (np.asarray(v, dtype=np.int64) for v in (zp, amin, amax))
    real = np.clip(prod / np.ldexp(1.0, d) + zp, amin, amax)
    return np.clip(q + zp, amin, amax), real


def gate_requant(acc, mult, shift, zp, amin, amax, q) -> Result:
    """Requantize outputs (int8 codes) within I8_FLOOR LSB of round(real); worst is the largest |q - real| in LSBs."""
    qt, real = requant_ref(acc, mult, shift, zp, amin, amax)
    q = int8_codes(q).reshape(qt.shape)
    lsb, dev = np.abs(q - qt).ravel(), np.abs(q - real).ravel()
    miss = np.flatnonzero(lsb > I8_FLOOR)
    i = int(np.argmax(dev))
    a = np.broadcast_to(np.asarray(acc, dtype=np.int64), qt.shape).ravel()
    return Result(miss.size == 0, "int8", "requant", int(qt.size), float(dev[i]), float(real.ravel()[i]), i, int(miss.size),
                  int(miss.size), int(lsb.max()), 0, 0, [(int(k), int(a[k]), int(q.ravel()[k]), int(qt.ravel()[k])) for k in miss[:FIRST]])


def gate_multiplier(mult, shift, real) -> Result:
    """The host's requantize multipliers against the real scale ratios they encode (s_a s_w / s_out): mult 2^(shift - 31) must be
    within half the multiplier's own LSB, 2^(shift - 32), of real, as TFLite's QuantizeMultiplier rounds; mult in [2^30, 2^31).

    worst is the largest |mult 2^(shift - 31) - real| in the multiplier's LSBs (pass: <= 0.5)."""
    mult, shift, real = np.broadcast_arrays(np.asarray(mult, dtype=np.int64), np.asarray(shift, dtype=np.int64),
                                            np.asarray(real, dtype=np.float64))
    lsb = np.ldexp(1.0, shift - 31)
    dev = np.abs(mult * lsb - real) / lsb  # exact enough: mult < 2^31 and the products are float64
    ok_el = (dev <= 0.5 + 1e-6) & (mult >= 2**30) & (mult < 2**31) & (real > 0)
    return _exact_result("int8", "multiplier", ok_el.ravel(), dev.ravel(), real.ravel(),
                         lambda k: (int(k), int(mult.ravel()[k]), int(shift.ravel()[k]), float(real.ravel()[k])))._replace(
        worst=float(dev.max()) if dev.size else 0.0)


def _srdhm(a: int, b: int) -> int:
    """TFLite's SaturatingRoundingDoublingHighMul: (a b + nudge) / 2^31 truncated toward zero; INT32_MIN squared saturates."""
    if a == b == -2**31:
        return 2**31 - 1
    v = a * b + (2**30 if a * b >= 0 else 1 - 2**30)
    return v // 2**31 if v >= 0 else -((-v) // 2**31)


def _rdbpot(x: int, e: int) -> int:
    """TFLite's RoundingDivideByPOT: x / 2^e, ties away from zero."""
    mask = (1 << e) - 1
    return (x >> e) + int((x & mask) > (mask >> 1) + int(x < 0))


def _mbqm1(x: int, m: int, s: int, rounding: str) -> int:
    """TFLite's MultiplyByQuantizedMultiplierSmallerThanOneExp (s <= 0) in DOUBLE, or MultiplyByQuantizedMultiplier under TFLITE_SINGLE_ROUNDING."""
    if rounding == "DOUBLE":
        return _rdbpot(_srdhm(x, m), -s)
    n = 31 - s
    return (x * m + (1 << (n - 1))) >> n


def add_ref(q1, q2, w: dict, rounding: str = "DOUBLE") -> np.ndarray:
    """TFLite's int8 ADD (reference_integer_ops::Add, left shift 20) on Python integers, from the layer's words w (zp1 .. amax)."""
    if rounding not in ("DOUBLE", "SINGLE"):
        raise ValueError(f"add_ref: rounding must be DOUBLE or SINGLE, not {rounding!r}")
    def one(a, b):
        x = _mbqm1((int(a) - w["zp1"]) << 20, w["m1"], w["s1"], rounding) + _mbqm1((int(b) - w["zp2"]) << 20, w["m2"], w["s2"], rounding)
        return min(w["amax"], max(w["amin"], _mbqm1(x, w["mo"], w["so"], rounding) + w["zpo"]))
    return np.vectorize(one, otypes=[np.int64])(int8_codes(q1), int8_codes(q2))


def gate_add(q1, q2, w: dict, out, rounding: str = "DOUBLE") -> Result:
    """The int8 ADD stage: bit-exact against TFLite's reference kernel (add_ref), not a float64 true function: spec Decision 1, the one exception to the true-function gates."""
    want = add_ref(q1, q2, w, rounding)
    got = int8_codes(out).reshape(want.shape)
    a1, a2, g, x = int8_codes(q1).ravel(), int8_codes(q2).ravel(), got.ravel(), want.ravel()
    return _exact_result("int8", "add", g == x, np.abs(g - x).astype(float), x.astype(float),
                         lambda k: (int(k), int(a1[k]), int(a2[k]), int(g[k]), int(x[k])))


# ── affine int8 requantize and ADD on the true function (decimal rule: |hw - t| <= max(1% |t|, s_out), t clamped to the output range) ──

I8_REL = TARGET  # int8's relative tolerance; the floor is one output step


def requant_true(acc, s, zp, lo, hi):
    """The true requantized value in output codes: acc s + zp clamped to [lo, hi], float64 (acc int32, s the real scale > 0)."""
    acc = (((np.asarray(acc, dtype=np.int64) & 0xFFFFFFFF) + 2**31) & 0xFFFFFFFF) - 2**31
    return np.clip(acc * np.asarray(s, dtype=np.float64) + int8_codes(zp), int8_codes(lo), int8_codes(hi))


def add_true(q1, q2, s1, z1, s2, z2, s_out, zo, lo, hi):
    """The true ADD in output codes: (s1 (q1 - z1) + s2 (q2 - z2)) / s_out + zo clamped to [lo, hi], float64."""
    v = (np.asarray(s1, dtype=np.float64) * (int8_codes(q1) - int8_codes(z1)) +
         np.asarray(s2, dtype=np.float64) * (int8_codes(q2) - int8_codes(z2))) / np.asarray(s_out, dtype=np.float64)
    return np.clip(v + int8_codes(zo), int8_codes(lo), int8_codes(hi))


def _code_gate(func, tc, zp, q, at, first):
    """Codes q against true codes tc under the decimal rule in code units, |q - tc| <= max(I8_REL |tc - zp|, 1); no row fails (no vacuous pass)."""
    tc = np.asarray(tc, dtype=np.float64).ravel()
    q = int8_codes(q).astype(np.float64)
    q = np.broadcast_to(q, tc.shape).ravel() if q.size == 1 else q.ravel()
    zp = np.broadcast_to(int8_codes(zp), tc.shape).ravel()
    if q.shape != tc.shape:
        raise ValueError(f"{func}: {q.size} outputs for {tc.size} true values")
    dev = np.abs(q - tc)
    tol = np.maximum(I8_REL * np.abs(tc - zp), 1.0)
    miss = np.flatnonzero(dev > tol)
    i = int(np.argmax(dev)) if dev.size else 0
    worst_code = int(np.max(np.abs(q - np.floor(tc + 0.5)))) if dev.size else 0
    return Result(miss.size == 0 and tc.size > 0, "int8", func, int(tc.size), float(dev[i]) if dev.size else 0.0,
                  float(at[i]) if dev.size else 0.0, i, int(miss.size), int(miss.size), worst_code,
                  int((dev <= 1.0).sum()), 0, [first(k, q, tc) for k in miss[:FIRST]])


def gate_requantize(acc, s, zp, lo, hi, q) -> Result:
    """Requantize outputs (codes) against the true function of the real scale s; worst is the largest |q - t| in steps."""
    tc = requant_true(acc, s, zp, lo, hi)
    a = np.broadcast_to(np.asarray(acc, dtype=np.int64), tc.shape).ravel()
    return _code_gate("requantize", tc, np.broadcast_to(int8_codes(zp), tc.shape), q, a.astype(np.float64),
                      lambda k, q, tc: (int(k), int(a[k]), int(q[k]), float(tc[k])))


def gate_quantized_add(q1, q2, s1, z1, s2, z2, s_out, zo, lo, hi, out) -> Result:
    """ADD outputs (codes) against the true sum of the real values of q1 and q2; worst is the largest |out - t| in steps."""
    tc = add_true(q1, q2, s1, z1, s2, z2, s_out, zo, lo, hi)
    a1, a2 = (np.broadcast_to(int8_codes(v), tc.shape).ravel() for v in (q1, q2))
    return _code_gate("qadd", tc, np.broadcast_to(int8_codes(zo), tc.shape), out, a1.astype(np.float64),
                      lambda k, q, tc: (int(k), int(a1[k]), int(a2[k]), int(q[k]), float(tc[k])))


def gate_scale(s, m, e, width: int = 24) -> Result:
    """Scale codes (m, e) against the real scales s: |m 2^-e - s| <= s 2^-width with m in [2^(width-1), 2^width), or the saturating code
    (2^width - 1, width - 8) where s >= 2^8, or m = 0 where s < 2^-32; worst is the largest relative error in units of 2^-width."""
    s, m, e = np.broadcast_arrays(np.asarray(s, dtype=np.float64), np.asarray(m, dtype=np.int64), np.asarray(e, dtype=np.int64))
    s, m, e = s.ravel(), m.ravel(), e.ravel()
    sat, flush = s >= 2.0 ** 8, s < 2.0 ** -32
    with np.errstate(divide="ignore", invalid="ignore"):
        rel = np.abs(np.ldexp(m.astype(np.float64), -e) - s) / s * 2.0 ** width
    normal = ~sat & ~flush & (m >= 1 << (width - 1)) & (m < 1 << width) & (rel <= 1.0)
    ok_el = (s > 0) & np.where(sat, (m == (1 << width) - 1) & (e == width - 8), np.where(flush, m == 0, normal))
    r = _exact_result("int8", "scale", ok_el, np.where(np.isfinite(rel), rel, np.inf), s,
                      lambda k: (int(k), int(m[k]), int(e[k]), float(s[k])))
    return r._replace(ok=r.ok and s.size > 0, worst=float(np.max(np.where(sat | flush, 0.0, rel))) if s.size else 0.0)

def maxpool_ref(x, ph, pw, pad, fill):
    """Max of every ph x pw window, stride the window, the input padded by pad with fill on each side."""
    x = np.asarray(x, dtype=np.float64)
    H, W = x.shape
    xp = np.full((H + 2 * pad, W + 2 * pad), fill, dtype=np.float64)
    xp[pad:pad + H, pad:pad + W] = x
    oh, ow = (H + 2 * pad - ph) // ph + 1, (W + 2 * pad - pw) // pw + 1
    return np.array([[xp[i * ph:i * ph + ph, j * pw:j * pw + pw].max() for j in range(ow)] for i in range(oh)], dtype=np.float64)


def gate_maxpool(fmt, x, out, ph, pw, pad) -> Result:
    """Max pooling is exact: each output equals the max of its window of the stage's actual inputs (as values; x is 2-D)."""
    fill = -128.0 if fmt == "int8" else -np.inf
    want = maxpool_ref(values(fmt, x), ph, pw, pad, fill).ravel()
    got = values(fmt, out).ravel()
    if got.size != want.size:
        raise ValueError(f"maxpool: {got.size} outputs, the windows are {want.size}")
    ok_el = (got == want) | (np.isnan(got) & np.isnan(want))
    with np.errstate(invalid="ignore"):
        err = np.where(ok_el, 0.0, np.abs(got - want))
    return _exact_result(fmt, "maxpool", ok_el, np.where(np.isnan(err), np.inf, err), want,
                         lambda k: (int(k), float(got[k]), float(want[k])))


def gate_dropout(fmt, x, keep, out, p, training, zp=0) -> Result:
    """Dropout is exact against its mask: training keeps x / (1 - p) (rounded to fmt; int8 keeps x) or drops to 0 (int8: zp); inference passes x."""
    xv, got = values(fmt, x).ravel(), values(fmt, out).ravel()
    keep = np.asarray(keep, dtype=bool).ravel()
    if fmt == "int8":
        kept, dropped = xv, np.broadcast_to(np.asarray(zp, dtype=np.float64), xv.shape)
    else:
        with np.errstate(over="ignore"):
            kept = values(fmt, encode(fmt, xv / (1.0 - p)))
        dropped = np.zeros_like(xv)
    want = np.where(keep, kept, dropped) if training else xv
    ok_el = (got == want) | (np.isnan(got) & np.isnan(want))
    with np.errstate(invalid="ignore"):
        err = np.where(ok_el, 0.0, np.abs(got - want))
    return _exact_result(fmt, "dropout", ok_el, np.where(np.isnan(err), np.inf, err), want,
                         lambda k: (int(k), float(xv[k]), float(got[k]), float(want[k])))


def stage_line(r: Result) -> str:
    """One report line for a stage gate's result, named by its stage and format."""
    if r.func == "matmul":
        w = (f"worst {100 * r.worst:.3g}% of sum|ab|" if np.isfinite(r.worst) else f"worst {worst_text(r.worst)}") + \
            (f" ({r.worst_lsb} in int32)" if r.fmt == "int8" else "")
        rule = f"over max({100 * MM_BOUND:g}% of sum|ab|, 2^-126): {r.over}  (floor {r.n_floor}, overflow {r.n_ovf})"
    elif r.func == "requant":
        w = f"worst {r.worst:.3f} LSB from real, {r.worst_lsb} from round(real)"
        rule = f"over {I8_FLOOR} LSB: {r.over}"
    elif r.func == "narrow":
        w = f"worst {r.worst_lsb} ULP"
        rule = f"not round-to-nearest-even: {r.over}"
    elif r.func in ("requantize", "qadd"):
        w = f"worst {r.worst:.3f} steps from the true value, {r.worst_lsb} codes from its round"
        rule = f"over max({100 * I8_REL:g}% |t|, one step): {r.over}  (within one step {r.n_floor})"
    elif r.func == "scale":
        w = f"worst {r.worst:.3f} x 2^-24 relative"
        rule = f"off the code: {r.over}"
    elif r.func == "multiplier":
        w = f"worst {r.worst:.3f} LSB of the multiplier from s_a s_w / s_out"
        rule = f"over 0.5 LSB: {r.over}"
    else:
        w = f"worst |out - want| {r.worst:.6g}"
        rule = f"not exact: {r.over}"
    return f"TRUTH {r.fmt} {r.func}: {'PASS' if r.ok else 'FAIL'}  n {r.n}  {w}  {rule}"


def merge(rs) -> Result:
    """One Result over several of one stage and format: counts summed, the worst kept, the first misses in order."""
    rs = [r for r in rs if r is not None]
    if not rs:
        return None
    w = max(rs, key=lambda r: (r.worst, r.worst_lsb))
    return w._replace(ok=all(r.ok for r in rs), n=sum(r.n for r in rs), over=sum(r.over for r in rs),
                      over_target=sum(r.over_target for r in rs), worst_lsb=max(r.worst_lsb for r in rs),
                      n_floor=sum(r.n_floor for r in rs), n_ovf=sum(r.n_ovf for r in rs), first=[m for r in rs for m in r.first][:FIRST])


# ── selftest: every rule passing and failing on hand-made cases ──


def selftest() -> int:
    fails, checks = [0], [0]

    def check(what, got, want):
        checks[0] += 1
        if got != want:
            fails[0] += 1
            print(f"[FAIL] {what}: got {got}, want {want}")

    def fl(what, fmt, func, x, o, ok, over=None, over_t=None, **kw):
        r = gate(fmt, func, np.atleast_1d(x), np.atleast_1d(o), **kw)
        check(f"{what}: ok", r.ok, ok)
        if over is not None:
            check(f"{what}: over", r.over, over)
        if over_t is not None:
            check(f"{what}: over target", r.over_target, over_t)
        return r

    b = lambda v: int(encode("bf16", v))
    s = lambda v: int(encode("fp32", v))
    bmax, binf, bnan = 0x7F7F, 0x7F80, 0x7FC0
    # references
    check("sigmoid(-700) = e^-700 / (1 + e^-700)", float(sigmoid(-700.0)), float(np.exp(-700.0)))
    check("sigmoid(800) = 1", float(sigmoid(800.0)), 1.0)
    check("sigmoid(0) = 0.5", float(sigmoid(0.0)), 0.5)
    check("selu(1) = 1.0507009873554805", float(selu(1.0)), 1.0507009873554805)  # literals, so a wrong constant fails
    check("selu(-1) = -1.1113307378125625", float(selu(-1.0)), -1.1113307378125625)
    check("selu(-40) = -1.7580993408473766", abs(float(selu(-40.0)) + 1.7580993408473766) < 1e-15, True)
    check("tanh(20) = 1", float(tanh(20.0)), 1.0)
    check("relu(-3) = 0, relu(3) = 3", (float(relu(-3.0)), float(relu(3.0))), (0.0, 3.0))
    # the bound: an output 9% off passes 10% and counts over 1%; 11% off fails; within 1% counts nowhere
    x1 = b(1.0)
    t1 = float(sigmoid(1.0))
    fl("bf16 sigmoid 1.0, rounded", "bf16", "sigmoid", x1, b(t1), True, 0, 0)
    fl("bf16 sigmoid 1.0, 5% off", "bf16", "sigmoid", x1, b(t1 * 1.05), True, 0, 1)
    fl("bf16 sigmoid 1.0, 9% off", "bf16", "sigmoid", x1, b(t1 * 1.09), True, 0, 1)
    fl("bf16 sigmoid 1.0, 11% off", "bf16", "sigmoid", x1, b(t1 * 1.11), False, 1, 1)
    fl("bf16 sigmoid 1.0, 5% off, bound 1%", "bf16", "sigmoid", x1, b(t1 * 1.05), False, 1, 1, bound=0.01)
    fl("fp32 sigmoid 1.0, 1.5% off counts over target", "fp32", "sigmoid", s(1.0), s(t1 * 1.015), True, 0, 1)
    fl("fp32 sigmoid 1.0, 0.5% off", "fp32", "sigmoid", s(1.0), s(t1 * 1.005), True, 0, 0)
    fl("fp32 tanh 0.5, 1 ulp off", "fp32", "tanh", s(0.5), s(np.tanh(0.5)) + 1, True, 0, 0)
    # NaN and Inf where the true value is finite
    fl("bf16 sigmoid 0, NaN out", "bf16", "sigmoid", b(0.0), bnan, False, 1)
    fl("bf16 sigmoid 0, +Inf out", "bf16", "sigmoid", b(0.0), binf, False, 1)
    fl("bf16 tanh -1, -Inf out", "bf16", "tanh", b(-1.0), 0xFF80, False, 1)
    fl("fp32 linear max, +Inf out (true finite)", "fp32", "linear", 0x7F7FFFFF, 0x7F800000, False, 1)
    fl("bf16 linear max, max out", "bf16", "linear", bmax, bmax, True, 0)
    # the float floor: both at or below 2^-126 pass; the output or the true value above it is judged by the bound
    n0, n1 = 0x0080, 0x0081  # 2^-126 and the next bf16 above it
    fl("bf16 tanh 2^-126 flushed to 0 (both <= floor)", "bf16", "tanh", n0, 0, True, 0)
    fl("bf16 tanh next above 2^-126 flushed to 0", "bf16", "tanh", n1, 0, False, 1)
    fl("bf16 tanh next above 2^-126, out 2^-126", "bf16", "tanh", n1, n0, True, 0)
    fl("bf16 tanh 2^-130, out 2^-126 (out at the floor)", "bf16", "tanh", b(2.0 ** -130), n0, True, 0)
    fl("bf16 tanh 2^-130, out next above 2^-126", "bf16", "tanh", b(2.0 ** -130), n1, False, 1)
    fl("fp32 tanh 2^-126 flushed (both <= floor)", "fp32", "tanh", 0x00800000, 0, True, 0)
    fl("fp32 tanh next above 2^-126 flushed", "fp32", "tanh", 0x00800001, 0, False, 1)
    # a subnormal input reads as zero; a normal input just above 2^-126 is judged as given
    fl("bf16 selu max subnormal, out 0 (input reads as 0)", "bf16", "selu", 0x007F, 0, True, 0, 0)
    fl("bf16 selu max negative subnormal, out -0", "bf16", "selu", 0x807F, 0x8000, True, 0, 0)
    fl("bf16 selu max subnormal, out 2^-126 (both <= floor)", "bf16", "selu", 0x007F, n0, True, 0, 0)
    fl("bf16 selu max subnormal, out 2^-125 (true 0)", "bf16", "selu", 0x007F, 0x0100, False, 1)
    fl("bf16 selu min subnormal, out 0", "bf16", "selu", 0x0001, 0, True, 0)
    fl("bf16 selu next above 2^-126, flushed to 0", "bf16", "selu", n1, 0, False, 1)
    fl("bf16 selu 2^-126 (normal, judged as given), out lambda 2^-126", "bf16", "selu", n0, b(SELU_LAMBDA * 2.0 ** -126), True, 0, 0)
    fl("fp32 selu max subnormal, out 0", "fp32", "selu", 0x007FFFFF, 0, True, 0)
    fl("fp32 selu next above 2^-126, flushed to 0", "fp32", "selu", 0x00800001, 0, False, 1)
    fl("bf16 sigmoid max subnormal, out 0.5", "bf16", "sigmoid", 0x007F, b(0.5), True, 0, 0)
    fl("bf16 relu negative subnormal, out 0", "bf16", "relu", 0x8040, 0, True, 0)
    fl("bf16 linear subnormal passed through (both <= floor)", "bf16", "linear", 0x0040, 0x0040, True, 0)
    # overflow: only max or Inf of the true value's sign passes
    r = fl("bf16 selu max, out max", "bf16", "selu", bmax, bmax, True, 0)
    check("bf16 selu max: counted as overflow", r.n_ovf, 1)
    fl("bf16 selu max, out +Inf", "bf16", "selu", bmax, binf, True, 0)
    fl("bf16 selu max, out finite below max", "bf16", "selu", bmax, 0x7F7E, False, 1)
    fl("bf16 selu max, out -Inf", "bf16", "selu", bmax, 0xFF80, False, 1)
    fl("bf16 selu max, out NaN", "bf16", "selu", bmax, bnan, False, 1)
    fl("fp32 selu max, out max", "fp32", "selu", 0x7F7FFFFF, 0x7F7FFFFF, True, 0)
    fl("fp32 selu max, out 2^127", "fp32", "selu", 0x7F7FFFFF, 0x7F000000, False, 1)
    fl("bf16 selu 0x7F73 (true 3.3938e38, above max, rounds to max), out 0x7F7E", "bf16", "selu", 0x7F73, 0x7F7E, False, 1)
    fl("bf16 selu 0x7F73, out max", "bf16", "selu", 0x7F73, bmax, True, 0)
    fl("bf16 selu 0x7F72 (true 3.3798e38, below max), out 0x7F7D", "bf16", "selu", 0x7F72, 0x7F7D, True, 0)
    check("fmax", (fmax("bf16"), fmax("fp32")), (float(decode("bf16", bmax)), float(np.finfo(np.float32).max)))
    # int8: within 1 LSB of the rounded true value, or within the bound dequantized
    tq = (4 / 128, 0, 1 / 128, 0)  # tanh: x = q / 32, out q / 128
    i8 = lambda what, func, q, o, ok, over=None, quant=tq, **kw: fl(what, "int8", func, q, o, ok, over, quant=quant, **kw)
    i8("int8 tanh q=2 (x 1/16, q_true 8), out 8", "tanh", 2, 8, True, 0)
    i8("int8 tanh q=2, out 9 (1 LSB)", "tanh", 2, 9, True, 0)
    i8("int8 tanh q=2, out 10 (2 LSB, 25%)", "tanh", 2, 10, False, 1)
    i8("int8 tanh q=2, out 6 (2 LSB below)", "tanh", 2, 6, False, 1)
    i8("int8 tanh q=32 (q_true 97), out 99 (2 LSB, 1.5%)", "tanh", 32, 99, True, 0)
    i8("int8 tanh q=32, out 112 (15 LSB, 14.9%)", "tanh", 32, 112, False, 1)
    i8("int8 tanh q=0, out 1 (true 0)", "tanh", 0, 1, True, 0)
    i8("int8 tanh q=0, out 2 (true 0)", "tanh", 0, 2, False, 1)
    i8("int8 tanh 8-bit words: q 0xFE (-2), out 0xF8 (-8)", "tanh", 0xFE, 0xF8, True, 0)
    sq = (3.5 / 8, 0, 1 / 256, -128)  # sigmoid with TFLite's output quantization
    r = i8("int8 sigmoid q=100 (clamps to 127), out 127", "sigmoid", 100, 127, True, 0, sq)
    i8("int8 sigmoid q=100, out 120 (7 LSB, 2.7% of the clamped value)", "sigmoid", 100, 120, True, 0, sq)
    i8("int8 sigmoid q=-20 (q_true -128), out -125 (3 LSB)", "sigmoid", -20, -125, False, 1, sq)
    i8("int8 linear identity", "linear", np.arange(-128, 128), np.arange(-128, 128), True, 0, (0.05, 7, 0.05, 7))
    i8("int8 linear off by 2", "linear", 3, 5, False, 1, (0.05, 0, 0.05, 0))
    i8("int8 linear 100 past the output range (q_true 127), out 120 (5.5% of the clamp)", "linear", 100, 120, True, 0, (1.0, 0, 0.05, 0))
    i8("int8 linear 100 past the output range, out 110 (13% of the clamp)", "linear", 100, 110, False, 1, (1.0, 0, 0.05, 0))
    i8("int8 relu q < z_in, out z_out", "relu", -100, -20, True, 0, (0.05, -20, 0.05, -20))
    i8("int8 selu zero multiplier (s_out inf), out z_out", "selu", 50, 7, True, 0, (0.05, 0, np.inf, 7))
    i8("int8 selu zero multiplier, out z_out + 2", "selu", 50, 9, False, 1, (0.05, 0, np.inf, 7))
    i8("int8 relu q < z_in, out q", "relu", -100, -100, False, 1, (0.05, -20, 0.05, -20))
    # the result reports the worst, where it is, and the misses
    xs = encode("bf16", np.array([0.5, 1.0, 2.0, 3.0]))
    os_ = encode("bf16", sigmoid(decode("bf16", xs)) * np.array([1.0, 1.2, 1.05, 1.3]))
    r = gate("bf16", "sigmoid", xs, os_)
    check("worst index", r.idx, 3)
    check("worst value near 30%", abs(r.worst - 0.3) < 0.01, True)
    check("misses listed", [m[0] for m in r.first], [1, 3])
    check("counts", (r.n, r.over, r.over_target), (4, 2, 3))
    check("line", line(r).startswith("TRUTH bf16 sigmoid: FAIL  n 4  worst "), True)
    check("line names an unbounded miss", "worst unbounded" in line(gate("bf16", "sigmoid", [0], [bnan])), True)
    check("worst_text", (worst_text(0.0123), worst_text(np.inf).startswith("unbounded")), ("1.230%", True))
    # matmul: within max(1% of sum|ab|, 2^-126) of the float64 sum, bias included, every pass summed
    A, B = np.array([[1.0, 2.0], [3.0, -4.0]]), np.array([[0.5, -1.0], [0.25, 2.0]])
    Aw, Bw = encode("fp32", A), encode("fp32", B)
    tm = A @ B  # [[1, 3], [2.5, -11]]; sum|ab| [[1, 5], [2.5, 11]]
    mm = lambda o, ok, over=None, **kw: (lambda r: (check(f"matmul {o}: ok", r.ok, ok), over is None or check(f"matmul {o}: over", r.over, over), r)[2])(
        gate_matmul("fp32", kw.pop("passes", [(Aw, Bw)]), encode("fp32", np.asarray(o, dtype=np.float64)), **kw))
    mm(tm, True, 0)
    mm(tm + np.array([[0.0, 0.049], [0.0, 0.0]]), True, 0)  # 0.98% of 5
    mm(tm + np.array([[0.0, 0.051], [0.0, 0.0]]), False, 1)  # 1.02% of 5
    mm(tm - np.array([[0.0, 0.0], [0.0, 0.12]]), False, 1)  # 1.09% of 11
    r = mm(tm + np.array([[0.0, 0.0], [0.0, 0.1]]), True, 0)
    check("matmul worst is |err| / sum|ab|", abs(r.worst - 0.1 / 11) < 1e-6, True)
    mm(np.where(np.eye(2, dtype=bool), tm, np.inf), False, 2)
    mm(np.where(np.eye(2, dtype=bool), tm, np.nan), False, 2)
    bias = encode("fp32", np.array([10.0, -20.0]))
    mm(tm + np.array([10.0, -20.0]), True, 0, bias=bias)
    mm(tm, False, 4, bias=bias)  # the bias left out
    mm(tm + np.array([10.0, -19.96]), True, 0, bias=bias)  # 0.04 within 1% of sum|ab| (5 and 11): the bias is not in the scale
    mm(tm + np.array([10.0, -19.9]), False, 1, bias=bias)  # 0.1 over 1% of 5, though within 1% of sum|ab| + |bias|
    mm(2 * tm, True, 0, passes=[(Aw, Bw), (Aw, Bw)])
    mm(tm, False, 4, passes=[(Aw, Bw), (Aw, Bw)])  # a pass left out
    Z = encode("fp32", np.zeros((2, 2)))
    mm(np.full((2, 2), 2.0 ** -126), True, 0, passes=[(Z, Z)])  # sum|ab| 0: the 2^-126 floor
    mm(np.full((2, 2), 2.0 ** -125), False, 4, passes=[(Z, Z)])
    check("matmul floor counted", gate_matmul("fp32", [(Z, Z)], Z).n_floor, 4)
    M = encode("fp32", np.full((2, 2), 2.0 ** 127))
    one = encode("fp32", np.ones((2, 2)))  # true sums 2^128, above fp32's max
    for what, o, ok in (("Inf", np.inf, True), ("max", fmax("fp32"), True), ("-Inf", -np.inf, False), ("2^127", 2.0 ** 127, False)):
        r = gate_matmul("fp32", [(M, one)], encode("fp32", np.full((2, 2), o)))
        check(f"matmul true sum past fp32's max, out {what}", (r.ok, r.n_ovf), (ok, 4))
    r = gate_matmul("bf16", [(encode("bf16", A), encode("bf16", B))], encode("fp32", tm))
    check("matmul bf16 operands, fp32 sums", r.ok, True)
    sub = np.array([[0x00400000, 0], [0x3F800000, 0x3F800000]])  # a subnormal operand (2^-127) reads as zero, not 2^-127 2^126
    r = gate_matmul("fp32", [(sub, encode("fp32", np.full((2, 2), 2.0 ** 126)))], encode("fp32", np.array([[0.0] * 2, [2.0 ** 127] * 2])))
    check("matmul: a subnormal operand reads as zero", r.ok, True)
    ia, ib = np.array([[127, -128], [5, 6]]), np.array([[-128, 1], [127, 2]])
    ti = ia @ ib
    i32 = lambda v: np.asarray(v, dtype=np.int64) & 0xFFFFFFFF
    check("matmul int8 exact", gate_matmul("int8", [(ia & 0xFF, ib & 0xFF)], i32(ti)).ok, True)
    for off, n in ((1, 1), (-1, 1), (150, 1), (300, 1)):  # exact: one LSB off fails, though 300 is under 1% of sum|ab| = 32512
        r = gate_matmul("int8", [(ia, ib)], i32(ti + np.array([[off, 0], [0, 0]])))
        check(f"matmul int8 {off} off fails", (r.ok, r.over, r.worst_lsb), (False, n, abs(off)))
    big = np.array([2**31 - 40000, 0])
    r = gate_matmul("int8", [(ia, ib)], i32(ti + big), bias=i32(big))
    check("matmul int8 bias near int32 max, sums in range", r.ok, True)
    wrap = np.array([2**31 - 1, 0])  # true sums [[2^31, 0], [2^31 - 1, 0]]: the first is past int32 and wraps to -2^31
    one = (np.array([[1, 0], [0, 0]]), np.array([[1, 0], [0, 0]]))
    for what, w00, ok in (("its two's-complement wrap passes", -2**31, True), ("saturated to INT32_MAX fails", 2**31 - 1, False),
                          ("wrapped one off fails", -2**31 + 1, False), ("wrapped as 31 bits fails", 0, False)):
        r = gate_matmul("int8", [one], i32(np.array([[w00, 0], [2**31 - 1, 0]])), bias=i32(wrap))
        check(f"matmul int8 sum past int32: {what}", (r.ok, r.over, r.n_ovf), (ok, 0 if ok else 1, 1))
    full = (np.full((16, 16), 127), np.full((16, 16), 127))  # sum|ab| = 258064 per element, sums 258064 + bias
    nb = np.full(16, 2**31 - 100000)  # every true sum is 2^31 + 158064: past INT32_MAX
    tw = -2**31 + 158064
    r = gate_matmul("int8", [full], i32(np.full((16, 16), tw)), bias=i32(nb))
    check("matmul int8, sum|ab| 258064: the wrapped sums pass", (r.ok, r.n_ovf, r.worst_lsb), (True, 256, 0))
    r = gate_matmul("int8", [full], i32(np.full((16, 16), 2**31 - 1)), bias=i32(nb))
    check("matmul int8, sum|ab| 258064: a saturating accumulator fails every element", (r.ok, r.over), (False, 256))
    r = gate_matmul("int8", [full], i32(np.full((16, 16), tw + 1)), bias=i32(nb))
    check("matmul int8, sum|ab| 258064: wrapped and 1 off fails every element", (r.ok, r.over, r.worst_lsb), (False, 256, 1))
    r = gate_matmul("int8", [full], i32(np.full((16, 16), tw - 150)), bias=i32(nb))
    check("matmul int8: wrapped and 150 off (0.06% of sum|ab|) fails", (r.ok, r.over), (False, 256))
    # narrowing: round to nearest even, exactly
    nr = lambda what, pre, post, ok: check(f"narrow {what}", gate_narrow("bf16", [pre], [post]).ok, ok)
    nr("1.0", 0x3F800000, 0x3F80, True)
    nr("tie to even down", 0x3F808000, 0x3F80, True)
    nr("tie to even up", 0x3F818000, 0x3F82, True)
    nr("tie to even, truncated", 0x3F818000, 0x3F81, False)
    nr("above half, rounded up", 0x3F80C000, 0x3F81, True)
    nr("above half, truncated", 0x3F80C000, 0x3F80, False)
    nr("below half", 0x3F807FFF, 0x3F80, True)
    nr("past max rounds to Inf", 0x7F7F8000, 0x7F80, True)
    nr("past max, max", 0x7F7F8000, 0x7F7F, False)
    nr("-0", 0x80000000, 0x8000, True)
    nr("subnormal reads as 0", 0x00400000, 0x0000, True)
    nr("NaN", 0x7FC00001, 0x7FC0, True)
    nr("NaN, out a number", 0x7FC00001, 0x3F80, False)
    check("narrow ULP distance", gate_narrow("bf16", [0x3F80C000], [0x3F7F]).worst_lsb, 2)
    # requantize: within 1 LSB of round(acc mult 2^(shift-31) + zp), clamped
    m1 = 1 << 30  # 0.5 at shift 0
    rq = lambda what, acc, q, ok, shift=0, zp=0, lo=-128, hi=127, mult=m1: check(f"requant {what}", gate_requant(acc, mult, shift, zp, lo, hi, q).ok, ok)
    rq("100 * 0.5", 100, 50, True)
    rq("100 * 0.5, 1 LSB up", 100, 51, True)
    rq("100 * 0.5, 2 LSB up", 100, 52, False)
    rq("100 * 0.5, 2 LSB down", 100, 48, False)
    rq("101 * 0.5 = 50.5 rounds to 51; 50 is 1 LSB", 101, 50, True)
    rq("101 * 0.5, 49", 101, 49, False)
    rq("-101 * 0.5 = -50.5 rounds to -50; -52 is 2 LSB", -101, -52, False)
    rq("shift -3: 100 * 0.5 / 8 = 6.25", 100, 6, True, shift=-3)
    rq("shift -3, 8", 100, 8, False, shift=-3)
    rq("shift 2: 10 * 0.5 * 4 = 20", 10, 20, True, shift=2)
    rq("zero point 7", 100, 57, True, zp=7)
    rq("zero point 7 left out", 100, 50, False, zp=7)
    rq("clamp to 127", 1000, 127, True)
    rq("clamp to 127, out 120", 1000, 120, False)
    rq("clamp min 3 (ReLU at zp 3)", -1000, 3, True, zp=3, lo=3)
    rq("8-bit word 0xCE (-50)", -100, 0xCE, True)
    check("requant_ref exact near 2^62", [int(requant_ref(-2**31, 2**31 - 1, s, 0, -2**40, 2**40)[0]) for s in (0, -31)], [-(2**31 - 1), -1])
    check("requant worst LSBs", gate_requant([100, 100], m1, 0, 0, -128, 127, [50, 53]).worst_lsb, 3)
    # the int8 ADD, bit-exact: (q1 + q2) / 4 with every multiplier 0.5, zero points 0 and 3, a ReLU clamp at zp_o
    aw = dict(zp1=0, zp2=0, m1=m1, s1=0, m2=m1, s2=0, mo=m1, so=-20, zpo=0, amin=-128, amax=127)
    check("add (10 + 10) / 4", add_ref([10], [10], aw).tolist(), [5])
    check("add -6 / 4 ties away from zero", add_ref([-3], [-3], aw).tolist(), [-2])
    check("add exact", gate_add([10, -3, 100], [10, -3, 100], aw, [5, -2, 50]).ok, True)
    check("add one code off", gate_add([10, -3, 100], [10, -3, 100], aw, [5, -1, 50]).over, 1)
    check("add zero points", add_ref([13], [10], dict(aw, zp1=3, zpo=3)).tolist(), [8])
    check("add ReLU clamp at zp_o", add_ref([-100], [-100], dict(aw, zpo=3, amin=3)).tolist(), [3])
    check("add 8-bit words", gate_add([0xF6], [0xF6], aw, [0xFB]).ok, True)
    # the requantize multipliers: mult 2^(shift - 31) within half a multiplier LSB of the real ratio
    import math
    def qm(r):  # TFLite QuantizeMultiplier, here to make the cases
        q, e = math.frexp(r)
        m = int(round(q * 2**31))
        return (m // 2, e + 1) if m == 2**31 else (m, e)
    reals = np.array([0.000123, 0.0071, 0.5, 0.999999999, 1.7e-5])
    ms, es = zip(*(qm(float(r)) for r in reals))
    check("multiplier: QuantizeMultiplier's words pass", gate_multiplier(ms, es, reals).ok, True)
    check("multiplier: one LSB high fails", gate_multiplier(np.array(ms) + 1, es, reals).over, 5)
    check("multiplier: shift one low fails", gate_multiplier(ms, np.array(es) - 1, reals).over, 5)
    check("multiplier: an unnormalized mult fails", gate_multiplier([ms[2] // 2], [es[2] + 1], [reals[2]]).ok, False)
    # max pooling: the max of each window of the actual inputs, padded with -Inf (int8: -128)
    x = np.arange(16.0).reshape(4, 4) - 8.0
    xw = encode("fp32", x)
    pw2 = maxpool_ref(x, 2, 2, 1, -np.inf)
    check("maxpool_ref 2x2 pad 1", pw2.tolist(), [[-8.0, -6.0, -5.0], [0.0, 2.0, 3.0], [4.0, 6.0, 7.0]])
    check("maxpool exact", gate_maxpool("fp32", xw, encode("fp32", pw2), 2, 2, 1).ok, True)
    first = np.array([[x[0, 0], x[0, 1], x[0, 3]], [x[1, 0], x[1, 1], x[1, 3]], [x[3, 0], x[3, 1], x[3, 3]]])  # each window's first input
    r = gate_maxpool("fp32", xw, encode("fp32", first), 2, 2, 1)
    check("maxpool first element instead of the max", (r.ok, r.over), (False, 5))
    check("maxpool -0 and +0 are one max", gate_maxpool("bf16", [[0x8000, 0x0000]], [0x8000], 1, 2, 0).ok, True)
    xi = np.array([[-128, 5], [3, -7]])
    check("maxpool int8, pad -128", gate_maxpool("int8", xi & 0xFF, np.array([-128, 5, 3, -7]) & 0xFF, 2, 2, 1).ok, True)
    check("maxpool 1x1 is the identity", gate_maxpool("int8", xi, xi.ravel(), 1, 1, 0).ok, True)
    check("maxpool 1x1, one differs", gate_maxpool("int8", xi, [-128, 5, 3, -6], 1, 1, 0).ok, False)
    # dropout: exact against the mask
    xd = encode("bf16", np.array([1.5, -2.0, 3.0, -0.0]))
    keep = np.array([True, False, True, False])
    do = lambda what, out, ok, **kw: check(f"dropout {what}", gate_dropout("bf16", xd, keep, encode("bf16", np.asarray(out, dtype=np.float64)),
                                                                           0.5, kw.get("training", True)).ok, ok)
    do("kept doubled, dropped 0", [3.0, -0.0, 6.0, 0.0], True)
    do("kept not scaled", [1.5, 0.0, 3.0, 0.0], False)
    do("a dropped one kept", [3.0, -4.0, 6.0, 0.0], False)
    do("inference passes x", [1.5, -2.0, 3.0, -0.0], True, training=False)
    do("inference, scaled", [3.0, -4.0, 6.0, 0.0], False, training=False)
    check("dropout int8: dropped to zp", gate_dropout("int8", [10, 20], [True, False], [10, -5], 0.5, True, -5).ok, True)
    check("dropout int8: dropped to 0, zp -5", gate_dropout("int8", [10, 20], [True, False], [10, 0], 0.5, True, -5).ok, False)
    check("stage_line", stage_line(gate_matmul("fp32", [(Aw, Bw)], encode("fp32", tm))).startswith("TRUTH fp32 matmul: PASS  n 4  worst 0% of sum|ab|"), True)
    check("merge", (lambda m: (m.ok, m.n, m.over))(merge([gate_requant(100, m1, 0, 0, -128, 127, 50), gate_requant(100, m1, 0, 0, -128, 127, 53)])),
          (False, 2, 1))
    # affine int8 requantize and ADD on the true function, in output codes
    gq = lambda acc, sc, q, zp=0, lo=-128, hi=127: gate_requantize(acc, sc, zp, lo, hi, q)
    check("requantize: 100 x 0.5 is 50", gq([100], [0.5], [50]).ok, True)
    check("requantize: 51 for 50 is one step", gq([100], [0.5], [51]).ok, True)
    check("requantize: 52 for 50 fails", gq([100], [0.5], [52]).over, 1)
    check("requantize: 50.5 passes 51 and 50", gq([101, 101], [0.5, 0.5], [51, 50]).ok, True)
    check("requantize: 1% of 150.5 steps passes 1.5", gq([301], [0.5], [24], -128).ok, True)
    check("requantize: and fails 2.5", gq([301], [0.5], [25], -128).ok, False)
    check("requantize: zp added", gq([100], [0.5], [53], 3).ok, True)
    check("requantize: zp not added fails", gq([100], [0.5], [50], 5).ok, False)
    check("requantize: clamped to hi", gq([1000], [0.5], [127]).ok, True)
    check("requantize: clamped to a ReLU's lo", gq([-1000], [0.5], [-5], -5, -5).ok, True)
    check("requantize: unclamped fails at a ReLU's lo", gq([-20], [0.5], [-10], 0, 0).ok, False)
    check("requantize: acc as an int32 word", gq([0xFFFFFF9C], [0.5], [-50]).ok, True)
    check("requantize: empty fails", gq([], [], []).ok, False)
    check("requantize: worst in steps", gq([100, 100], [0.5, 0.5], [50, 53]).worst, 3.0)
    gqa = lambda q1, q2, out, s1=0.25, z1=0, s2=0.25, z2=0, so=1.0, zo=0, lo=-128, hi=127: gate_quantized_add(q1, q2, s1, z1, s2, z2, so, zo, lo, hi, out)
    check("qadd: (10 + 10) / 4", gqa([10], [10], [5]).ok, True)
    check("qadd: 3 for 5 fails", gqa([10], [10], [3]).over, 1)
    check("qadd: z1", gqa([50], [10], [5], z1=40).ok, True)
    check("qadd: z2", gqa([10], [-10], [8], z2=-30).ok, True)
    check("qadd: z1 as z2 fails", gqa([10], [-10], [3], z1=-30).ok, False)
    check("qadd: zo", gqa([10], [10], [9], zo=4).ok, True)
    check("qadd: s_out", gqa([10], [10], [10], so=0.5).ok, True)
    check("qadd: s_out ignored fails", gqa([10], [10], [5], so=0.25).ok, False)
    check("qadd: clamped at lo", gqa([-100], [-100], [3], zo=3, lo=3).ok, True)
    check("qadd: 8-bit words", gqa([0xF6], [0xF6], [0xFB]).ok, True)
    check("qadd: empty fails", gqa([], [], []).ok, False)
    check("scale: 0.75 as 12582912 2^-24", gate_scale([0.75], [12582912], [24]).ok, True)
    check("scale: one LSB high fails", gate_scale([0.75], [12582913], [24]).ok, False)
    check("scale: an unnormalized code fails", gate_scale([0.75], [6291456], [23]).ok, False)
    check("scale: the saturating code", gate_scale([300.0], [2**24 - 1], [16]).ok, True)
    check("scale: past 2^8 not saturated fails", gate_scale([300.0], [9830400], [15]).ok, False)
    check("scale: the flush code", gate_scale([1e-12], [0], [55]).ok, True)
    check("scale: empty fails", gate_scale([], [], []).ok, False)
    check("stage_line requantize", stage_line(gq([100], [0.5], [50])).startswith("TRUTH int8 requantize: PASS  n 1  worst 0.000 steps"), True)
    print(f"truth selftest: {checks[0]} checks, {fails[0]} failures")
    print(f"RESULT: {'PASSED' if fails[0] == 0 else 'FAILED'}")
    return fails[0]


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--selftest", action="store_true", help="every rule passing and failing on hand-made cases")
    a = ap.parse_args()
    if not a.selftest:
        ap.error("nothing to do; truth.py is a library (import it), or run --selftest")
    sys.exit(1 if selftest() else 0)


if __name__ == "__main__":
    main()
