#!/usr/bin/env python3
"""True-function gate library: every math kind, activation and matmul against numpy float64 (restructure spec, DV).

Extends truth.py: its references (sigmoid, selu, tanh, relu, linear, requant_true, add_true), word codecs and narrow_ref are reused;
every pass rule is written here, on this module's constants, so a changed constant changes every gate that uses it.
Floats: |hw - t| <= max(REL |t|, F_FLOOR), the floor at every |t|; a true value past the format's max passes only as max or Inf of its
sign; NaN true needs NaN, Inf true needs the same Inf. A subnormal input reads as zero.
Accumulation (acc_add, horner, matmul): |hw - t| <= max(REL sum|terms|, F_FLOOR); int32 sums are exact modulo 2^32.
int8 quantized outputs, the same rule on decoded values: hw = s_out (q - zp_out) against t, the true value clamped to the output's range
(as max or Inf is for floats); |hw - t| <= max(REL |t|, I8_FLOOR output steps), the floor at every |t|. int8Requantizer and int8QuantizedAdder
take the same rule in output codes on the real scales (truth.requant_true, truth.add_true), never on the encoders' words.
Exact kinds: narrow (round to nearest even), widen, the identities, cmp (as the max it selects), drop.
"""
import argparse
import os
import sys
from collections import namedtuple

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ipu  # noqa: E402
import truth  # noqa: E402

REL = 0.01  # the target every gate holds
ACT_BOUND = 0.10  # activations: the waiver in force (Soham, 2026-10-11); every run reports the worst against REL too
F_FLOOR = 2.0 ** -126  # floats: an output within it of the true value passes, at every |t|
I8_FLOOR = 1  # int8: within one output step passes at every |t|
MIN_NORMAL = 2.0 ** -126  # the formats' smallest normal: a smaller input reads as zero (a format property, not a gate bound)
FMAX = {"fp32": float(np.finfo(np.float32).max), "bf16": (2.0 - 2.0 ** -7) * 2.0 ** 127}
FLOATS = ("fp32", "bf16")
FORMATS = FLOATS + ("int8",)
KINDS = ("mul", "add", "mul_acc", "acc_add", "narrow", "widen", "requantize", "quantized_add", "cmp", "relu", "scale", "drop", "horner")
FIRST = 8  # misses listed in a result

Check = namedtuple("Check", "ok kind fmt n miss worst at over_target skipped first ok_el")


# ── words and values ──

def decode(fmt, w):
    """fp32 or bf16 bit patterns as float64, exactly (subnormals kept)."""
    return truth.decode(fmt, w)


def encode(fmt, v):
    """float64 values as fp32 or bf16 words, rounded to nearest even."""
    return truth.encode(fmt, v)


def ftz(x):
    """A subnormal reads as a zero of its sign."""
    x = np.asarray(x, dtype=np.float64)
    return np.where(np.abs(x) < MIN_NORMAL, np.copysign(0.0, x), x)


def sign_extend(w, bits):
    """The low bits of w as a signed integer (int64)."""
    return ipu.sx(np.asarray(w, dtype=np.int64), bits)


# ── the pass rules (per element: ok, error) ──

def float_rule(t, o, fmax, bound=None):
    """(ok, e): |o - t| <= max(bound |t|, F_FLOOR); e is |o - t| / |t|, 0 where the floor or the overflow rule passes, inf where a rule
    fails outright."""
    bound = REL if bound is None else bound
    t, o = np.broadcast_arrays(np.asarray(t, dtype=np.float64), np.asarray(o, dtype=np.float64))
    with np.errstate(invalid="ignore", divide="ignore", over="ignore"):
        tn, ti = np.isnan(t), np.isinf(t)
        big = ~tn & ~ti & (np.abs(t) > fmax)
        top = ~np.isnan(o) & ((np.abs(o) == fmax) | np.isinf(o)) & (np.signbit(o) == np.signbit(t))
        floor = np.isfinite(o) & (np.abs(o - t) <= F_FLOOR)  # within 2^-126 of t: the floor, at every |t|
        rel = np.where(t != 0, np.abs(o - t) / np.abs(t), np.inf)
        rel = np.where(np.isfinite(o), rel, np.inf)
        e = np.where(floor, 0.0, rel)
        e = np.where(big, np.where(top, 0.0, np.inf), e)
        e = np.where(ti, np.where(o == t, 0.0, np.inf), e)
        e = np.where(tn, np.where(np.isnan(o), 0.0, np.inf), e)
    return e <= bound, e


def acc_rule(t, o, scale, fmax):
    """(ok, e): |o - t| <= max(REL scale, F_FLOOR); e = |o - t| / scale; NaN, Inf and overflow as float_rule."""
    t, o, scale = np.broadcast_arrays(*(np.asarray(v, dtype=np.float64) for v in (t, o, scale)))
    with np.errstate(invalid="ignore", divide="ignore", over="ignore"):
        tn, ti = np.isnan(t), np.isinf(t)
        big = ~tn & ~ti & (np.abs(t) > fmax)
        top = ~np.isnan(o) & ((np.abs(o) == fmax) | np.isinf(o)) & (np.signbit(o) == np.signbit(t))
        err = np.abs(o - t)
        ok = np.isfinite(o) & (err <= np.maximum(REL * scale, F_FLOOR))
        e = np.where(err <= F_FLOOR, 0.0, np.where(scale > 0, err / scale, np.inf))  # a pass on the floor reports 0, as float_rule's
        e = np.where(np.isfinite(o), e, np.inf)
        ok = np.where(big, top, ok)
        ok = np.where(ti, o == t, ok)
        ok = np.where(tn, np.isnan(o), ok)
        e = np.where(big | ti | tn, np.where(ok, 0.0, np.inf), e)
    return ok, e


def exact_rule(want, got, nan_equal=True):
    """(ok, e): values equal (NaN matches NaN when nan_equal); e = |got - want|."""
    want, got = np.broadcast_arrays(np.asarray(want, dtype=np.float64), np.asarray(got, dtype=np.float64))
    with np.errstate(invalid="ignore"):
        ok = (want == got) | (nan_equal & np.isnan(want) & np.isnan(got))
        e = np.where(ok, 0.0, np.abs(got - want))
    return ok, np.where(np.isnan(e), np.inf, e)


