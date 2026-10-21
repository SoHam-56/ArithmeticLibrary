#!/usr/bin/env python3
"""The one parser of sienna_fmt_pkg: its precision constants and bundles under a define, read from the RTL text.

The package is Common/src/sienna_fmt_pkg.sv, its define map after the old functions. Values come from the text, never from a copy here.
"""
import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "src"))
PKG = os.path.join(SRC, "sienna_fmt_pkg.sv")
FORMATS = ("fp32", "bf16", "int8")
DEFINES = {f: "FMT_" + f.upper() for f in FORMATS}


def preprocess(text, defines):
    """The text with `ifdef/`ifndef/`elsif/`else/`endif resolved for a set of defined macros; an undefined macro left in live text is an error."""
    out, stack = [], []  # stack of (taking, taken_any) per open `ifdef
    live = lambda: all(t for t, _ in stack)
    for ln in text.splitlines():
        s = ln.strip()
        m = re.match(r"`(ifdef|ifndef|elsif)\s+(\w+)", s)
        if m:
            kw, name = m.groups()
            if kw in ("ifdef", "ifndef"):
                take = (name in defines) == (kw == "ifdef")
                stack.append((take, take))
            else:
                if not stack:
                    raise ValueError("`elsif without `ifdef")
                _, any_ = stack.pop()
                take = (not any_) and name in defines
                stack.append((take, any_ or take))
            continue
        if s.startswith("`else"):
            _, any_ = stack.pop()
            stack.append((not any_, True))
            continue
        if s.startswith("`endif"):
            stack.pop()
            continue
        if live():
            code = ln.split("//")[0]
            u = re.search(r"`(\w+)", code)
            if u and u.group(1) not in ("include", "timescale") and u.group(1) not in defines:
                raise ValueError(f"undefined macro `{u.group(1)} (the define map's guard): defines {sorted(defines)}")
            out.append(ln)
    if stack:
        raise ValueError("unterminated `ifdef")
    return "\n".join(out)


def _literal(tok):
    """A Verilog number: 8'h80, 5'd16, 1'b0, 32'hFF80_0000, 13; returns (value, width or None)."""
    tok = tok.strip().replace("_", "")
    m = re.fullmatch(r"(\d+)'([hdbo])([0-9a-fA-F]+)", tok)
    if m:
        w, base, digits = m.groups()
        return int(digits, {"h": 16, "d": 10, "b": 2, "o": 8}[base]), int(w)
    if re.fullmatch(r"\d+", tok):
        return int(tok), None
    raise ValueError(f"not a literal: {tok!r}")


def _value(expr):
    """A localparam's value: a literal, a sum of literals, a string, or a concatenation {a, b, ...} of sized literals."""
    e = expr.strip()
    if e.startswith('"'):
        return e.strip('"')
    if e.startswith("{"):
        v = 0
        for part in e.strip("{}").split(","):
            x, w = _literal(part)
            if w is None:
                raise ValueError(f"unsized part in {e!r}")
            v = (v << w) | (x & ((1 << w) - 1))
        return v
    return sum(_literal(p)[0] for p in e.split("+"))


def _struct(body):
    """Fields of a packed struct body, MSB first: [(name, width)]."""
    fields = []
    for ln in body.split(";"):
        ln = ln.split("//")[0].strip()
        if not ln:
            continue
        m = re.fullmatch(r"logic\s*(?:\[(\d+):(\d+)\])?\s*(\w+)", ln)
        if not m:
            raise ValueError(f"struct field {ln!r}")
        hi, lo, name = m.groups()
        fields.append((name, int(hi) - int(lo) + 1 if hi else 1))
    return fields


def _strip_comments(text):
    return "\n".join(ln.split("//")[0] for ln in text.splitlines())


def _sources():
    return open(PKG).read()


def read(fmt=None, defines=None):
    """{'consts': {name: value}, 'types': {name: [(field, width)] or 1}} for a format (or an explicit define set)."""
    if defines is None:
        if fmt not in FORMATS + ("default",):
            raise ValueError(f"{fmt}: not one of {', '.join(FORMATS)}")
        defines = set() if fmt == "default" else {DEFINES[fmt]}
    text = _strip_comments(preprocess(_sources(), set(defines)))
    consts = {}
    for m in re.finditer(r"localparam\s+(?:int|bit|string|logic\s*(?:\[[^\]]*\])?)\s+(\w+)\s*=\s*([^;]+);", text):
        consts[m.group(1)] = _value(m.group(2))
    types = {}
    for m in re.finditer(r"typedef\s+struct\s+packed\s*\{(.*?)\}\s*(\w+)\s*;", text, re.S):
        types[m.group(2)] = _struct(m.group(1))
    for m in re.finditer(r"typedef\s+logic\s+(\w+)\s*;", text):
        types[m.group(1)] = 1
    return {"consts": consts, "types": types}


