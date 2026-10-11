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
    ("target 2%", "TARGET = 0.01", "TARGET = 0.02"),
    ("bound 12%", "BOUND = 0.10", "BOUND = 0.12"),
    ("float floor 2^-125", "F_FLOOR = 2.0 ** -126", "F_FLOOR = 2.0 ** -125"),
    ("float floor 2^-127", "F_FLOOR = 2.0 ** -126", "F_FLOOR = 2.0 ** -127"),
    ("int8 floor 2 LSB", "I8_FLOOR = 1", "I8_FLOOR = 2"),
    ("int8 floor 0 LSB", "I8_FLOOR = 1", "I8_FLOOR = 0"),
    ("NaN output not failed", "rel = np.where(np.isfinite(o), rel, np.inf)", "rel = rel"),
    ("Inf output passed", "rel = np.where(np.isfinite(o), rel, np.inf)", "rel = np.where(np.isinf(o), 0.0, np.where(np.isnan(o), np.inf, rel))"),
    ("overflow sign ignored", "ovf_ok = big & top & (np.sign(o) == np.sign(t))", "ovf_ok = big & top"),
    ("no overflow rule", "big = np.abs(t) >= ovf(fmt)", "big = np.abs(t) > np.inf"),
    ("floor on the output alone", "floor = (np.abs(o) <= F_FLOOR) & (np.abs(t) <= F_FLOOR)", "floor = np.abs(o) <= F_FLOOR"),
    ("subnormal inputs flushed in the reference", "x, o = decode(fmt, x_in), decode(fmt, out)",
     "x, o = decode(fmt, x_in), decode(fmt, out)\n        x = np.where(np.abs(x) < F_FLOOR, 0.0, x)"),
    ("int8 true value not clamped to the output range", "tc = np.clip(t, lo, hi)", "tc = t"),
    ("int8 q_true truncated", "np.floor(t / s_out + 0.5)", "np.floor(t / s_out)"),
    ("SELU alpha 1.67", "SELU_ALPHA = 1.6732632423543772848170429916717", "SELU_ALPHA = 1.67"),
    ("tanh as x", "return np.tanh(np.asarray(x, dtype=np.float64))", "return np.asarray(x, dtype=np.float64)"),
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