def _result(kind, fmt, ok, e, inputs, out, skipped=0, over_target=None) -> Check:
    ok, e = np.asarray(ok, dtype=bool).ravel(), np.asarray(e, dtype=np.float64).ravel()
    if ok.size == 0:
        raise ValueError(f"{kind} {fmt}: no inputs")
    miss = np.flatnonzero(~ok)
    i = int(np.argmax(np.where(np.isnan(e), np.inf, e)))
    cols = [np.asarray(c).ravel() for c in inputs] + [np.asarray(out).ravel()]
    show = lambda k: (int(k),) + tuple(c[k].item() for c in cols)
    ot = int(miss.size) if over_target is None else int(over_target)
    return Check(miss.size == 0, kind, fmt, int(ok.size), int(miss.size), float(e[i]), show(i), ot, int(skipped), [show(k) for k in miss[:FIRST]], ok)


def _fmt_ok(fmt):
    if fmt not in FORMATS:
        raise ValueError(f"{fmt}: not one of {', '.join(FORMATS)}")


def quiet_op(f, *v):
    """f on float64 operands with NaN, Inf and overflow quiet (the rules judge them)."""
    with np.errstate(invalid="ignore", over="ignore"):
        return f(*v)


def int_value(w, bits):
    return sign_extend(w, bits).astype(np.float64)


# ── one checker per kind; words in, a Check out ──

def check_mul(fmt, a, b, y, w=None):
    """Lane multiply: floats t = a b (fmt words); int8 the exact signed product of w-bit codes (w = 8 by default), y 2w bits."""
    _fmt_ok(fmt)
    if fmt in FLOATS:
        t = quiet_op(np.multiply, ftz(decode(fmt, a)), ftz(decode(fmt, b)))
        ok, e = float_rule(t, decode(fmt, y), FMAX[fmt])
    else:
        w = 8 if w is None else w
        ok, e = exact_rule(int_value(a, w) * int_value(b, w), int_value(y, 2 * w))
    return _result("mul", fmt, ok, e, (a, b), y)


def check_add(fmt, a, b, y):
    """Lane add: floats t = a + b (fmt words); int8 has no lane add (fmt_add is int32Adder, check_acc_add)."""
    if fmt not in FLOATS:
        raise ValueError("add: floats only (int8 has no lane add)")
    t = quiet_op(np.add, ftz(decode(fmt, a)), ftz(decode(fmt, b)))
    ok, e = float_rule(t, decode(fmt, y), FMAX[fmt])
    return _result("add", fmt, ok, e, (a, b), y)


def check_mul_acc(fmt, a, b, p):
    """Mesh product: fmt operands, an fp32 product in floats (bf16's is exact), the exact int32 product in int8."""
    _fmt_ok(fmt)
    if fmt in FLOATS:
        t = quiet_op(np.multiply, ftz(decode(fmt, a)), ftz(decode(fmt, b)))
        ok, e = float_rule(t, decode("fp32", p), FMAX["fp32"])
    else:
        ok, e = exact_rule(int_value(a, 8) * int_value(b, 8), int_value(p, 32))
    return _result("mul_acc", fmt, ok, e, (a, b), p)


def check_acc_add(fmt, a, b, s):
    """Accumulator add: fp32 words in floats, within max(REL (|a| + |b|), F_FLOOR); int8 int32 words, exact modulo 2^32."""
    _fmt_ok(fmt)
    if fmt in FLOATS:
        va, vb = ftz(decode("fp32", a)), ftz(decode("fp32", b))
        ok, e = acc_rule(quiet_op(np.add, va, vb), decode("fp32", s), quiet_op(np.add, np.abs(va), np.abs(vb)), FMAX["fp32"])
    else:
        ok, e = exact_rule(int_value(sign_extend(a, 32) + sign_extend(b, 32), 32), int_value(s, 32))
    return _result("acc_add", fmt, ok, e, (a, b), s)


def check_narrow(fmt, x, y):
    """Mesh result word: bf16 the round-to-nearest-even bf16 of the fp32 sum (a subnormal reads as zero); fp32 and int8 x itself."""
    _fmt_ok(fmt)
    x, y = np.asarray(x, dtype=np.int64), np.asarray(y, dtype=np.int64)
    if fmt == "bf16":
        ok, e = exact_rule(decode("bf16", truth.narrow_ref("bf16", x)), decode("bf16", y))
    else:
        ok, e = exact_rule(x & 0xFFFFFFFF, y & 0xFFFFFFFF)
    return _result("narrow", fmt, ok, e, (x,), y)


def check_widen(fmt, x, y):
    """Bias in: bf16 the fp32 word of the same value; fp32 and int8 x itself (32-bit words)."""
    _fmt_ok(fmt)
    if fmt == "bf16":
        ok, e = exact_rule(decode("bf16", x), decode("fp32", y))
    else:
        ok, e = exact_rule(np.asarray(x, dtype=np.int64) & 0xFFFFFFFF, np.asarray(y, dtype=np.int64) & 0xFFFFFFFF)
    return _result("widen", fmt, ok, e, (x,), y)


def code_rule(tc, zp, q):
    """(ok, e) of int8 codes q against true codes tc (float64, clamped to the output range): |q - tc| <= max(REL |tc - zp|, I8_FLOOR), in
    output steps; e is |q - tc| / |tc - zp|, 0 within the floor."""
    tc = np.asarray(tc, dtype=np.float64)
    zp, q = np.broadcast_to(np.asarray(zp, dtype=np.float64), tc.shape), np.broadcast_to(np.asarray(q, dtype=np.float64), tc.shape)
    dev, tz = np.abs(q - tc), np.abs(tc - zp)
    ok = dev <= np.maximum(REL * tz, I8_FLOOR)
    with np.errstate(divide="ignore", invalid="ignore"):
        e = np.where(dev <= I8_FLOOR, 0.0, np.where(tz > 0, dev / tz, np.inf))
    return ok, e


def _int8_only(kind, fmt):
    _fmt_ok(fmt)
    if fmt != "int8":
        raise ValueError(f"{kind}: an int8 unit (int8 builds only)")