def consts(fmt):
    return read(fmt)["consts"]


def get(fmt, name):
    c = consts(fmt)
    if name not in c:
        raise KeyError(f"{name}: not a constant of sienna_fmt_pkg under {fmt}")
    return c[name]


def width(fmt, typ):
    """Bits of a package type: a struct's field widths summed, 1 for a dummy."""
    t = read(fmt)["types"][typ]
    return t if isinstance(t, int) else sum(w for _, w in t)


def table(fmt, name, entry_w, n):
    """Entries of a flat packed table, entry i at [i*entry_w +: entry_w]."""
    v = get(fmt, name)
    return [(v >> (i * entry_w)) & ((1 << entry_w) - 1) for i in range(n)]


LAT_OF_KIND = {"requantize": "REQUANT_LATENCY", "quantized_add": "QUANT_ADD_LATENCY"}  # the units with no wrapper; the combinational ones have latency 0
KINDS = ("mul", "add", "cmp", "relu", "narrow", "requantize", "quantized_add")  # 2 wrappers, 2 package functions, 3 swept units (spec 2026-10-17)


def kind_lat(fmt, kind, data_width=None, ext_data_width=None):
    """A kind's latency, as the package's functions: fmt_mul's mul_latency (MUL_LATENCY into ACC_DATA_WIDTH from a narrower word, else LANE_MUL_LATENCY)
    and fmt_add's add_latency (ADD_LATENCY at ACC_DATA_WIDTH, LANE_ADD_LATENCY otherwise); data_width defaults to DATA_WIDTH for fmt_mul, ACC_DATA_WIDTH for fmt_add."""
    acc = get(fmt, "ACC_DATA_WIDTH")
    if kind == "mul":
        data_width = get(fmt, "DATA_WIDTH") if data_width is None else data_width
        if ext_data_width is None:
            ext_data_width = 2 * data_width if fmt == "int8" else data_width
        return get(fmt, "MUL_LATENCY") if (ext_data_width == acc and data_width != acc) else get(fmt, "LANE_MUL_LATENCY")
    if kind == "add":
        return get(fmt, "ADD_LATENCY") if data_width in (None, acc) else get(fmt, "LANE_ADD_LATENCY")
    return get(fmt, LAT_OF_KIND[kind]) if kind in LAT_OF_KIND else 0


def kind_widths(fmt, kind, data_width=None, ext_data_width=None):
    """The wrapper widths a kind runs at: fmt_add's DATA_WIDTH defaults to ACC_DATA_WIDTH, fmt_mul's to DATA_WIDTH with EXT_DATA_WIDTH
    2 DATA_WIDTH in int8 and DATA_WIDTH in floats; the other kinds run at DATA_WIDTH."""
    if data_width is None:
        data_width = get(fmt, "ACC_DATA_WIDTH") if kind == "add" else get(fmt, "DATA_WIDTH")
    if ext_data_width is None:
        ext_data_width = 2 * data_width if (kind == "mul" and fmt == "int8") else data_width
    return int(data_width), int(ext_data_width)


def cflags(fmt, kind, data_width=None, ext_data_width=None):
    """C defines for the sweep harness: the widths and the kind's latency, from the package."""
    c = consts(fmt)
    out = [f"-DFMT_{fmt.upper()}"]
    for k in ("DATA_WIDTH", "ACC_DATA_WIDTH", "RESULT_DATA_WIDTH", "BIAS_DATA_WIDTH", "ACTIVATION_DATA_WIDTH"):
        out.append(f"-DPKG_{k}={c[k]}")
    out.append(f"-DPKG_LATENCY={kind_lat(fmt, kind, data_width, ext_data_width)}")
    dw, edw = kind_widths(fmt, kind, data_width, ext_data_width)
    out.append(f"-DWRAPPER_DATA_WIDTH={dw}")  # the harness has no default: the widths always come from here
    out.append(f"-DEXT_DATA_WIDTH={edw}")
    return " ".join(out)


