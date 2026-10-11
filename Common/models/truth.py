#!/usr/bin/env python3
"""True-function gate: float64 numpy references for the activations, and the pass rule every activation run gates on.

The reference is the function of the actual input (subnormals are not flushed); a bit-exact model of the hardware is never the gate.
Floats pass when |out - t| <= bound |t|, or when |out| and |t| are both <= F_FLOOR; a NaN or Inf output where t is finite fails;
where t overflows the format, only the format's max or Inf of t's sign passes.
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


def ovf(fmt):
    """The smallest magnitude that rounds to Inf: max plus half an ulp."""
    return 2.0 ** 128 - 2.0 ** (126 - FLOATS[fmt])


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


def _float_err(fmt, t, o):
    """Per-element error: 0 where a floor or the overflow rule passes, inf where a rule fails outright, else |o - t| / |t|."""
    big = np.abs(t) >= ovf(fmt)
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
    t = ref(func, s_in * (q - z_in))
    lo, hi = s_out * (-128 - z_out), s_out * (127 - z_out)
    qt = np.clip(np.floor(t / s_out + 0.5) + z_out, -128, 127)
    lsb = np.abs(out - qt)
    tc = np.clip(t, lo, hi)
    deq = s_out * (out - z_out)
    with np.errstate(divide="ignore", invalid="ignore"):
        rel = np.where(tc != 0, np.abs(deq - tc) / np.abs(tc), np.where(deq == 0, 0.0, np.inf))
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
        t = ref(func, x)
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


def line(r: Result, bound=None, target=None) -> str:
    """One report line for a result."""
    bound = BOUND if bound is None else bound
    target = TARGET if target is None else target
    lsb = f"  worst {r.worst_lsb} LSB" if r.fmt == "int8" else ""
    return (f"TRUTH {r.fmt} {r.func}: {'PASS' if r.ok else 'FAIL'}  n {r.n}  worst {100 * r.worst:.3f}% at x = {r.at:.6g}{lsb}  "
            f"over {100 * bound:g}%: {r.over}  over {100 * target:g}%: {r.over_target}  (floor {r.n_floor}, overflow {r.n_ovf})")


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
    # subnormal inputs are not flushed in the reference
    fl("bf16 selu max subnormal, out 0 (true 1.04 x 2^-126)", "bf16", "selu", 0x007F, 0, False, 1)
    fl("bf16 selu max subnormal, out 2^-126", "bf16", "selu", 0x007F, n0, True, 0, 1)
    fl("bf16 selu min subnormal, out 0", "bf16", "selu", 0x0001, 0, True, 0)
    fl("bf16 sigmoid max subnormal, out 0.5", "bf16", "sigmoid", 0x007F, b(0.5), True, 0, 0)
    fl("bf16 relu negative subnormal, out 0", "bf16", "relu", 0x8040, 0, True, 0)
    # overflow: only max or Inf of the true value's sign passes
    r = fl("bf16 selu max, out max", "bf16", "selu", bmax, bmax, True, 0)
    check("bf16 selu max: counted as overflow", r.n_ovf, 1)
    fl("bf16 selu max, out +Inf", "bf16", "selu", bmax, binf, True, 0)
    fl("bf16 selu max, out finite below max", "bf16", "selu", bmax, 0x7F7E, False, 1)
    fl("bf16 selu max, out -Inf", "bf16", "selu", bmax, 0xFF80, False, 1)
    fl("bf16 selu max, out NaN", "bf16", "selu", bmax, bnan, False, 1)
    fl("fp32 selu max, out max", "fp32", "selu", 0x7F7FFFFF, 0x7F7FFFFF, True, 0)
    fl("fp32 selu max, out 2^127", "fp32", "selu", 0x7F7FFFFF, 0x7F000000, False, 1)
    check("ovf(bf16) = 2^128 - 2^119", ovf("bf16"), 2.0 ** 128 - 2.0 ** 119)
    with np.errstate(over="ignore"):
        check("ovf(fp32) rounds to inf in float32", bool(np.isinf(np.float32(ovf("fp32")))) and not np.isinf(np.float32(np.nextafter(ovf("fp32"), 0))), True)
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
