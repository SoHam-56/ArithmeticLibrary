#!/usr/bin/env python3
"""Checks fpu.narrow, fpu.widen and fpu.mul_widen: a hand-derived corner table, every bf16 round trip, an independent RNE."""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fpu  # noqa: E402

fails = checks = 0

# fp32 bits, bf16 bits after fpNarrow; each comment is the derivation (16 dropped bits, kept LSB).
NARROW_BF16 = [
    (0x00000000, 0x0000),  # +0
    (0x80000000, 0x8000),  # -0
    (0x00000001, 0x0000),  # +subnormal: exponent 0 -> +0
    (0x807FFFFF, 0x8000),  # -subnormal: exponent 0 -> -0
    (0x007FFFFF, 0x0000),  # largest subnormal would round up to a normal; exponent 0 flushes it
    (0x00800000, 0x0080),  # smallest normal
    (0x0080FFFF, 0x0081),  # smallest normal, dropped FFFF rounds up
    (0x3F800000, 0x3F80),  # 1.0
    (0x3F807FFF, 0x3F80),  # below the tie: down
    (0x3F808000, 0x3F80),  # tie, LSB 0: stays even
    (0x3F808001, 0x3F81),  # above the tie: up
    (0x3F818000, 0x3F82),  # tie, LSB 1: up to even
    (0xBF808000, 0xBF80),  # negative tie, LSB 0
    (0xBF818000, 0xBF82),  # negative tie, LSB 1
    (0x3FFFFFFF, 0x4000),  # mantissa carry into the exponent
    (0x7F7F7FFF, 0x7F7F),  # largest finite, below the tie
    (0x7F7F8000, 0x7F80),  # tie at the largest finite, LSB 1: rounds to +inf
    (0x7F7FFFFF, 0x7F80),  # largest fp32 finite: +inf
    (0xFF7F8000, 0xFF80),  # negative: -inf
    (0xFF7FFFFF, 0xFF80),  # most negative fp32 finite: -inf
    (0x7F800000, 0x7F80),  # +inf
    (0xFF800000, 0xFF80),  # -inf
    (0x7FC00000, 0x7FC0),  # qNaN
    (0xFFC00001, 0x7FC0),  # negative qNaN: canonical
    (0x7F800001, 0x7FC0),  # sNaN with only a low bit, would truncate to inf: canonical
    (0x7FBF8000, 0x7FC0),  # sNaN that rounds toward the qNaN pattern
    (0x7FFFFFFF, 0x7FC0),  # all-ones NaN, would carry into the sign
]


def check(what, got, want):
    global fails, checks
    checks += 1
    g, w = np.asarray(got, dtype=np.int64), np.asarray(want, dtype=np.int64)
    bad = np.nonzero(np.atleast_1d(g != w))[0]
    if g.shape != w.shape or len(bad):
        fails += 1
        i = bad[0] if len(bad) else 0
        print(f"[FAIL] {what}: {len(bad)} wrong, first got {np.atleast_1d(g)[i]:x}, want {np.atleast_1d(w)[i]:x}")


def rne_ref(x):
    """Independent bf16 RNE: integer quotient and remainder of the magnitude, then the special classes."""
    out = []
    for v in x.tolist():
        s, e, mag = v >> 31, (v >> 23) & 0xFF, v & 0x7FFFFFFF
        if e == 0xFF and (v & 0x7FFFFF):
            out.append(0x7FC0)
        elif e == 0:
            out.append(s << 15)
        else:
            q, r = divmod(mag, 1 << 16)
            q += 1 if (r > 0x8000 or (r == 0x8000 and q & 1)) else 0
            out.append((s << 15) | q)
    return np.array(out, dtype=np.int64)


def main() -> None:
    xs = np.array([c[0] for c in NARROW_BF16], dtype=np.int64)
    check("narrow corners", fpu.narrow(fpu.BF16, xs), [c[1] for c in NARROW_BF16])
    check("narrow corners vs rne_ref", fpu.narrow(fpu.BF16, xs), rne_ref(xs))
    check("narrow fp32 is the identity", fpu.narrow(fpu.FP32, xs), xs)
    sx = xs.astype(np.uint32).view(np.int32)  # a sign-extended int32 caller
    check(f"narrow corners from int32 ({int((sx < 0).sum())} negative)", fpu.narrow(fpu.BF16, sx), [c[1] for c in NARROW_BF16])
    check("narrow fp32 identity from int32", fpu.narrow(fpu.FP32, sx), xs)

    every = np.arange(1 << 16, dtype=np.int64)
    e = (every >> 7) & 0xFF
    keep = every[(e != 0) & ~((e == 0xFF) & ((every & 0x7F) != 0))]
    check(f"narrow(widen(x)) == x for {len(keep)} bf16 values", fpu.narrow(fpu.BF16, fpu.widen(fpu.BF16, keep)), keep)
    check("widen 1.0", fpu.widen(fpu.BF16, 0x3F80), 0x3F800000)
    check("widen -tiny", fpu.widen(fpu.BF16, 0x8001), 0x80010000)
    check("widen fp32 is the identity", fpu.widen(fpu.FP32, xs), xs)

    rng = np.random.default_rng(1)
    rx = rng.integers(0, 1 << 32, 200000, dtype=np.int64)
    ties = (every << 16)[:, None] + np.array([0x7FFF, 0x8000, 0x8001], dtype=np.int64)
    check("narrow 200000 random vs rne_ref", fpu.narrow(fpu.BF16, rx), rne_ref(rx))
    check("narrow every tie class vs rne_ref", fpu.narrow(fpu.BF16, ties.ravel()), rne_ref(ties.ravel()))

    # mul_widen is mul(FP32) on widened operands; for normal operands far from the range edges the product is exact.
    a = rng.integers(0, 1 << 16, 100000, dtype=np.int64)
    b = rng.integers(0, 1 << 16, 100000, dtype=np.int64)
    r = fpu.mul_widen(fpu.BF16, a, b)
    check("mul_widen returns 4 results", len(r), 4)
    m32 = fpu.mul(fpu.FP32, fpu.widen(fpu.BF16, a), fpu.widen(fpu.BF16, b))
    for k in range(4):
        check(f"mul_widen[{k}] == mul(FP32, widen, widen)[{k}]", r[k], m32[k])
    ea, eb = (a >> 7) & 0xFF, (b >> 7) & 0xFF
    mid = (ea > 64) & (ea < 190) & (eb > 64) & (eb < 190)
    fa = fpu.widen(fpu.BF16, a[mid]).astype(np.uint32).view(np.float32).astype(np.float64)
    fb = fpu.widen(fpu.BF16, b[mid]).astype(np.uint32).view(np.float32).astype(np.float64)
    exact = (fa * fb).astype(np.float32).view(np.uint32).astype(np.int64)
    check(f"mul_widen exact on {int(mid.sum())} normal products", r[0][mid], exact)
    back = exact.astype(np.uint32).view(np.float32).astype(np.float64)
    check("the float64 products fit fp32 exactly", (fa * fb) == back, np.ones(len(back), dtype=bool))

    print(f"test_fpu: {checks} checks, {fails} failed")
    print("RESULT: " + ("PASSED" if fails == 0 else "FAILED"))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