# ── selftest: the parser against the restructure spec's table, typed in here independently ──

SPEC = {  # sienna-restructure "The format package and the define": fp32, bf16, int8
    "DATA_WIDTH": (32, 16, 8), "ACC_DATA_WIDTH": (32, 32, 32), "RESULT_DATA_WIDTH": (32, 16, 32), "BIAS_DATA_WIDTH": (32, 16, 32), "ACTIVATION_DATA_WIDTH": (32, 16, 16),
    "MUL_LATENCY": (8, 3, 1), "ADD_LATENCY": (5, 5, 1), "LANE_MUL_LATENCY": (8, 3, 1), "LANE_ADD_LATENCY": (5, 5, 0), "POST_DECREMENT_PAD_CYCLES": (1, 0, 0),
    "HORNER_STEP_LATENCY": (13, 8, 3), "HORNER_COEFFICIENT_LAG": (8, 3, 1), "REQUANT_LATENCY": (0, 0, 4), "QUANT_ADD_LATENCY": (0, 0, 6), "DROPOUT_SCALE_LATENCY": (8, 3, 0),
    "LOWEST_VALUE": (0xFF800000, 0xFF80, 0x80), "ONE_VALUE": (0x3F800000, 0x3F80, 1), "HAS_FLOAT_TAIL": (1, 1, 0), "HAS_REQUANT_EPILOGUE": (0, 0, 1),
    "HAS_RESIDUAL_ADD": (0, 0, 1), "EXPONENT_WIDTH": (8, 8, 0), "MANTISSA_WIDTH": (23, 7, 7),
}


