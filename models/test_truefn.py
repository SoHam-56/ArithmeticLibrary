#!/usr/bin/env python3
"""Checks truefn.py: its selftest fails on every planted mutant, and its rules agree with truth.py's where the two libraries share one."""
import contextlib
import io
import os
import sys
import types

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import truefn  # noqa: E402
import truth  # noqa: E402

fails = checks = 0


def check(what, got, want):
    global fails, checks
    checks += 1
    if got != want:
        fails += 1
        print(f"[FAIL] {what}: got {got}, want {want}")


# Mutants of truefn.py's source: each breaks one rule, and the selftest must report failures on it.
MUTANTS = [
    ("REL 2% (a planted 1.5% error passes)", "REL = 0.01  #", "REL = 0.02  #"),
    ("float floor 2^-125", "F_FLOOR = 2.0 ** -126  #", "F_FLOOR = 2.0 ** -125  #"),
    ("float floor 2^-127", "F_FLOOR = 2.0 ** -126  #", "F_FLOOR = 2.0 ** -127  #"),
    ("int8 floor 0 steps", "I8_FLOOR = 1  #", "I8_FLOOR = 0  #"),
    ("int8 floor 2 steps", "I8_FLOOR = 1  #", "I8_FLOOR = 2  #"),
    ("activation waiver 12%", "ACT_BOUND = 0.10  #", "ACT_BOUND = 0.12  #"),
    ("subnormal inputs not read as zero", "np.where(np.abs(x) < MIN_NORMAL, np.copysign(0.0, x), x)", "x"),
    ("2^-126 read as zero", "np.abs(x) < MIN_NORMAL,", "np.abs(x) <= MIN_NORMAL,"),
    ("NaN or Inf out of a finite true value passes", "        rel = np.where(np.isfinite(o), rel, np.inf)\n", ""),
    ("overflow sign ignored", "& (np.signbit(o) == np.signbit(t))\n        floor", "\n        floor"),
    ("no overflow rule", "big = ~tn & ~ti & (np.abs(t) > fmax)\n        top = ~np.isnan(o) & ((np.abs(o) == fmax) | np.isinf(o)) & (np.signbit(o) == np.signbit(t))\n        floor",
     "big = np.zeros(t.shape, dtype=bool)\n        top = big\n        floor"),
    ("float floor as both at or below 2^-126 (the old form)", "floor = np.isfinite(o) & (np.abs(o - t) <= F_FLOOR)",
     "floor = (np.abs(t) <= F_FLOOR) & (np.abs(o) <= F_FLOOR)"),
    ("float floor dropped", "        e = np.where(floor, 0.0, rel)\n", "        e = rel\n"),
    ("NaN true value passes anything", "e = np.where(tn, np.where(np.isnan(o), 0.0, np.inf), e)", "e = np.where(tn, 0.0, e)"),
    ("Inf true value passes either sign", "e = np.where(ti, np.where(o == t, 0.0, np.inf), e)", "e = np.where(ti, np.where(np.isinf(o), 0.0, np.inf), e)"),
    ("accumulation floor dropped", "ok = np.isfinite(o) & (err <= np.maximum(REL * scale, F_FLOOR))", "ok = np.isfinite(o) & (err <= REL * scale)"),
    ("accumulation scaled by |t|", "ok = np.isfinite(o) & (err <= np.maximum(REL * scale, F_FLOOR))", "ok = np.isfinite(o) & (err <= np.maximum(REL * np.abs(t), F_FLOOR))"),
    ("int32 sums not wrapped", "exact_rule(int_value(sign_extend(a, 32) + sign_extend(b, 32), 32), int_value(s, 32))", "exact_rule((sign_extend(a, 32) + sign_extend(b, 32)).astype(np.float64), int_value(s, 32))"),
    ("int8 products unsigned", "ok, e = exact_rule(int_value(a, 8) * int_value(b, 8), int_value(p, 32))", "ok, e = exact_rule((np.asarray(a) & 0xFF) * (np.asarray(b) & 0xFF) * 1.0, int_value(p, 32))"),
    ("narrow truncates", 'exact_rule(decode("bf16", truth.narrow_ref("bf16", x)), decode("bf16", y))', 'exact_rule(decode("bf16", (x >> 16) & 0xFFFF), decode("bf16", y))'),
    ("widen drops the low bits", 'ok, e = exact_rule(decode("bf16", x), decode("fp32", y))', 'ok, e = exact_rule(decode("bf16", x), decode("fp32", y & 0xFFFF0000))'),
    ("cmp selects the min", "ok, e = exact_rule(np.maximum(va, vb), np.where(gt, va, vb))", "ok, e = exact_rule(np.minimum(va, vb), np.where(gt, va, vb))"),
    ("cmp int8 unsigned", "exact_rule((int_value(a, 8) > int_value(b, 8)).astype(np.float64)", "exact_rule(((np.asarray(a) & 0xFF) > (np.asarray(b) & 0xFF)).astype(np.float64)"),
    ("relu as identity", "float_rule(np.maximum(v, 0.0), decode(fmt, y), FMAX[fmt])", "float_rule(v, decode(fmt, y), FMAX[fmt])"),
    ("int8 relu as identity", "ok, e = exact_rule(np.maximum(int_value(x, 8), int_value(zp, 8)), int_value(y, 8))", "ok, e = exact_rule(int_value(x, 8), int_value(y, 8))"),
    ("int8 relu unsigned", "np.maximum(int_value(x, 8), int_value(zp, 8))", "np.maximum(np.asarray(x) & 0xFF, np.asarray(zp) & 0xFF) * 1.0"),
    ("scale by 1", "quiet_op(np.multiply, 2.0, ftz(decode(fmt, x)))", "quiet_op(np.multiply, 1.0, ftz(decode(fmt, x)))"),
    ("drop ignores zp", "exact_rule(int_value(zp, 8) * np.ones(np.shape(x)), int_value(y, 8))", "exact_rule(np.zeros(np.shape(x)), int_value(y, 8))"),
    ("int8 horner unclamped", "T = np.clip(T, -32768 * 2048, 32767 * 2048)", "T = T"),
    ("int8 horner c not scaled", "+ sign_extend(c, 16) * 2048", "+ sign_extend(c, 16)"),
    ("int8 code rule floor only below one step", "ok = dev <= np.maximum(REL * tz, I8_FLOOR)", "ok = (dev <= REL * tz) | ((tz < 1) & (dev <= I8_FLOOR))"),
    ("int8 code rule without the floor", "ok = dev <= np.maximum(REL * tz, I8_FLOOR)", "ok = dev <= REL * tz"),
    ("int8 code rule against |t| not |t - zp|", "dev, tz = np.abs(q - tc), np.abs(tc - zp)", "dev, tz = np.abs(q - tc), np.abs(tc)"),
    ("int8 code rule t rounded to a code", "tc = np.asarray(tc, dtype=np.float64)\n    zp, q", "tc = np.floor(np.asarray(tc, dtype=np.float64) + 0.5)\n    zp, q"),
    ("requantize zero point left out", "tc = truth.requant_true(acc, s, zp, lo, hi)", "tc = truth.requant_true(acc, s, 0, lo, hi)"),
    ("requantize unclamped", "tc = truth.requant_true(acc, s, zp, lo, hi)", "tc = truth.requant_true(acc, s, zp, -1e9, 1e9)"),
    ("quantized_add second input dropped", "tc = truth.add_true(q1, q2, r1, z1, r2, z2, 1.0, zo, lo, hi)", "tc = truth.add_true(q1, q2, r1, z1, 0.0 * r2, z2, 1.0, zo, lo, hi)"),
    ("quantized_add output zero point left out", "ok, e = code_rule(tc, int_value(zo, 8), int_value(y, 8))", "ok, e = code_rule(tc, 0, int_value(y, 8))"),
    ("int8 activation t rounded to a code", "tc = np.clip(t, s_out * (-128.0 - z_out), s_out * (127.0 - z_out))",
     "tc = s_out * (np.clip(np.floor(t / s_out + z_out + 0.5), -128.0, 127.0) - z_out)"),
    ("int8 activation t not clamped", "tc = np.clip(t, s_out * (-128.0 - z_out), s_out * (127.0 - z_out))", "tc = t"),
    ("int8 activation floor only below one step", "floor = err <= I8_FLOOR * s_out  #", "floor = (err <= I8_FLOOR * s_out) & (np.abs(tc) < s_out)  #"),
    ("int8 activation zero point left out", "hw = s_out * (o - z_out)  # the decoded output", "hw = s_out * o"),
    ("matmul bias in the scale", "t = t + ftz(decode(\"fp32\", bias))[None, :]",
     "t, s = t + ftz(decode(\"fp32\", bias))[None, :], s + np.abs(ftz(decode(\"fp32\", bias)))[None, :]"),
    ("matmul int8 within 1% of sum|ab|", "ok, e = err == 0, err", "ok, e = err <= REL * s, err"),
    ("matmul sum|ab| as |sum ab|", "s + np.abs(A) @ np.abs(B)", "s + np.abs(A @ B)"),
]