def check_requantize(fmt, acc, q, s, zp, lo, hi):
    """int8Requantizer: codes q against the true requantized value of int32 acc at the real scale s (truth.requant_true: acc s + zp clamped
    to [lo, hi]), by code_rule."""
    _int8_only("requantize", fmt)
    tc = truth.requant_true(acc, s, zp, lo, hi)
    ok, e = code_rule(tc, int_value(zp, 8), int_value(q, 8))
    return _result("requantize", fmt, ok, e, (np.broadcast_to(acc, tc.shape),), np.broadcast_to(q, tc.shape))


def check_quantized_add(fmt, q1, q2, y, r1, z1, r2, z2, zo, lo, hi):
    """int8QuantizedAdder: codes y against the true ADD of the real ratios r1 = s1 / s_out and r2 = s2 / s_out (truth.add_true:
    r1 (q1 - z1) + r2 (q2 - z2) + zo clamped to [lo, hi]), by code_rule."""
    _int8_only("quantized_add", fmt)
    tc = truth.add_true(q1, q2, r1, z1, r2, z2, 1.0, zo, lo, hi)
    ok, e = code_rule(tc, int_value(zo, 8), int_value(y, 8))
    return _result("quantized_add", fmt, ok, e, (np.broadcast_to(q1, tc.shape), np.broadcast_to(q2, tc.shape)), np.broadcast_to(y, tc.shape))


def check_cmp(fmt, a, b, gt):
    """a > b as the max it selects: the chosen word's value equals max(a, b) (a subnormal reads as zero); NaN inputs are not gated."""
    _fmt_ok(fmt)
    gt = np.asarray(gt, dtype=np.int64).astype(bool)
    if fmt in FLOATS:
        va, vb = ftz(decode(fmt, a)), ftz(decode(fmt, b))
        nan = np.isnan(va) | np.isnan(vb)
        ok, e = exact_rule(np.maximum(va, vb), np.where(gt, va, vb))
        ok = ok | nan
        e = np.where(nan, 0.0, e)
        skipped = int(nan.sum())
    else:
        ok, e = exact_rule((int_value(a, 8) > int_value(b, 8)).astype(np.float64), gt.astype(np.float64))
        skipped = 0
    return _result("cmp", fmt, ok, e, (a, b), gt.astype(np.int64), skipped)


def check_relu(fmt, x, y, zp=0):
    """ReLU: floats t = max(x, 0) (NaN inputs not gated); int8 max(q, zp) on signed codes, exactly (zp is the code of 0.0)."""
    _fmt_ok(fmt)
    if fmt in FLOATS:
        v = ftz(decode(fmt, x))
        nan = np.isnan(v)
        ok, e = float_rule(np.maximum(v, 0.0), decode(fmt, y), FMAX[fmt])
        return _result("relu", fmt, ok | nan, np.where(nan, 0.0, e), (x,), y, int(nan.sum()))
    ok, e = exact_rule(np.maximum(int_value(x, 8), int_value(zp, 8)), int_value(y, 8))
    return _result("relu", fmt, ok, e, (x,), y)


def check_scale(fmt, x, y):
    """Dropout keep: floats t = 2 x; int8 x itself."""
    _fmt_ok(fmt)
    if fmt in FLOATS:
        ok, e = float_rule(quiet_op(np.multiply, 2.0, ftz(decode(fmt, x))), decode(fmt, y), FMAX[fmt])
    else:
        ok, e = exact_rule(int_value(x, 8), int_value(y, 8))
    return _result("scale", fmt, ok, e, (x,), y)


def check_drop(fmt, x, y, zp=None):
    """Dropout drop: floats t = 0 (a zero of either sign passes); int8 the zero point zp."""
    _fmt_ok(fmt)
    if fmt in FLOATS:
        ok, e = float_rule(np.zeros(np.shape(x)), decode(fmt, y), FMAX[fmt])
    else:
        ok, e = exact_rule(int_value(zp, 8) * np.ones(np.shape(x)), int_value(y, 8))
    return _result("drop", fmt, ok, e, (x,), y)


def check_horner(fmt, x, acc, c, y):
    """One Horner step y = c + x acc: floats within max(REL (|x acc| + |c|), F_FLOOR); int8 Q4.11 decoded (word / 2^11) against the true
    value clamped to 16 bits, |hw - t| <= max(REL |t|, I8_FLOOR steps of 2^-11)."""
    _fmt_ok(fmt)
    if fmt in FLOATS:
        vx, va, vc = (ftz(decode(fmt, w)) for w in (x, acc, c))
        with np.errstate(invalid="ignore", over="ignore"):
            p = vx * va
            ok, e = acc_rule(vc + p, decode(fmt, y), np.abs(p) + np.abs(vc), FMAX[fmt])  # quiet: errstate above
    else:
        T = sign_extend(x, 16) * sign_extend(acc, 16) + sign_extend(c, 16) * 2048  # 2^11 times the true value, exact
        T = np.clip(T, -32768 * 2048, 32767 * 2048)
        dev = np.abs(sign_extend(y, 16) * 2048 - T)  # |hw - t| in units of 2^-22: exact
        floor = dev <= I8_FLOOR * 2048  # within one step of 2^-11, at every |t|
        ok = floor | (dev <= REL * np.abs(T))
        with np.errstate(divide="ignore", invalid="ignore"):
            e = np.where(floor, 0.0, np.where(T != 0, dev / np.abs(T), np.inf))
    return _result("horner", fmt, ok, e, (x, acc, c), y)


CHECKERS = {"mul": check_mul, "add": check_add, "mul_acc": check_mul_acc, "acc_add": check_acc_add, "narrow": check_narrow,
            "widen": check_widen, "requantize": check_requantize, "quantized_add": check_quantized_add, "cmp": check_cmp, "relu": check_relu,
            "scale": check_scale, "drop": check_drop, "horner": check_horner}


# ── activations and matmul ──

