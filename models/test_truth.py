#!/usr/bin/env python3
"""Checks truth.py: decoding, the references against Python's math, the vectorized gate against one element at a time, and that its selftest fails on every planted mutant."""
import contextlib
import io
import math
import os
import struct
import sys
import types

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import truth  # noqa: E402

fails = checks = 0


def check(what, got, want):
    global fails, checks
    checks += 1
    if got != want:
        fails += 1
        if fails <= 30:
            print(f"[FAIL] {what}: got {got}, want {want}")


# Mutants of truth.py's source: each breaks one rule, and the selftest must report failures on it.
MUTANTS = [
    ("int8 relative tolerance 2%", "I8_REL = TARGET", "I8_REL = 0.02"),
    ("int8 step floor 2", "tol = np.maximum(I8_REL * np.abs(tc - zp), 1.0)", "tol = np.maximum(I8_REL * np.abs(tc - zp), 2.0)"),
    ("int8 step floor 0", "tol = np.maximum(I8_REL * np.abs(tc - zp), 1.0)", "tol = I8_REL * np.abs(tc - zp)"),
    ("int8 tolerance on |tc|, not |t|", "tol = np.maximum(I8_REL * np.abs(tc - zp), 1.0)", "tol = np.maximum(I8_REL * np.abs(tc), 1.0)"),
    ("int8 vacuous pass", "miss.size == 0 and tc.size > 0", "miss.size == 0"),
    ("requant true value unclamped", "return np.clip(acc * np.asarray(s, dtype=np.float64) + int8_codes(zp), _bound(lo), _bound(hi))",
     "return acc * np.asarray(s, dtype=np.float64) + int8_codes(zp)"),
    ("real clamp bound truncated", "np.where(b == np.floor(b), int8_codes(np.floor(b)), np.clip(b, -128.0, 127.0))", "int8_codes(b)"),
    ("add true value clamped on truncated bounds", "np.clip(v + int8_codes(zo), _bound(lo), _bound(hi))", "np.clip(v + int8_codes(zo), int8_codes(lo), int8_codes(hi))"),
    ("requant true value without zp", "acc * np.asarray(s, dtype=np.float64) + int8_codes(zp)", "acc * np.asarray(s, dtype=np.float64) + 0"),
    ("add true value without z1", "(int8_codes(q1) - int8_codes(z1))", "int8_codes(q1)"),
    ("add true value without s_out", ") / np.asarray(s_out, dtype=np.float64)", ") / 1.0"),
    ("scale off by 2 LSB passes", "& (rel <= 1.0)", "& (rel <= 3.0)"),
    ("scale unnormalized passes", "& (m >= 1 << (width - 1)) & (m < 1 << width)", ""),
    ("scale saturating code not required", "(m == (1 << width) - 1) & (e == width - 8)", "True"),
    ("target 2%", "TARGET = 0.01", "TARGET = 0.02"),
    ("bound 12%", "BOUND = 0.10", "BOUND = 0.12"),
    ("float floor 2^-125", "F_FLOOR = 2.0 ** -126", "F_FLOOR = 2.0 ** -125"),
    ("float floor 2^-127", "F_FLOOR = 2.0 ** -126", "F_FLOOR = 2.0 ** -127"),
    ("int8 activation floor 2 steps", "floor = d <= 1.0  # within one output step", "floor = d <= 2.0  # within one output step"),
    ("int8 activation floor 0 steps", "floor = d <= 1.0  # within one output step", "floor = d <= 0.0  # within one output step"),
    ("int8 activation floor one code of round(t)", "floor = d <= 1.0  # within one output step", "floor = lsb <= 1  # within one output step"),
    ("NaN output not failed", "rel = np.where(np.isfinite(o), rel, np.inf)", "rel = rel"),
    ("Inf output passed", "rel = np.where(np.isfinite(o), rel, np.inf)", "rel = np.where(np.isinf(o), 0.0, np.where(np.isnan(o), np.inf, rel))"),
    ("overflow sign ignored", "ovf_ok = big & top & (np.sign(o) == np.sign(t))", "ovf_ok = big & top"),
    ("no overflow rule", "big = np.abs(t) > fmax(fmt)", "big = np.abs(t) > np.inf"),
    ("overflow from the rounding threshold", "big = np.abs(t) > fmax(fmt)", "big = np.abs(t) >= 2.0 ** 128 - 2.0 ** (126 - FLOATS[fmt])"),
    ("floor on the output alone", "floor = (np.abs(o) <= F_FLOOR) & (np.abs(t) <= F_FLOOR)", "floor = np.abs(o) <= F_FLOOR"),
    ("subnormal inputs not read as zero", "t = ref(func, ftz(x))", "t = ref(func, x)"),
    ("normal inputs at 2^-126 read as zero", "np.where(np.abs(x) < F_FLOOR, np.copysign(0.0, x), x)",
     "np.where(np.abs(x) <= F_FLOOR, np.copysign(0.0, x), x)"),
    ("int8 true value not clamped to the output range", "tcode = np.clip(t / s_out + z_out, -128, 127)", "tcode = t / s_out + z_out"),
    ("int8 true value in steps truncated", "tcode = np.clip(t / s_out + z_out, -128, 127)", "tcode = np.clip(np.floor(t / s_out) + z_out, -128, 127)"),
    ("SELU alpha 1.67", "SELU_ALPHA = 1.6732632423543772848170429916717", "SELU_ALPHA = 1.67"),
    ("tanh as x", "return np.tanh(np.asarray(x, dtype=np.float64))", "return np.asarray(x, dtype=np.float64)"),
    ("matmul bound 2%", "MM_BOUND = 0.01", "MM_BOUND = 0.02"),
    ("matmul int8 within 1% of sum|ab|", '(err == 0) if fmt == "int8" else (err <= lim)', "err <= lim"),
    ("matmul int8 sums not wrapped", "np.abs(np.mod(o - t + 2**31, 2**32) - 2**31) if fmt == \"int8\" else np.abs(o - t)", "np.abs(o - t)"),
    ("matmul int8 sums saturated", "np.abs(np.mod(o - t + 2**31, 2**32) - 2**31) if fmt == \"int8\" else np.abs(o - t)",
     "np.abs(o - np.clip(t, -2**31, 2**31 - 1))"),
    ("matmul overflow sign ignored", "| np.isinf(o)) & (np.sign(o) == np.sign(t))", "| np.isinf(o))"),
    ("matmul no overflow rule", 'big = np.zeros(t.shape, dtype=bool) if fmt == "int8" else np.abs(t) > fmax("fp32")', "big = np.zeros(t.shape, dtype=bool)"),
    ("matmul floor dropped", "lim = np.maximum(bound * s, F_FLOOR)", "lim = bound * s"),
    ("matmul bias left out", "        t = t + b", "        t = t"),
    ("matmul bias in the scale", "        t = t + b", "        t, s = t + b, s + np.abs(b)"),
    ("matmul sum|ab| as |sum ab|", "s + np.abs(A) @ np.abs(B)", "s + np.abs(A @ B)"),
    ("matmul last pass only", "t, s = t + A @ B,", "t, s = A @ B,"),
    ("matmul operands' subnormals kept", "        return ftz(decode(fmt, w))", "        return decode(fmt, w)"),
    ("narrow truncates", 'return encode(fmt, ftz(decode("fp32", pre)))',
     'return (np.asarray(pre, dtype=np.int64) >> 16) & 0xFFFF if fmt == "bf16" else encode(fmt, ftz(decode("fp32", pre)))'),
    ("narrow NaN never matches", "ok_el = (vw == vp) | (np.isnan(vw) & np.isnan(vp))", "ok_el = vw == vp"),
    ("maxpool first element", "xp[i * ph:i * ph + ph, j * pw:j * pw + pw].max()", "xp[i * ph:i * ph + ph, j * pw:j * pw + pw].ravel()[0]"),
    ("maxpool pad 0", "fill = -128.0 if fmt == \"int8\" else -np.inf", "fill = 0.0"),
    ("dropout unscaled", "kept = values(fmt, encode(fmt, xv / (1.0 - p)))", "kept = xv"),
    ("dropout mask ignored", "want = np.where(keep, kept, dropped) if training else xv", "want = kept if training else xv"),
]


