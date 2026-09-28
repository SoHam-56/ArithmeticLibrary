"""Bit-exact models of AriL's float units, vectorized: fpMultiplier and fpAdder at any (EXP_W, MAN_W), and at (8, 23)
fp32Multiplier and fp32Adder. Operands and results are bit patterns in int64 arrays; each op returns (result, overflow,
underflow, invalid). Truncating; subnormal inputs read as zero; tiny results flush to a signed zero; NaN is canonical."""
import numpy as np


class Fmt:
    def __init__(self, name: str, exp_w: int, man_w: int):
        self.name, self.e, self.m = name, exp_w, man_w
        self.w = 1 + exp_w + man_w
        self.bias = (1 << (exp_w - 1)) - 1
        self.emax = (1 << exp_w) - 1
        self.mmask = (1 << man_w) - 1
        self.qnan = (self.emax << man_w) | (1 << (man_w - 1))
        self.sig = man_w + 1


FP32, BF16 = Fmt("fp32", 8, 23), Fmt("bf16", 8, 7)
FORMATS = {"fp32": FP32, "bf16": BF16}


def from_fp32(x: int, man_w: int) -> int:
    """sienna_fmt_pkg::from_fp32: a finite fp32 constant rounded to nearest even at man_w bits."""
    sh = 23 - man_w
    return x if sh == 0 else (x + (1 << (sh - 1)) - 1 + ((x >> sh) & 1)) >> sh


def _split(f: Fmt, x):
    x = np.asarray(x, dtype=np.int64)
    return (x >> (f.w - 1)) & 1, (x >> f.m) & f.emax, x & f.mmask


def _bitlen(x):
    """Bit length of non-negative int64 values below 2^53."""
    _, e = np.frexp(x.astype(np.float64))
    return np.where(x == 0, 0, e).astype(np.int64)


def _classes(f: Fmt, e, m):
    """zero (subnormals too), infinity, NaN, signaling NaN."""
    return e == 0, (e == f.emax) & (m == 0), (e == f.emax) & (m != 0), (e == f.emax) & (m != 0) & (((m >> (f.m - 1)) & 1) == 0)


def mul(f: Fmt, a, b):
    sa, ea, ma = _split(f, a)
    sb, eb, mb = _split(f, b)
    za, ia, na, sna = _classes(f, ea, ma)
    zb, ib, nb, snb = _classes(f, eb, mb)
    sign = sa ^ sb
    inv = (za & ib) | (ia & zb)
    nan, inf, zero = na | nb | inv, ia | ib, za | zb
    s = ea + eb
    p = ((1 << f.m) | ma) * ((1 << f.m) | mb)
    top = (p >> (2 * f.m + 1)) & 1
    ov_sum, un_sum, pot = s >= f.emax + f.bias, s < f.bias, s == f.bias
    under = un_sum | (pot & (top == 0))
    fexp = ((s - f.bias) + top) & f.emax
    fman = np.where(top == 1, (p >> (f.m + 1)) & f.mmask, (p >> f.m) & f.mmask)
    sz = sign << (f.w - 1)
    infb = sz | (f.emax << f.m)
    res = np.select([nan, inf, zero, ov_sum, under, fexp == f.emax],
                    [np.full_like(s, f.qnan), infb, sz, infb, sz, infb], default=sz | (fexp << f.m) | fman)
    fin = ~nan & ~inf & ~zero
    ov = fin & (ov_sum | (~under & (fexp == f.emax)))
    un = fin & ~ov_sum & under
    return res, ov, un, inv | sna | snb


def add(f: Fmt, a, b, fp32_overflow_quirk: bool = False):
    """fpAdder(A=a, B=b); with fp32_overflow_quirk, fp32Adder, which also raises overflow on a negative exponent (D-1)."""
    sa, ea, ra = _split(f, a)
    sb, eb, rb = _split(f, b)
    za, ia, na, sna = _classes(f, ea, ra)
    zb, ib, nb, snb = _classes(f, eb, rb)
    ma, mb = np.where(za, 0, ra), np.where(zb, 0, rb)
    sub = sa ^ sb
    a_ge = ((ea << f.m) | ma) >= ((eb << f.m) | mb)
    inf_inf = ia & ib & (sa != sb)
    invalid = inf_inf | sna | snb
    nan, inf = na | nb | inf_inf, ia | ib
    zero = za & zb
    bypass = za ^ zb
    siga = ((~za).astype(np.int64) << f.m) | ma
    sigb = ((~zb).astype(np.int64) << f.m) | mb
    big, small = np.where(a_ge, siga, sigb), np.where(a_ge, sigb, siga)
    diff = np.where(a_ge, ea - eb, eb - ea)
    exp, sign = np.where(a_ge, ea, eb), np.where(a_ge, sa, sb)
    sw = f.sig + 4
    swm = (1 << sw) - 1
    big3 = big << 3
    small3 = np.where(bypass, 0, np.where(diff >= f.sig + 2, 1, (small << 3) >> np.minimum(diff, 62)))
    tot = np.where(sub == 1, big3 - small3, big3 + small3) & swm
    zero = zero | (tot == 0)
    lz = sw - _bitlen(tot)
    carry = ((tot >> (sw - 1)) & 1) == 1
    shift = np.maximum(lz - 1, 0)
    conds = [bypass, carry, lz == 1, zero, lz > 1]
    nm = np.select(conds, [tot, tot >> 1, tot, 0, (tot << shift) & swm], default=tot)
    ne = np.select(conds, [exp, exp + 1, exp, 0, exp - shift], default=exp) & ((1 << (f.e + 1)) - 1)
    neg = ((ne >> f.e) & 1) == 1
    under = (neg | (ne == 0)) & ~bypass
    ov_raw = ne >= f.emax
    ov = (ov_raw if fp32_overflow_quirk else (~neg & ov_raw)) & ~inf & ~nan
    sz = sign << (f.w - 1)
    infb = sz | (f.emax << f.m)
    res = np.select([nan, inf, zero, under, ov_raw], [np.full_like(ne, f.qnan), infb, sz, sz, infb],
                    default=sz | ((ne & f.emax) << f.m) | ((nm >> 3) & f.mmask))
    un = ~nan & ~inf & ~zero & under
    return res, ov, un, invalid