def check_activation(fmt, func, x, y, quant=None, bound=None) -> Check:
    """An activation lane: floats take words, int8 codes with quant = (s_in, z_in, s_out, z_out) as the test's float32 scales.
    Passes at bound (ACT_BOUND, the waiver); over_target counts the outputs past REL."""
    _fmt_ok(fmt)
    bound = ACT_BOUND if bound is None else bound
    if func not in truth.REFS:
        raise ValueError(f"{func}: not one of {', '.join(truth.FUNCS)}")
    if fmt in FLOATS:
        v = ftz(decode(fmt, x))
        if np.isnan(v).any():
            raise ValueError("NaN inputs are not gated")
        _, e = float_rule(truth.ref(func, v), decode(fmt, y), FMAX[fmt])
    else:
        if quant is None:
            raise ValueError("int8 needs quant = (s_in, z_in, s_out, z_out)")
        q, o = (sign_extend(w, 8).astype(np.float64) for w in (x, y))
        s_in, z_in, s_out, z_out = (np.broadcast_to(np.asarray(v, dtype=np.float64), q.shape) for v in quant)
        with np.errstate(divide="ignore", invalid="ignore", over="ignore"):
            t = truth.ref(func, s_in * (q - z_in))
            tc = np.clip(t, s_out * (-128.0 - z_out), s_out * (127.0 - z_out))  # the output's range, as max or Inf is for floats
            hw = s_out * (o - z_out)  # the decoded output
            err = np.abs(hw - tc)
            floor = err <= I8_FLOOR * s_out  # within one output step: the floor, at every |t|
            e = np.where(floor, 0.0, np.where(tc != 0, err / np.abs(tc), np.inf))
            zero_mult = np.isinf(s_out)  # s_out = Inf: a zero multiplier, every code is the zero point
            e = np.where(zero_mult, np.where(o == z_out, 0.0, np.inf), e)
        e = np.where(np.isnan(e), np.inf, e)
    ok = e <= bound
    return _result(func, fmt, ok, e, (x,), y, over_target=int((e > REL).sum()))


def check_matmul(fmt, passes, out, bias=None) -> Check:
    """Mesh sums: floats within max(REL sum|ab|, F_FLOOR) of sum over passes of A @ B plus the bias row (Soham, 2026-10-11: the
    bias is not in the scale); int8 int32 sums exact modulo 2^32 (two's-complement int32 accumulation)."""
    _fmt_ok(fmt)
    val = (lambda w: ftz(decode(fmt, w))) if fmt in FLOATS else (lambda w: int_value(w, 8))
    t = s = 0.0
    for A, B in passes:
        A, B = val(A), val(B)
        t, s = t + A @ B, s + np.abs(A) @ np.abs(B)
    t, s = np.asarray(t, dtype=np.float64), np.asarray(s, dtype=np.float64)
    if fmt in FLOATS:
        if bias is not None:
            t = t + ftz(decode("fp32", bias))[None, :]
        o = decode("fp32", out).reshape(t.shape)
        ok, e = acc_rule(t, o, s, FMAX["fp32"])
    else:
        if bias is not None:
            t = t + int_value(bias, 32)[None, :]
        o = int_value(out, 32).reshape(t.shape)
        err = np.abs(np.mod(o - t + 2.0**31, 2.0**32) - 2.0**31)
        ok, e = err == 0, err
    return _result("matmul", fmt, ok, e, (t,), o)


def line(r: Check) -> str:
    """One report line."""
    w = f"{100 * r.worst:.4g}%" if np.isfinite(r.worst) else "unbounded"
    lsb = ""  # every worst is relative now, a decoded value against t
    skip = f"  not gated (NaN operands) {r.skipped}" if r.skipped else ""
    return (f"TRUEFN {r.kind} {r.fmt}: {'PASS' if r.ok else 'FAIL'}  n {r.n}  miss {r.miss}  worst {w}{lsb} at {r.at}  "
            f"over {100 * REL:g}%: {r.over_target}{skip}")


# ── the C harness's samples, judged again here ──

def recheck(path):
    """(rows, disagreements) between the sweep harness's verdicts and these checkers on its sample file."""
    rows = [ln.split() for ln in open(path) if ln.strip() and not ln.startswith("#")]
    if not rows:
        raise ValueError(f"{path}: no rows")
    kind, fmt = rows[0][0], rows[0][1]
    a, b, c, y, ok, w = (np.array([int(r[i], 0) for r in rows], dtype=np.int64) for i in range(2, 8))
    P = np.array([[int(v, 0) for v in r[8:19]] for r in rows], dtype=np.int64)
    if kind in ("mul", "mul_acc", "acc_add", "cmp", "add"):
        got = CHECKERS[kind](fmt, a, b, y, w=int(w[0])) if kind == "mul" else CHECKERS[kind](fmt, a, b, y)
    elif kind in ("narrow", "widen", "scale"):
        got = CHECKERS[kind](fmt, a, y)
    elif kind == "relu":
        got = check_relu(fmt, a, y, zp=b)
    elif kind == "drop":
        got = check_drop(fmt, a, y, zp=b)
    elif kind == "horner":
        got = check_horner(fmt, a, b, c, y)
    elif kind == "requantize":  # P: bits(s), m, e, zp, lo, hi
        got = check_requantize(fmt, sign_extend(a, 32), y, P[:, 0].view(np.float64), P[:, 3], P[:, 4], P[:, 5])
    elif kind == "quantized_add":  # P: bits(r1), bits(r2), m1, m2, e, z1, z2, zo, lo, hi
        got = check_quantized_add(fmt, sign_extend(a, 8), sign_extend(b, 8), y, P[:, 0].view(np.float64), P[:, 5], P[:, 1].view(np.float64),
                                  P[:, 6], P[:, 7], P[:, 8], P[:, 9])
    else:
        raise ValueError(f"{kind}: no checker")
    return kind, fmt, len(rows), int((got.ok_el != ok.astype(bool)).sum()), int((~ok.astype(bool)).sum())


# ── selftest: every rule passing and failing at its edges ──