def mutant_failures(old, new):
    """Selftest failures of truth.py with old replaced by new; None when old is not in the source."""
    with open(truth.__file__) as fh:
        src = fh.read()
    if old not in src:
        return None
    m = types.ModuleType("truth_mutant")
    m.__file__ = truth.__file__
    exec(compile(src.replace(old, new, 1), "truth_mutant", "exec"), m.__dict__)
    with contextlib.redirect_stdout(io.StringIO()), np.errstate(all="ignore"):
        return m.selftest()


def main():
    rng = np.random.default_rng(7)
    # decoding: fp32 against struct, every bf16 pattern as the top half of an fp32
    w = rng.integers(0, 1 << 32, 20000, dtype=np.int64)
    want = [struct.unpack("<f", struct.pack("<I", int(v)))[0] for v in w]
    got = truth.decode("fp32", w)
    check("decode fp32 vs struct", bool(np.array_equal(got, np.array(want), equal_nan=True)), True)
    b = np.arange(1 << 16, dtype=np.int64)
    want = np.array([struct.unpack("<f", struct.pack("<I", int(v) << 16))[0] for v in b])
    check("decode bf16 vs struct, every pattern", bool(np.array_equal(truth.decode("bf16", b), want, equal_nan=True)), True)
    fin = b[(b & 0x7F80) != 0x7F80]
    check("encode(decode) bf16, every finite pattern", bool(np.array_equal(truth.encode("bf16", truth.decode("bf16", fin)), fin)), True)
    check("encode bf16 ties to even", [int(v) for v in truth.encode("bf16", [1 + 2 ** -8, 1 + 3 * 2 ** -8])], [0x3F80, 0x3F82])
    check("subnormal decoded, not flushed", float(truth.decode("bf16", 0x0001)), 2.0 ** -133)
    check("ftz: subnormals to signed zero, 2^-126 kept", [str(v) for v in truth.ftz([2.0 ** -133, -2.0 ** -127, 2.0 ** -126])],
          ["0.0", "-0.0", str(2.0 ** -126)])
    # references against Python's math, scalar by scalar
    xs = np.concatenate([rng.uniform(-50, 50, 3000), rng.uniform(-1e-3, 1e-3, 1000), [0.0, -0.0, 1e-300, -1e-300, 700.0, -700.0]])
    bad = {f: 0 for f in ("sigmoid", "tanh", "selu")}
    for x in xs:
        s = 1 / (1 + math.exp(-x)) if x >= 0 else math.exp(x) / (1 + math.exp(x))
        r = {"sigmoid": s, "tanh": math.tanh(x),
             "selu": truth.SELU_LAMBDA * x if x > 0 else truth.SELU_LAMBDA * truth.SELU_ALPHA * math.expm1(x)}
        for f, v in r.items():
            t = float(truth.ref(f, x))
            bad[f] += abs(t - v) > 4e-16 * abs(v)
    for f, n in bad.items():
        check(f"{f} against math, {xs.size} inputs", n, 0)
    check("relu and linear", (truth.ref("relu", np.array([-2.0, 3.0])).tolist(), truth.ref("linear", np.array([-2.0])).tolist()),
          ([0.0, 3.0], [-2.0]))
    with np.errstate(over="raise", invalid="raise", divide="raise"):  # no overflow, NaN or division by zero over the whole bf16 range
        v = truth.decode("bf16", fin)
        check("references raise nothing on every finite bf16", all(np.isfinite(truth.ref(f, v)).all() for f in truth.FUNCS), True)
    # the vectorized gate equals one element at a time, on outputs mixing near, far, NaN, Inf, max and zero
    x = rng.choice(fin, 3000)
    for fmt, xw in (("bf16", x), ("fp32", truth.encode("fp32", truth.decode("bf16", x)))):
        for func in truth.FUNCS:
            t = truth.ref(func, truth.decode(fmt, xw))
            with np.errstate(all="ignore"):
                near = truth.encode(fmt, t * rng.uniform(0.85, 1.15, t.size))
            special = truth.encode(fmt, np.array([np.nan, np.inf, -np.inf, 0.0, truth.fmax(fmt), -truth.fmax(fmt), 2.0 ** -126]))
            o = np.where(rng.random(t.size) < 0.1, rng.choice(special, t.size), near)
            r = truth.gate(fmt, func, xw, o)
            one = [truth.gate(fmt, func, xw[i:i + 1], o[i:i + 1]) for i in range(xw.size)]
            check(f"{fmt} {func}: vector misses = scalar misses", [m[0] for m in r.first], [i for i, s in enumerate(one) if not s.ok][:truth.FIRST])
            check(f"{fmt} {func}: over", r.over, sum(not s.ok for s in one))
            check(f"{fmt} {func}: over target", r.over_target, sum(s.over_target for s in one))
            check(f"{fmt} {func}: worst", r.worst, max(s.worst for s in one))
    # int8: q_true and the clamp, against Python's math one code at a time
    for func, (s_in, z_in, s_out, z_out) in (("tanh", (4 / 32, -37, 1 / 128, 0)), ("sigmoid", (3.5 / 64, -100, 1 / 256, -128)),
                                            ("selu", (4 / 128, 120, 0.0123, -77))):
        q = np.arange(-128, 128, dtype=np.float64)
        _, _, _, _, qt = truth._int8_err(func, q, q, s_in, z_in, s_out, z_out)
        f = {"tanh": math.tanh, "sigmoid": lambda v: 1 / (1 + math.exp(-v)),
             "selu": lambda v: truth.SELU_LAMBDA * v if v > 0 else truth.SELU_LAMBDA * truth.SELU_ALPHA * math.expm1(v)}[func]
        want = [min(127, max(-128, math.floor(f(s_in * (k - z_in)) / s_out + 0.5) + z_out)) for k in range(-128, 128)]
        check(f"int8 {func} q_true", qt.astype(int).tolist(), want)
        r = truth.gate("int8", func, np.arange(-128, 128), np.array(want), quant=(s_in, z_in, s_out, z_out))
        check(f"int8 {func}: q_true itself passes, worst 0", (r.ok, r.worst, r.worst_lsb), (True, 0.0, 0))
        r = truth.gate("int8", func, np.arange(-128, 128), np.clip(np.array(want) + 2, -128, 127), quant=(s_in, z_in, s_out, z_out))
        check(f"int8 {func}: +2 LSB everywhere is 2 LSB worst and over 1% somewhere", (r.worst_lsb, r.over_target > 0), (2, True))
    for bad_call in (lambda: truth.gate("fp16", "tanh", [0], [0]), lambda: truth.gate("bf16", "gelu", [0], [0]),
                     lambda: truth.gate("int8", "tanh", [0], [0]), lambda: truth.gate("bf16", "tanh", [0x7FC0], [0]),
                     lambda: truth.gate("bf16", "tanh", [], [])):
        try:
            bad_call()
            check("bad call raises", "returned", "ValueError")
        except ValueError:
            check("bad call raises", "ValueError", "ValueError")
    # the stage references against independent ones: Fractions, fpu's narrowing, loops, brute-force windows
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import fpu  # noqa: E402
    import ipu  # noqa: E402
    acc = rng.integers(-2**31, 2**31, 20000)
    sc = np.exp(rng.uniform(np.log(1e-9), np.log(4.0), 20000))
    zp, lo, hi = rng.integers(-128, 128, 20000), -128, 127
    from fractions import Fraction
    tc = truth.requant_true(acc, sc, zp, lo, hi)
    exact = [float(min(hi, max(lo, Fraction(int(a)) * Fraction(float(c)) + int(z)))) for a, c, z in zip(acc[:3000], sc[:3000], zp[:3000])]
    check("requant_true against Fractions, 3000 draws (float64 error under 1e-6 steps)", bool(np.allclose(tc[:3000], exact, rtol=0, atol=1e-6)), True)
    codes = [ipu.encode_scale(float(c)) for c in sc]
    q = ipu.requantize(acc, [m for m, _ in codes], [e for _, e in codes], zp, lo, hi)
    check("gate_requantize passes ipu.requantize on encode_scale's words, 20000 draws", truth.gate_requantize(acc, sc, zp, lo, hi, q).ok, True)
    w = np.concatenate([rng.integers(0, 1 << 32, 20000), [0x7F7F8000, 0xFF7F8000, 0x7F7F7FFF, 0x3F808000, 0x3F818000]])
    w = w[((w >> 23) & 0xFF) != 0]  # fp32ToBf16 flushes subnormal inputs as narrow_ref does; compared on normals, NaN and Inf
    want = np.asarray(fpu.narrow(fpu.FORMATS["bf16"], w), dtype=np.int64)
    got = truth.narrow_ref("bf16", w)
    vw, vg = truth.decode("bf16", want), truth.decode("bf16", got)
    check("narrow_ref against fpu.narrow, 20000 words", bool(np.all((vw == vg) | (np.isnan(vw) & np.isnan(vg)))), True)
    As = [rng.uniform(-4, 4, (5, 3)) for _ in range(3)]
    Bs = [rng.uniform(-4, 4, (3, 4)) for _ in range(3)]
    bias = rng.uniform(-1, 1, 4)
    t, s = truth.matmul_ref(list(zip(As, Bs)), bias)
    lt = [[math.fsum([As[p][i, k] * Bs[p][k, j] for p in range(3) for k in range(3)] + [bias[j]]) for j in range(4)] for i in range(5)]
    ls = [[math.fsum([abs(As[p][i, k] * Bs[p][k, j]) for p in range(3) for k in range(3)]) for j in range(4)] for i in range(5)]
    check("matmul_ref against fsum loops", bool(np.allclose(t, lt, rtol=1e-14, atol=1e-14) and np.allclose(s, ls, rtol=1e-14)), True)
    x = rng.uniform(-9, 9, (6, 7))
    for ph, pw, pad in ((2, 2, 1), (3, 2, 0), (1, 1, 0), (2, 3, 1)):
        ref = truth.maxpool_ref(x, ph, pw, pad, -np.inf)
        xp = np.pad(x, pad, constant_values=-np.inf)
        bf = [[max(xp[i * ph + a, j * pw + b] for a in range(ph) for b in range(pw)) for j in range(ref.shape[1])] for i in range(ref.shape[0])]
        check(f"maxpool_ref {ph}x{pw} pad {pad} against brute force", ref.tolist(), bf)
    # the int8 ADD: add_true against Fractions, and gate_quantized_add passing ipu.qadd on encode_add's words, failing one code off by two
    bad, n = 0, 0
    for i in range(100):
        r1, r2 = np.exp2(rng.uniform(-10, 0, 2))  # most sums stay off the rails
        zp1, zp2, zpo = (int(z) for z in rng.integers(-128, 128, 3))
        q1, q2 = rng.integers(-128, 128, 256), rng.integers(-128, 128, 256)
        m1, m2, e = ipu.encode_add(float(r1), float(r2))
        y = ipu.qadd(q1, q2, zp1, zp2, m1, m2, e, zpo, -128, 127)
        r = truth.gate_quantized_add(q1, q2, r1, zp1, r2, zp2, 1.0, zpo, -128, 127, y)
        bad, n = bad + r.over, n + r.n
        if i == 0:
            t = truth.add_true(q1[:20], q2[:20], r1, zp1, r2, zp2, 1.0, zpo, -128, 127)
            ex = [float(min(127, max(-128, Fraction(float(r1)) * (int(a) - zp1) + Fraction(float(r2)) * (int(b) - zp2) + zpo)))
                  for a, b in zip(q1[:20], q2[:20])]
            check("add_true against Fractions", bool(np.allclose(t, ex, rtol=0, atol=1e-6)), True)
            ta = truth.add_true(q1, q2, r1, zp1, r2, zp2, 1.0, zpo, -128, 127)
            off = y.copy()
            k = int(np.flatnonzero((np.abs(ta) < 120) & (np.abs(ta - zpo) < 100))[0])  # inside the rails, where the floor is one step
            off[k] += 2 if off[k] < 126 else -2
            rr = truth.gate_quantized_add(q1, q2, r1, zp1, r2, zp2, 1.0, zpo, -128, 127, off & 0xFF)
            check("gate_quantized_add fails one code off by two", (rr.ok, rr.over, rr.first[0][0]), (False, 1, k))
    check("gate_quantized_add passes ipu.qadd on encode_add's words, 100 sets x 256 pairs", (bad, n), (0, 25600))

    # the selftest passes, and fails on each mutant
    with contextlib.redirect_stdout(io.StringIO()):
        check("selftest failures", truth.selftest(), 0)
    for name, old, new in MUTANTS:
        n = mutant_failures(old, new)
        check(f"mutant '{name}' is in the source", n is not None, True)
        if n is not None:
            check(f"mutant '{name}' fails the selftest", n > 0, True)
            print(f"mutant {name}: selftest {n} failures")

    print(f"test_truth: {checks} checks, {fails} failures")
    print(f"RESULT: {'PASSED' if fails == 0 else 'FAILED'}")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