def run_mutant(src, old, new):
    """Failures of the selftest on src with old replaced by new (each mutant's text must occur)."""
    if old not in src:
        return None
    mod = types.ModuleType("truefn_mutant")
    mod.__file__ = os.path.join(HERE, "truefn.py")
    exec(compile(src.replace(old, new, 1), "truefn_mutant", "exec"), mod.__dict__)
    with contextlib.redirect_stdout(io.StringIO()):
        try:
            return mod.selftest()
        except Exception:  # noqa: BLE001  a mutant that crashes the selftest is caught too
            return 1


def main():
    src = open(os.path.join(HERE, "truefn.py")).read()
    check("selftest of the unmutated source", run_mutant(src, "REL = 0.01  #", "REL = 0.01  #"), 0)
    for what, old, new in MUTANTS:
        n = run_mutant(src, old, new)
        if n is None:
            check(f"mutant '{what}': its text is in truefn.py", False, True)
        else:
            check(f"mutant '{what}' caught by the selftest", n > 0, True)
    print(f"test_truefn mutants: {len(MUTANTS)} planted")

    # floats: truefn's rule is truth.py's except within the floor zone (max(tol |t|, 2^-126) against truth.py's "both at or below 2^-126")
    rng = np.random.default_rng(7)
    for fmt, nbits in (("bf16", 16), ("fp32", 32)):
        x = rng.integers(0, 1 << nbits, 200000, dtype=np.int64)
        x = x[~np.isnan(truth.decode(fmt, x))]
        for func in truth.FUNCS:
            t = truth.ref(func, truth.ftz(truth.decode(fmt, x)))
            with np.errstate(over="ignore", invalid="ignore"):
                o = truth.encode(fmt, t * rng.choice([1.0, 1.005, 1.02, 1.09, 1.11, 0.5], x.size))
            o = np.where(rng.random(x.size) < 0.01, rng.integers(0, 1 << nbits, x.size), o)  # some random words: NaN, Inf, anything
            a = truefn.check_activation(fmt, func, x, o).ok_el
            miss = _truth_miss(fmt, func, x, o)
            differ = a == miss  # truefn's pass where truth.py misses, or the reverse
            tv, ov = truth.ref(func, truth.ftz(truth.decode(fmt, x))), truth.decode(fmt, o)
            with np.errstate(invalid="ignore"):  # where one of the two floors decides: |o - t| <= 2^-126, or both at or below 2^-126
                near = (np.abs(ov - tv) <= truefn.F_FLOOR) | ((np.abs(tv) <= truefn.F_FLOOR) & (np.abs(ov) <= truefn.F_FLOOR))
            check(f"{fmt} {func}: truefn and truth.py differ only where a floor decides", int((differ & ~near).sum()), 0)
    # int8: a truefn pass is a truth.py pass (truefn: |hw - t| <= max(tol |t|, s_out) on decoded values; truth.py: 1 LSB of round(y))
    q = np.arange(-128, 128)
    stricter = 0
    for func, quant in (("tanh", (4 / 128, 0, 1 / 128, 0)), ("sigmoid", (3.5 / 8, 0, 1 / 256, -128)), ("selu", (0.05, -3, 0.04, 5))):
        tq = truth.ref(func, quant[0] * (q - quant[1]))
        base = np.clip(np.floor(tq / quant[2] + 0.5) + quant[3], -128, 127)
        for off in (-2, -1, 0, 1, 2):
            o = np.clip(base + off, -128, 127).astype(np.int64)
            a = truefn.check_activation("int8", func, q, o, quant=quant).ok_el
            tr = ~_truth_miss("int8", func, q, o, quant)
            check(f"int8 {func} offset {off}: truefn pass implies truth.py pass", int((a & ~tr).sum()), 0)
            stricter += int((~a & tr).sum())
    print(f"int8 activations: {stricter} outputs truth.py passes and truefn fails (the decimal rule with the floor at every |t|)")
    # matmul: truefn and truth.py agree (the bias outside the scale in both)
    for k in range(50):
        A, B = rng.normal(size=(4, 6)), rng.normal(size=(6, 3))
        Aw, Bw = truth.encode("fp32", A), truth.encode("fp32", B)
        o = truth.encode("fp32", (A @ B + 0.5) * rng.choice([1.0, 1.003, 1.03], (4, 3)))
        bias = truth.encode("fp32", np.full(3, 0.5))
        check(f"matmul case {k}: same verdict", truefn.check_matmul("fp32", [(Aw, Bw)], o, bias).ok, truth.gate_matmul("fp32", [(Aw, Bw)], o, bias).ok)
    print(f"test_truefn: {checks} checks, {fails} failures")
    print(f"RESULT: {'PASSED' if fails == 0 else 'FAILED'}")
    sys.exit(1 if fails else 0)


def _truth_miss(fmt, func, x, o, quant=None):
    """truth.py's per-element miss mask (its gate keeps only the first misses)."""
    if fmt == "int8":
        q, oo = truth.int8_codes(x).astype(np.float64), truth.int8_codes(o).astype(np.float64)
        s_in, z_in, s_out, z_out = (np.broadcast_to(np.asarray(v, dtype=np.float64), q.shape) for v in quant)
        e = truth._int8_err(func, q, oo, s_in, z_in, s_out, z_out)[0]
        return e > truth.BOUND
    t = truth.ref(func, truth.ftz(truth.decode(fmt, x)))
    e = truth._float_err(fmt, t, truth.decode(fmt, o))[0]
    return e > truth.BOUND


if __name__ == "__main__":
    main()