def selftest() -> int:
    fails, checks = [0], [0]

    def check(what, got, want):
        checks[0] += 1
        if got != want:
            fails[0] += 1
            print(f"[FAIL] {what}: got {got}, want {want}")

    bf = lambda v: int(encode("bf16", v))
    f3 = lambda v: int(encode("fp32", v))
    one = lambda kind, fmt, *args, **kw: CHECKERS[kind](fmt, *(np.atleast_1d(np.asarray(x, dtype=np.int64)) for x in args), **kw).ok
    # floats: the 1% bound, both sides of it (a REL of 2% lets the 1.5% case pass)
    t = 1.5 * 1.25
    check("fp32 mul exact", one("mul", "fp32", f3(1.5), f3(1.25), f3(t)), True)
    check("fp32 mul 0.9% off", one("mul", "fp32", f3(1.5), f3(1.25), f3(t * 1.009)), True)
    check("fp32 mul 1.5% off", one("mul", "fp32", f3(1.5), f3(1.25), f3(t * 1.015)), False)
    check("fp32 mul 1.1% low", one("mul", "fp32", f3(1.5), f3(1.25), f3(t * 0.989)), False)
    check("bf16 mul one ULP low (truncation, 0.39%)", one("mul", "bf16", bf(1.5), bf(1.25), bf(t) - 1), True)
    check("bf16 mul 1.5% off", one("mul", "bf16", bf(1.5), bf(1.25), bf(t * 1.015)), False)
    check("bf16 add 1.5% off", one("add", "bf16", bf(1.0), bf(0.5), bf(1.5 * 1.015)), False)
    check("bf16 add exact", one("add", "bf16", bf(1.0), bf(0.5), bf(1.5)), True)
    check("bf16 mul_acc exact fp32 product", one("mul_acc", "bf16", bf(1.5), bf(1.25), f3(t)), True)
    check("bf16 mul_acc 1.5% off", one("mul_acc", "bf16", bf(1.5), bf(1.25), f3(t * 1.015)), False)
    # floats: the floor, 2^-126 exactly at both ends
    tiny = 2.0 ** -70
    check("fp32 mul true 2^-140, out 0", one("mul", "fp32", f3(tiny), f3(2.0 ** -70), 0), True)
    check("fp32 mul true 2^-140, out 2^-126", one("mul", "fp32", f3(tiny), f3(2.0 ** -70), 0x00800000), True)
    check("fp32 mul true 2^-140, out next above 2^-126 (within 2^-126 of t: the floor)", one("mul", "fp32", f3(tiny), f3(2.0 ** -70), 0x00800001), True)
    check("fp32 mul true 2^-140, out 2^-125 (beyond the floor)", one("mul", "fp32", f3(tiny), f3(2.0 ** -70), 0x01000000), False)
    check("fp32 mul true 2^-126 (normal), out 0", one("mul", "fp32", f3(2.0 ** -63), f3(2.0 ** -63), 0), True)
    check("fp32 mul true 2^-125, out 0", one("mul", "fp32", f3(2.0 ** -62), f3(2.0 ** -63), 0), False)
    check("bf16 mul true 1.5 x 2^-126, out 2^-126 (0.5 x 2^-126 off: the floor)", one("mul", "bf16", bf(2.0 ** -63), bf(1.5 * 2.0 ** -63), 0x0080), True)
    check("bf16 mul true 1.5 x 2^-126, out 0 (1.5 x 2^-126 off)", one("mul", "bf16", bf(2.0 ** -63), bf(1.5 * 2.0 ** -63), 0), False)
    check("bf16 widen subnormal kept", one("widen", "bf16", 0x0001, 0x00010000), True)
    # a subnormal input reads as zero
    check("fp32 mul subnormal x 2^100: 0", one("mul", "fp32", 0x00400000, f3(2.0 ** 100), 0), True)
    check("fp32 mul subnormal x 2^100: 2^-27 fails", one("mul", "fp32", 0x00400000, f3(2.0 ** 100), f3(2.0 ** -27)), False)
    check("fp32 mul 2^-126 (normal) x 2^100 needs 2^-26", one("mul", "fp32", 0x00800000, f3(2.0 ** 100), 0), False)
    # NaN, Inf and overflow
    check("bf16 mul NaN in, NaN out", one("mul", "bf16", 0x7FC0, bf(1.0), 0x7FC0), True)
    check("bf16 mul NaN in, 1.0 out", one("mul", "bf16", 0x7FC0, bf(1.0), bf(1.0)), False)
    check("bf16 mul 0 x Inf: NaN", one("mul", "bf16", 0, 0x7F80, 0x7FC0), True)
    check("bf16 mul 0 x Inf: 0 fails", one("mul", "bf16", 0, 0x7F80, 0), False)
    check("bf16 mul Inf x -1: -Inf", one("mul", "bf16", 0x7F80, bf(-1.0), 0xFF80), True)
    check("bf16 mul Inf x -1: +Inf fails", one("mul", "bf16", 0x7F80, bf(-1.0), 0x7F80), False)
    check("bf16 mul max x 2: +Inf", one("mul", "bf16", 0x7F7F, bf(2.0), 0x7F80), True)
    check("bf16 mul max x 2: max", one("mul", "bf16", 0x7F7F, bf(2.0), 0x7F7F), True)
    check("bf16 mul max x 2: -Inf fails", one("mul", "bf16", 0x7F7F, bf(2.0), 0xFF80), False)
    check("bf16 mul max x 2: below max fails", one("mul", "bf16", 0x7F7F, bf(2.0), 0x7F7E), False)
    check("bf16 mul 1 x 1: Inf fails", one("mul", "bf16", bf(1.0), bf(1.0), 0x7F80), False)
    check("bf16 add Inf - Inf: NaN", one("add", "bf16", 0x7F80, 0xFF80, 0x7FC0), True)
    check("bf16 mul NaN out of 1 x 1: worst unbounded", check_mul("bf16", np.array([bf(1.0)]), np.array([bf(1.0)]), np.array([0x7FC0])).worst, np.inf)
    # accumulation: |err| <= max(1% (|a| + |b|), 2^-126)
    check("fp32 acc_add cancellation within 1% of |a| + |b|", one("acc_add", "fp32", f3(1.0), f3(-0.999), f3(0.001 + 0.019)), True)
    check("fp32 acc_add cancellation over it", one("acc_add", "fp32", f3(1.0), f3(-0.999), f3(0.001 + 0.021)), False)
    check("fp32 acc_add zeros, out 2^-126", one("acc_add", "fp32", 0, 0, 0x00800000), True)
    check("fp32 acc_add zeros, out next above", one("acc_add", "fp32", 0, 0, 0x00800001), False)
    r = check_acc_add("fp32", np.array([0x80800000]), np.array([0x00FFFFFF]), np.array([0]))  # t just below 2^-126, flushed: a floor pass
    check("fp32 acc_add floor pass reports worst 0, not err / (|a| + |b|) = 1/3", (r.ok, r.worst), (True, 0.0))
    check("fp32 acc_add max + max: Inf", one("acc_add", "fp32", 0x7F7FFFFF, 0x7F7FFFFF, 0x7F800000), True)
    check("fp32 acc_add max + max: max", one("acc_add", "fp32", 0x7F7FFFFF, 0x7F7FFFFF, 0x7F7FFFFF), True)
    check("fp32 acc_add max + max: 2^127 fails", one("acc_add", "fp32", 0x7F7FFFFF, 0x7F7FFFFF, 0x7F000000), False)
    check("fp32 acc_add NaN out of finite fails", one("acc_add", "fp32", f3(1.0), f3(1.0), 0x7FC00000), False)
    check("bf16 horner 1 + 2 x 3", one("horner", "bf16", bf(2.0), bf(3.0), bf(1.0), bf(7.0)), True)
    check("bf16 horner cancellation 1.5% of scale off", one("horner", "bf16", bf(2.0), bf(3.0), bf(-6.0), bf(0.18)), False)
    check("bf16 horner cancellation 0.9% of scale off", one("horner", "bf16", bf(2.0), bf(3.0), bf(-6.0), bf(0.1)), True)
    # int8 and int32: exact
    check("int8 mul_acc -128 x -128 = 16384", one("mul_acc", "int8", 0x80, 0x80, 16384), True)
    check("int8 mul_acc one off", one("mul_acc", "int8", 0x80, 0x80, 16385), False)
    check("int8 mul_acc words sign-extended", one("mul_acc", "int8", 0xFF, 0x02, 0xFFFFFFFE), True)
    check("int8 mul -128 x 127 (16-bit product)", one("mul", "int8", 0x80, 0x7F, (-16256) & 0xFFFF), True)
    check("int8 mul at w = 24", one("mul", "int8", 0x800000, 0x000002, (-(2**24)) & ((1 << 48) - 1), w=24), True)
    check("int8 acc_add wraps", one("acc_add", "int8", 0x7FFFFFFF, 1, 0x80000000), True)
    check("int8 acc_add saturated fails", one("acc_add", "int8", 0x7FFFFFFF, 1, 0x7FFFFFFF), False)
    # int8 horner: Q4.11 within 1 LSB of the unrounded value
    check("int8 horner 0.5 x 0.5 + 0.25 = 0.5", one("horner", "int8", 1024, 1024, 512, 1024), True)
    check("int8 horner one step low (0.1%)", one("horner", "int8", 1024, 1024, 512, 1023), True)
    check("int8 horner 1.5% low", one("horner", "int8", 1024, 1024, 512, 1009), False)
    check("int8 horner t 3 steps, out 2 (one step: the floor)", one("horner", "int8", 3, 2048, 0, 2), True)
    check("int8 horner t 3 steps, out 1 (2 steps)", one("horner", "int8", 3, 2048, 0, 1), False)
    check("int8 horner floor: 3 x 3 / 2^11 = 0.0044, out 0", one("horner", "int8", 3, 3, 0, 0), True)
    check("int8 horner saturates to 32767", one("horner", "int8", 32767, 32767, 32767, 32767), True)
    check("int8 horner wrapped fails", one("horner", "int8", 32767, 32767, 32767, 0x8000), False)
    # requantize, the decimal rule in output steps: t = clamp(acc s + zp, lo, hi) on the real scale s; |q - t| <= max(1% |t - zp|, one step),
    # the floor at every |t| (Soham's "1% with a floor of 1 LSB")
    rq = lambda acc, q, ok, s=0.5, zp=0, lo=-128, hi=127: check(f"requantize {acc} at {s} -> {q}", one("requantize", "int8", acc, q, s=s, zp=zp,
                                                                                                         lo=lo, hi=hi), ok)
    rq(100, 50, True)  # t = 50: exact
    rq(100, 51, True)  # one step from t = 50: the floor
    rq(101, 49, False)  # t = 50.5: 1.5 steps
    rq(257, 63, False, s=0.25)  # t = 64.25: 1.25 steps, 1.9%
    rq(501, 124, True, s=0.25)  # t = 125.25: 1.25 steps, 0.998%
    rq(501, 123, False, s=0.25)  # 2.25 steps, 1.8%
    rq(250, 126, True)  # t = 125: 1 step, 0.8%
    rq(254, 125, False)  # t = 127: 2 steps, 1.6%
    rq(1000, 127, True)  # clamped: t = 127
    rq(-1000, 3, True, zp=3, lo=3)  # ReLU clamp at zp 3: t = 0
    rq(100, 57, True, zp=7)  # t = 50 above zp 7
    rq(100, 50, False, zp=7)
    rq(100, 6, True, s=1 / 16)  # t = 6.25: the best code, 0.25 steps
    rq(100, 8, False, s=1 / 16)  # 1.75 steps, 28%
    rq(1, 0, True)  # t = 0.5, below one step: within one step
    rq(1, 1, True)
    rq(1, 2, False)  # 1.5 steps
    rq(21, 11, True)  # t = 10.5: the best code, half a step
    rq(21, 9, False)  # 1.5 steps, 14%
    rq(-2**31, -128, True, s=2.0**-20)  # acc s = -2048: clamps to -128 (lane C's wrap example, now in range of the rule)
    rq(-2**31, 127, False, s=2.0**-20)
    rq(3, 1, True, s=0.33)  # t = 0.99 on the real scale
    rq(10, 127, False, s=0.58, zp=120)  # t = 125.8, 5.8 steps above zp: 1.2 steps off is past one step (1% of |t| itself would pass it)
    try:
        check_requantize("fp32", np.array([1]), np.array([0]), 0.5, 0, -128, 127)
        check("requantize in fp32 raises", "accepted", "raised")
    except ValueError:
        check("requantize in fp32 raises", True, True)
    # the ADD, the same rule: t = r1 (q1 - z1) + r2 (q2 - z2) + zo clamped, on the real ratios
    qa = lambda q1, q2, y, ok, r1=0.5, r2=0.25, z1=3, z2=-4, zo=1, lo=-128, hi=127: check(
        f"quantized_add {q1} + {q2} -> {y}", one("quantized_add", "int8", q1, q2, y, r1=r1, z1=z1, r2=r2, z2=z2, zo=zo, lo=lo, hi=hi), ok)
    qa(13, 4, 8, True)  # 0.5 x 10 + 0.25 x 8 + 1 = 8
    qa(13, 4, 9, True)  # one step
    qa(13, 4, 10, False)  # two steps from t = 7 above zo
    qa(13, 4, 5, True, hi=5)  # clamped to hi
    qa(13, 4, 7, False, hi=5)
    qa(13, 4, 4, False, zo=-5)  # zo -5: t = 2, 7 steps above zo; out 4 is 2 steps off
    qa(13, -4, 127, False, r1=0.58, zo=120)  # t = 125.8, 5.8 steps above zo: 1.2 steps off fails (1% of |t| itself would pass it)
    p1, p2, sh = ipu.encode_add(0.05 / 0.1, 0.08 / 0.1)
    q1, q2 = np.meshgrid(np.arange(-128, 128), np.arange(-128, 128))
    q1, q2 = q1.ravel(), q2.ravel()
    hw = ipu.qadd(q1, q2, 3, -4, p1, p2, sh, 1, -128, 127)
    r = check_quantized_add("int8", q1, q2, hw & 0xFF, 0.5, 3, 0.8, -4, 1, -128, 127)
    check("quantized_add: int8QuantizedAdder's model passes on every pair", (r.ok, r.n), (True, 65536))
    k = int(np.flatnonzero((np.abs(hw - 1) > 20) & (np.abs(hw) < 100))[0])
    bad = hw.copy()
    bad[k] += 3
    check("quantized_add: three codes off at |t| > 20 steps fails once", check_quantized_add("int8", q1, q2, bad & 0xFF, 0.5, 3, 0.8, -4, 1, -128, 127).miss, 1)
    # narrow: round to nearest even, exactly (truncation fails though it is under 1%)
    check("bf16 narrow tie to even", one("narrow", "bf16", 0x3F818000, 0x3F82), True)
    check("bf16 narrow truncated", one("narrow", "bf16", 0x3F818000, 0x3F81), False)
    check("bf16 narrow above half truncated", one("narrow", "bf16", 0x3F80C000, 0x3F80), False)
    check("bf16 narrow subnormal to 0", one("narrow", "bf16", 0x00400000, 0), True)
    check("bf16 narrow past max to Inf", one("narrow", "bf16", 0x7F7F8000, 0x7F80), True)
    check("bf16 widen exact", one("widen", "bf16", 0x3F81, 0x3F810000), True)
    check("bf16 widen low bit set fails", one("widen", "bf16", 0x3F81, 0x3F810001), False)
    # cmp as the max it selects
    check("bf16 cmp 2 > 1", one("cmp", "bf16", bf(2.0), bf(1.0), 1), True)
    check("bf16 cmp 2 > 1 wrong", one("cmp", "bf16", bf(2.0), bf(1.0), 0), False)
    check("bf16 cmp -2 > -1 wrong", one("cmp", "bf16", bf(-2.0), bf(-1.0), 1), False)
    check("bf16 cmp +0, -0 either", (one("cmp", "bf16", 0, 0x8000, 0), one("cmp", "bf16", 0, 0x8000, 1)), (True, True))
    check("bf16 cmp subnormal vs 0 either", (one("cmp", "bf16", 1, 0, 1), one("cmp", "bf16", 1, 0, 0)), (True, True))
    check("bf16 cmp NaN not gated", CHECKERS["cmp"]("bf16", np.array([0x7FC0]), np.array([0]), np.array([0])).skipped, 1)
    check("int8 cmp -1 > -128", one("cmp", "int8", 0xFF, 0x80, 1), True)
    check("int8 cmp unsigned compare fails", one("cmp", "int8", 0xFF, 0x01, 1), False)
    # relu, scale, drop
    check("bf16 relu -3 -> 0", one("relu", "bf16", bf(-3.0), 0), True)
    check("bf16 relu -3 -> -3 fails", one("relu", "bf16", bf(-3.0), bf(-3.0)), False)
    check("bf16 relu -0 -> 0", one("relu", "bf16", 0x8000, 0), True)
    check("int8 relu max(q, zp): q below zp", one("relu", "int8", 0x80, 0xF9, zp=-7), True)
    check("int8 relu max(q, zp): q passed below zp fails", one("relu", "int8", 0x80, 0x80, zp=-7), False)
    check("int8 relu max(q, zp): q above zp", one("relu", "int8", 0x05, 0x05, zp=-7), True)
    check("int8 relu signed: 0x80 is -128, below zp 3", one("relu", "int8", 0x80, 0x03, zp=3), True)
    check("bf16 scale 3 -> 6", one("scale", "bf16", bf(3.0), bf(6.0)), True)
    check("bf16 scale 3 -> 3 fails", one("scale", "bf16", bf(3.0), bf(3.0)), False)
    check("bf16 scale max -> Inf", one("scale", "bf16", 0x7F7F, 0x7F80), True)
    check("int8 scale identity", one("scale", "int8", 0x05, 0x05), True)
    check("bf16 drop -> -0", one("drop", "bf16", bf(-3.0), 0x8000), True)
    check("bf16 drop -> 2^-126", one("drop", "bf16", bf(-3.0), 0x0080), True)
    check("bf16 drop -> next above 2^-126 fails", one("drop", "bf16", bf(-3.0), 0x0081), False)
    check("int8 drop -> zp", one("drop", "int8", 0x05, 0xF9, zp=-7), True)
    check("int8 drop -> 0 with zp -7 fails", one("drop", "int8", 0x05, 0, zp=-7), False)
    # activations: the waiver and the target
    x1, t1 = bf(1.0), float(truth.sigmoid(1.0))
    act = lambda fmt, func, x, y, **kw: check_activation(fmt, func, np.atleast_1d(x), np.atleast_1d(y), **kw)
    r = act("bf16", "sigmoid", x1, bf(t1 * 1.05))
    check("bf16 sigmoid 5% off: passes the waiver, counted over 1%", (r.ok, r.over_target), (True, 1))
    check("bf16 sigmoid 11% off fails", act("bf16", "sigmoid", x1, bf(t1 * 1.11)).ok, False)
    check("bf16 sigmoid 1.5% off fails at bound REL", act("bf16", "sigmoid", x1, bf(t1 * 1.015), bound=REL).ok, False)
    check("fp32 tanh 2^-126 flushed (within 2^-126 of t: the floor)", act("fp32", "tanh", 0x00800000, 0).ok, True)
    check("fp32 tanh next above 2^-126 flushed", act("fp32", "tanh", 0x00800001, 0).ok, False)
    check("fp32 mul t = 2^-130, out just above 2^-126 (within the floor)", one("mul", "fp32", f3(2.0 ** -65), f3(2.0 ** -65), 0x00800001), True)
    check("fp32 tanh t = -2^-126, out +2^-126 (2 x 2^-126 off, both at the floor)", act("fp32", "tanh", 0x80800000, 0x00800000).ok, False)
    check("bf16 selu max subnormal reads as 0", act("bf16", "selu", 0x007F, 0).ok, True)
    # int8 activations, the decimal rule: hw = s_out (q - z_out) against t = f(s_in (q_in - z_in)) clamped to the output's range (as max
    # or Inf is for floats); |hw - t| <= max(tol |t|, s_out), the floor at every |t|
    tq = (4 / 128, 0, 1 / 128, 0)  # tanh: x = q / 32, out q / 128
    i8 = lambda q, o, quant=tq, func="tanh": act("int8", func, q, o, quant=quant).ok
    check("int8 tanh q=2 (t 7.99 steps), out 8 (0.13%)", i8(2, 8), True)
    check("int8 tanh q=2, out 9 (12.6%)", i8(2, 9), False)
    check("int8 tanh q=2, out 7 (0.99 of a step)", i8(2, 7), True)
    check("int8 tanh q=0 (t 0), out 1 (one step)", i8(0, 1), True)
    check("int8 tanh q=0, out 2", i8(0, 2), False)
    check("int8 tanh q=32 (t 0.7616), out 99 (1.6%)", i8(32, 99), True)
    check("int8 tanh q=32, out 112 (14.9%)", i8(32, 112), False)
    sq = (3.5 / 8, 0, 1 / 256, -128)
    check("int8 sigmoid q=100 (t 1.0, clamped to 255/256), out 127", i8(100, 127, sq, "sigmoid"), True)
    check("int8 linear 100 past the output range (clamped to 6.35), out 127", i8(100, 127, (1.0, 0, 0.05, 0), "linear"), True)
    check("int8 sigmoid q=-20 (t 1.6e-4, below a step), out -125 (2.96 steps)", i8(-20, -125, sq, "sigmoid"), False)
    check("int8 linear t = 2.4 steps, out 2: the best code, 0.4 of a step", i8(1, 2, (0.024, 0, 0.01, 0), "linear"), True)
    check("int8 linear t = 2.4 steps, out 4 (1.6 steps, 67%)", i8(1, 4, (0.024, 0, 0.01, 0), "linear"), False)
    check("int8 linear t = 24 steps, out 24", i8(10, 24, (0.024, 0, 0.01, 0), "linear"), True)
    check("int8 selu zero multiplier, out z_out", i8(50, 7, (0.05, 0, np.inf, 7), "selu"), True)
    check("int8 selu zero multiplier, out z_out + 2", i8(50, 9, (0.05, 0, np.inf, 7), "selu"), False)
    # matmul: max(1% of sum|ab|, 2^-126), the bias outside the scale; int8 exact modulo 2^32
    A, B = np.array([[1.0, 2.0], [3.0, -4.0]]), np.array([[0.5, -1.0], [0.25, 2.0]])
    tm = A @ B
    mm = lambda o, bias=None: check_matmul("fp32", [(encode("fp32", A), encode("fp32", B))], encode("fp32", o), bias).ok
    check("matmul exact", mm(tm), True)
    check("matmul 0.98% of 5", mm(tm + np.array([[0.0, 0.049], [0.0, 0.0]])), True)
    check("matmul 1.02% of 5", mm(tm + np.array([[0.0, 0.051], [0.0, 0.0]])), False)
    bw = encode("fp32", np.array([10.0, -20.0]))
    check("matmul bias added", mm(tm + np.array([10.0, -20.0]), bw), True)
    check("matmul bias left out", mm(tm, bw), False)
    check("matmul bias not in the scale", mm(tm + np.array([10.0, -19.9]), bw), False)
    ia, ib = np.array([[127, -128], [5, 6]]), np.array([[-128, 1], [127, 2]])
    check("matmul int8 exact", check_matmul("int8", [(ia & 0xFF, ib & 0xFF)], (ia @ ib) & 0xFFFFFFFF).ok, True)
    check("matmul int8 one off", check_matmul("int8", [(ia, ib)], (ia @ ib + np.array([[1, 0], [0, 0]])) & 0xFFFFFFFF).ok, False)
    check("matmul int8 wraps", check_matmul("int8", [(np.array([[1]]), np.array([[1]]))], np.array([0x80000000]), np.array([0x7FFFFFFF])).ok, True)
    # the result names its worst and its misses
    xs = encode("bf16", np.array([1.0, 2.0, 3.0]))
    r = check_mul("bf16", xs, xs, encode("bf16", np.array([1.0, 4.0 * 1.02, 9.0 * 1.3])))
    check("counts", (r.ok, r.n, r.miss), (False, 3, 2))
    check("worst near 30% at index 2", (abs(r.worst - 0.3) < 0.01, r.at[0]), (True, 2))
    check("first misses", [m[0] for m in r.first], [1, 2])
    check("line", line(r).startswith("TRUEFN mul bf16: FAIL  n 3  miss 2  worst 29.86% at (2, "), True)
    print(f"truefn selftest: {checks[0]} checks, {fails[0]} failures")
    print(f"RESULT: {'PASSED' if fails[0] == 0 else 'FAILED'}")
    return fails[0]


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--selftest", action="store_true", help="every rule at its edges")
    ap.add_argument("--recheck", nargs="+", metavar="SAMPLE", help="the sweep harness's sample files, judged again here")
    a = ap.parse_args()
    if a.selftest:
        sys.exit(1 if selftest() else 0)
    if a.recheck:
        bad = 0
        for p in a.recheck:
            kind, fmt, n, dis, misses = recheck(p)
            print(f"RECHECK {kind} {fmt}: {n} rows ({misses} misses in the harness's verdicts), {dis} disagreements: {os.path.basename(p)}")
            bad += dis != 0
        print(f"RESULT: {'PASSED' if bad == 0 else 'FAILED'}")
        sys.exit(1 if bad else 0)
    ap.error("nothing to do: --selftest or --recheck")


if __name__ == "__main__":
    main()