def selftest():
    fails, checks = [0], [0]

    def check(what, got, want):
        checks[0] += 1
        if got != want:
            fails[0] += 1
            print(f"[FAIL] {what}: got {got!r}, want {want!r}")

    for i, f in enumerate(FORMATS):
        c = consts(f)
        for k, v in SPEC.items():
            check(f"{f} {k}", c.get(k), v[i])
        check(f"{f} FORMAT_NAME", c["FORMAT_NAME"], f)
        check(f"{f} FMT_DEFINE_COUNT", c["FMT_DEFINE_COUNT"], 1)
        check(f"{f} HORNER_STEP_LATENCY = LANE_MUL_LATENCY + LANE_ADD_LATENCY (floats)", c["HORNER_STEP_LATENCY"] == c["LANE_MUL_LATENCY"] + c["LANE_ADD_LATENCY"], f != "int8")
        if f != "int8":
            check(f"{f} HORNER_COEFFICIENT_LAG = LANE_MUL_LATENCY", c["HORNER_COEFFICIENT_LAG"], c["LANE_MUL_LATENCY"])
    check("no define is fp32", consts("default"), {**consts("fp32"), "FMT_DEFINE_COUNT": 0})
    check("int8 requant_params_t (int8Requantizer's ports)", read("int8")["types"]["requant_params_t"],
          [("mantissa", 24), ("shift", 6), ("zero_point", 8), ("act_min", 8), ("act_max", 8)])
    check("int8 add_params_t (int8QuantizedAdder's ports, add_words_t's order)", read("int8")["types"]["add_params_t"],
          [("in1_zero_point", 8), ("in2_zero_point", 8), ("in1_mantissa", 32), ("in2_mantissa", 32), ("shift", 6), ("out_zero_point", 8),
           ("act_min", 8), ("act_max", 8)])
    check("int8 lane_params_t width (gp_* ports)", width("int8", "lane_params_t"), 16 + 5 + 8 + 24 + 6 + 8)
    check("int8 lane_entry_t (SIENNA's per-entry words)", read("int8")["types"]["lane_entry_t"],
          [("zero_point", 8), ("act_min", 8), ("act_max", 8), ("in_rescale_mantissa", 16), ("in_rescale_shift", 5), ("selu_out_mantissa", 24),
           ("selu_out_shift", 6), ("selu_out_zero_point", 8)])
    check("int8 requant_scale_t (a channel's scale)", read("int8")["types"]["requant_scale_t"], [("mantissa", 24), ("shift", 6)])
    check("DROPOUT_KEEP_SCALE", [get(f, "DROPOUT_KEEP_SCALE") for f in FORMATS], [0x40000000, 0x4000, 1])
    for f in ("fp32", "bf16"):
        check(f"{f} bundles are 1-bit dummies", [width(f, t) for t in ("lane_params_t", "requant_params_t", "add_params_t", "lane_entry_t", "requant_scale_t")],
              [1, 1, 1, 1, 1])
    check("COEF_BASE_DEGREE_TABLE floats", table("bf16", "COEF_BASE_DEGREE_TABLE", 10, 3), [(0 << 5) | 8, (9 << 5) | 6, (16 << 5) | 8])
    check("COEF_BASE_DEGREE_TABLE int8", table("int8", "COEF_BASE_DEGREE_TABLE", 10, 3), [(0 << 5) | 2, (9 << 5) | 3, (16 << 5) | 3])
    check("LANE_DRAIN_CYCLES_TABLE int8", table("int8", "LANE_DRAIN_CYCLES_TABLE", 4, 3), [3, 3, 6])
    check("LANE_DRAIN_CYCLES_TABLE fp32 tanh", table("fp32", "LANE_DRAIN_CYCLES_TABLE", 4, 3), [0, 0, 10])
    check("kind latencies int8", [kind_lat("int8", k) for k in KINDS], [1, 1, 0, 0, 0, 4, 6])
    check("fmt_add latency by width", [kind_lat(f, "add", d) for f, d in (("fp32", 32), ("bf16", 32), ("bf16", 16), ("int8", 32))], [5, 5, 5, 1])
    check("fmt_mul latency by width", [kind_lat(f, "mul", d, e) for f, d, e in (("fp32", 32, 32), ("bf16", 16, 16), ("bf16", 16, 32), ("int8", 8, 16), ("int8", 8, 32))],
          [8, 3, 3, 1, 1])
    check("cflags", cflags("int8", "requantize").split()[:2], ["-DFMT_INT8", "-DPKG_DATA_WIDTH=8"])
    check("cflags always carry both widths", [x for x in cflags("bf16", "add", 16).split() if "DATA_WIDTH=" in x and "PKG" not in x],
          ["-DWRAPPER_DATA_WIDTH=16", "-DEXT_DATA_WIDTH=16"])
    check("kind widths: defaults", [kind_widths("bf16", "add"), kind_widths("int8", "mul"), kind_widths("fp32", "mul"), kind_widths("int8", "cmp")],
          [(32, 32), (8, 16), (32, 32), (8, 8)])
    for two in ({"FMT_INT8", "FMT_BF16"}, {"FMT_INT8", "FMT_FP32"}, {"FMT_BF16", "FMT_FP32"}, {"FMT_INT8", "FMT_BF16", "FMT_FP32"}):
        try:
            read(defines=two)
            check(f"{sorted(two)} rejected", "accepted", "rejected")
        except ValueError as e:
            check(f"{sorted(two)} rejected", "SIENNA_FMT_ERROR" in str(e), True)
    try:
        consts("fp16")
        check("fp16 rejected", "accepted", "rejected")
    except ValueError:
        check("fp16 rejected", True, True)
    check("literal 32'hFF80_0000", _literal("32'hFF80_0000"), (0xFF800000, 32))
    check("concat", _value("{5'd16, 5'd3}"), (16 << 5) | 3)
    print(f"fmt_pkg selftest: {checks[0]} checks, {fails[0]} failures")
    print(f"RESULT: {'PASSED' if fails[0] == 0 else 'FAILED'}")
    return fails[0]


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--fmt", choices=FORMATS + ("default",), default="fp32")
    ap.add_argument("--get", help="print one constant")
    ap.add_argument("--json", action="store_true", help="every constant and type as JSON")
    ap.add_argument("--cflags", metavar="KIND", help="the sweep harness's C defines for a kind")
    ap.add_argument("--data-width", type=int, help="fmt_mul's or fmt_add's DATA_WIDTH")
    ap.add_argument("--ext-data-width", type=int, help="fmt_mul's EXT_DATA_WIDTH")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        sys.exit(1 if selftest() else 0)
    if a.get:
        print(get(a.fmt, a.get))
    elif a.cflags:
        print(cflags(a.fmt, a.cflags, a.data_width, a.ext_data_width))
    elif a.json:
        print(json.dumps(read(a.fmt), indent=1))
    else:
        ap.error("nothing to do: --get, --cflags, --json or --selftest")


if __name__ == "__main__":
    main()
