#!/usr/bin/env python3
"""The unit sweeps of the restructure's gate table, per format: builds each kind's harness, runs its slices on every core,
rechecks a 10^6-row sample of the harness's verdicts with truefn.py, and writes one GATE line per kind to results/sweep/<fmt>.log.
int8Requantizer and int8QuantizedAdder run on parameter sets written here: real scales across the encoders' whole domain and the words
ipu.encode_scale and ipu.encode_add give them (--write-params KIND FILE writes one kind's sets alone)."""
import argparse
import concurrent.futures as cf
import math
import os
import re
import subprocess
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
COMMON = os.path.join(HERE, "..", "Common")
sys.path.insert(0, os.path.join(COMMON, "models"))
import fmt_pkg  # noqa: E402
import int8_vectors  # noqa: E402
import ipu  # noqa: E402
import truefn  # noqa: E402

PAIRS16_SLICES = [("pairs16", {"lo": hb}) for hb in range(256)]  # every 16-bit pair: 2^32, by a's high byte
WORDS32_SLICES = [("unary32", {"lo": hb}) for hb in range(256)]  # every 32-bit word, by its high byte
RANDOM_SLICES = lambda n, k=8: [("random", {"n": n // k, "seed": 100 + i}) for i in range(k)]  # n random vectors in k slices
CANCEL_SLICES = lambda n, k=8: [("cancel", {"n": n // k, "seed": 200 + i}) for i in range(k)]
SPLIT_SLICES = lambda mode, total, k: [(mode, {"first": i * (total // k), "count": total // k + (total % k if i == k - 1 else 0)}) for i in range(k)]

PARAM_SLICES = [("params", {"split": 64})] + [("params_random", {"n": 10**8 // 8, "seed": 300 + i}) for i in range(8)]  # every set, split; random
PLAN = {  # (fmt, kind[/DATA_WIDTH[/EXT_DATA_WIDTH]]): [(mode, args)], the gate table's rows: fmt_mul and fmt_add at every width, the package
    # functions fmt_greater_than (cmp) and fmt_relu, and the units fp32ToBf16, int8Requantizer and int8QuantizedAdder (no wrapper; swept so the miss list covers them)
    ("fp32", "mul"): [("dense2", {})] + RANDOM_SLICES(10**8), ("fp32", "add"): [("dense2", {})] + RANDOM_SLICES(10**8) + CANCEL_SLICES(10**7),  # 32 is every fp32 width:
    ("fp32", "add@lane"): [("dense2", {})] + RANDOM_SLICES(10**8) + CANCEL_SLICES(10**7),  # the accumulator rule above, and GPNAE's lane rule on |t| here
    ("fp32", "cmp"): [("dense2", {})] + RANDOM_SLICES(10**8), ("fp32", "relu"): [("dense1", {})] + RANDOM_SLICES(10**8), ("fp32", "narrow"): RANDOM_SLICES(10**7),
    ("bf16", "mul/16/32"): PAIRS16_SLICES, ("bf16", "mul/16/16"): PAIRS16_SLICES, ("bf16", "add"): [("dense2", {})] + RANDOM_SLICES(10**8) + CANCEL_SLICES(10**7), ("bf16", "add/16"): PAIRS16_SLICES,
    ("bf16", "cmp"): PAIRS16_SLICES, ("bf16", "relu"): [("unary16", {})], ("bf16", "narrow"): WORDS32_SLICES,
    ("int8", "mul/8/32"): [("pairs8", {})], ("int8", "mul/8/16"): [("pairs8", {})],
    ("int8", "add"): [("dense_int", {})] + RANDOM_SLICES(10**8), ("int8", "cmp"): [("pairs8", {})],
    ("int8", "relu"): [("pairs8", {})],  # every (q, zp)
    ("int8", "requantize"): PARAM_SLICES, ("int8", "quantized_add"): PARAM_SLICES,
}
REQUANT_FACTORS = (1.0, 1 + 2.0**-24, 1 + 2.0**-23, 1.25, 1.5, math.sqrt(2.0), 1.75, 2 - 2.0**-23, 2 - 2.0**-24, 2 - 2.0**-25)  # mantissas of each binade
REQUANT_BINADES = range(-40, 10)  # 2^-40 to 2^10: past the encoder's flush (2^-32) and saturation (2^8) ends
REQUANT_ZPS = (-128, -1, 0, 1, 127)


def requantize_sets():
    """(s, m, e, zp, lo, hi) rows: every binade of REQUANT_BINADES at REQUANT_FACTORS and 6 log-uniform mantissas, each scale under every zero point
    of REQUANT_ZPS and each of int8_vectors.clamps; (m, e) = ipu.encode_scale(s), the words the host sends."""
    rng = np.random.default_rng(11)
    rows = []
    for binade in REQUANT_BINADES:
        for factor in REQUANT_FACTORS + tuple(float(x) for x in np.exp2(rng.uniform(0.0, 1.0, 6))):
            scale = math.ldexp(factor, binade)
            mantissa, shift = ipu.encode_scale(scale)
            rows += [(scale, mantissa, shift, zero_point, low, high) for zero_point in REQUANT_ZPS for low, high in int8_vectors.clamps(zero_point)]
    return rows


def quantized_add_sets(n_random=2000):
    """(r1, r2, m1, m2, e, z1, z2, zo, lo, hi) rows: int8_vectors.add_corner_sets, then n_random ratio pairs log-uniform over [2^-14, 2^23) (every
    fourth a near cancellation r2 = r1 (1 + d), |d| < 2^-10), on ADD_ZP_SETS in turn; (m1, m2, e) = ipu.encode_add(r1, r2)."""
    rng = np.random.default_rng(13)
    top = 2.0 ** ipu.ADD_MAX_RATIO_LOG2 * (1 - 2.0 ** -12)
    pairs = [tuple(c) for c in int8_vectors.add_corner_sets()]
    for k in range(n_random):
        r1 = float(int8_vectors.log_uniform(rng, 2.0 ** -14, top, 1)[0])
        r2 = r1 * (1 + float(rng.uniform(-2.0 ** -10, 2.0 ** -10))) if k % 4 == 0 else float(int8_vectors.log_uniform(rng, 2.0 ** -14, top, 1)[0])
        pairs.append((r1, min(r2, top)) + int8_vectors.ADD_ZP_SETS[k % len(int8_vectors.ADD_ZP_SETS)])
    rows = []
    for r1, r2, z1, z2, zo, lo, hi in pairs:
        m1, m2, e = ipu.encode_add(r1, r2)
        rows.append((r1, r2, m1, m2, e, z1, z2, zo, lo, hi))
    return rows


PARAM_SETS = {"requantize": requantize_sets, "quantized_add": quantized_add_sets}


def write_params(kind, path):
    """One kind's parameter sets, a line each, reals as C99 hex floats (sweep_fmt.cpp's --params); returns the set count."""
    rows = PARAM_SETS[kind]()
    with open(path, "w") as f:
        f.write(f"# {kind}: " + ("s m e zp lo hi" if kind == "requantize" else "r1 r2 m1 m2 e z1 z2 zo lo hi") + " (reals as C99 hex floats)\n")
        for r in rows:
            f.write(" ".join(float(v).hex() if isinstance(v, float) else str(int(v)) for v in r) + "\n")
    return len(rows)


def harness_size(exe, mode, params):
    """The harness's own vector count for a mode (--size), so a split covers every vector it would run."""
    r = subprocess.run([exe, "--mode", mode, "--params", params, "--size"], capture_output=True, text=True)
    m = re.search(r"^SIZE (\d+)$", r.stdout, re.M)
    if r.returncode or not m:
        raise RuntimeError(f"{exe} --size: {r.stdout[-200:]}{r.stderr[-200:]}")
    return int(m.group(1))
SAMPLE = 10**6  # rows of each kind's sample (the spec's 10^6-vector cross-check), spread over its slices


def provenance():
    """The tree's revision and status: git where the tree has it, else TREE_REVISION (a farm snapshot carries no .git; the launcher sets it)."""
    try:
        rev = subprocess.run(["git", "-C", HERE, "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
        dirty = subprocess.run(["git", "-C", HERE, "status", "--short"], capture_output=True, text=True, check=True).stdout.strip()
        return f"{rev} ({'clean' if not dirty else str(len(dirty.splitlines())) + ' files changed'})"
    except (subprocess.CalledProcessError, FileNotFoundError):
        return os.environ.get("TREE_REVISION", "unknown: no git in this tree and TREE_REVISION unset")


def build(fmt, kind, data_width, ext_data_width, log, rule=None):
    args = ["make", "-s", "--no-print-directory", "-C", HERE, "sweep-build", f"FMT={fmt}", f"KIND={kind}"] + \
        ([f"DATA_WIDTH={data_width}"] if data_width else []) + ([f"EXT_DATA_WIDTH={ext_data_width}"] if ext_data_width else []) + \
        ([f"RULE={rule}"] if rule else [])
    r = subprocess.run(args, capture_output=True, text=True)
    log.write(r.stdout + r.stderr)
    built = [x.split()[-1] for x in r.stdout.splitlines() if x.startswith(f"sweep-build {kind} {fmt}: /")]
    if r.returncode or len(built) != 1:
        raise RuntimeError(f"sweep-build {kind} {fmt}: {r.stdout[-400:]}{r.stderr[-400:]}")
    return built[0]  # the harness, from its own line: under a parent make, -C also prints its directory


def expected_kind(fmt, kind, data_width, ext_data_width, rule):
    """The rule a slice must report for its plan key: the widening product is mul_acc, fmt_add at the accumulator width is acc_add
    (the lane rule with @lane), anything else its own kind."""
    acc = 32  # ACC_DATA_WIDTH in every format
    if kind == "mul" and ext_data_width and int(ext_data_width) == acc and int(data_width or 0) != acc:
        return "mul_acc"
    if kind == "add" and rule != "lane" and int(data_width or acc) == acc:
        return "acc_add"
    return kind


def gate_verdict(bad, miss, disagreements, rows, n, ungated, floor_only):
    """PASS when every slice passed, nothing missed, the recheck agreed, and not every gated row was decided by the floor (|t| within one step
    of zero, or an error over the tolerance within one step): a sweep that only met the floor tested nothing (a misdecode)."""
    if bad or miss or disagreements or rows == 0:
        return "FAIL"
    if n > ungated and floor_only == n - ungated:
        return "FAIL (every gated row is decided by the floor)"
    return "PASS"


def selftest():
    """gate_verdict on hand cases, among them rs3_r4f_ex_bf16's add/16: 4,294,967,296 rows, all within 2^-126 of t = 0 (bf16 words read as fp32)."""
    cases = [((0, 0, 0, 2000384, 4294967296, 0, 4294967296), "FAIL (every gated row is decided by the floor)"),  # the misdecode
             ((0, 0, 0, 2000384, 4294967296, 0, 21000), "PASS"),  # the real add/16 shape: a few rows near zero
             ((0, 0, 0, 131072, 65536, 254, 65282), "FAIL (every gated row is decided by the floor)"),
             ((0, 0, 0, 131072, 65536, 65536, 0), "PASS"),  # every row ungated: nothing gated on the floor
             ((1, 0, 0, 10, 10, 0, 0), "FAIL"), ((0, 1, 0, 10, 10, 0, 0), "FAIL"), ((0, 0, 1, 10, 10, 0, 0), "FAIL")]
    bad = 0
    for args, want in cases:
        got = gate_verdict(*args)
        if got != want:
            bad += 1
            print(f"[FAIL] gate_verdict{args}: got {got}, want {want}")
    print(f"sweep selftest: {len(cases)} checks, {bad} failures")
    return bad


EXACT_KINDS = {("int8", "mul"), ("int8", "add"), ("int8", "cmp"), ("int8", "relu"), ("fp32", "cmp"), ("bf16", "cmp"), ("fp32", "narrow"),
               ("bf16", "narrow")}  # judged exactly: their worst is a distance (0 when every output is the reference)
CODE_KINDS = ("requantize", "quantized_add")  # int8 outputs under max(1% |t|, one step)


def accuracy(fmt, kind, worst, worst_steps, worst_relative, relative_rows):
    """A GATE line's accuracy: floats in percent of |t|; the code kinds in percent of the decimal value |t| over the rows 1% decides, and in output
    steps over every row (a row within one step passes on the floor and has no percent of its own); exact kinds as a distance."""
    if kind in CODE_KINDS:
        rel = f"{100 * worst_relative:.4g}%" if relative_rows else "none"
        return f"worst {rel} of |t| over the {relative_rows} rows the 1% tolerance decides, worst {worst_steps:.4g} steps over every row"
    if (fmt, kind) in EXACT_KINDS:
        return f"worst distance {worst:.4g} (exact)"
    return f"worst {100 * worst:.4g}% of |t|"


def run_slice(exe, mode, args, sample, sample_n):
    cmd = [exe, "--mode", mode] + sum(([f"--{k}", str(v)] for k, v in args.items()), []) + ["--sample", sample, "--sample-n", str(sample_n)]
    t = time.time()
    r = subprocess.run(cmd, capture_output=True, text=True)
    return cmd, r.returncode, r.stdout + r.stderr, time.time() - t


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--fmt", required=True, choices=truefn.FORMATS)
    ap.add_argument("--kinds", default="", help="comma-separated kinds (default: every kind the plan has for the format)")
    ap.add_argument("--jobs", type=int, default=len(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else os.cpu_count())
    ap.add_argument("--scale", type=float, default=1.0, help="multiply every random count (a probe uses < 1); exhaustive modes stay whole")
    ap.add_argument("--slices", type=int, default=0, help="run only the first k slices of each kind (a probe)")
    ap.add_argument("--out", default=os.path.join(HERE, "results", "sweep"))
    ap.add_argument("--selftest", action="store_true", help="gate_verdict on hand cases (no simulator)")
    ap.add_argument("--write-params", nargs=2, metavar=("KIND", "FILE"), help="write one kind's parameter sets and stop")
    if "--selftest" in sys.argv[1:]:
        sys.exit(1 if selftest() else 0)
    if "--write-params" in sys.argv[1:]:
        k, path = sys.argv[sys.argv.index("--write-params") + 1:][:2]
        if k not in PARAM_SETS:
            sys.exit(f"--write-params: {k} has no parameter sets ({', '.join(PARAM_SETS)})")
        print(f"{k}: {write_params(k, path)} sets in {path}")
        sys.exit(0)
    a = ap.parse_args()
    names = {k[1].split("/")[0].split("@")[0] for k in PLAN if k[0] == a.fmt} | {k[1] for k in PLAN if k[0] == a.fmt}
    unknown = [k for k in a.kinds.split(",") if k and k not in names]
    if unknown:
        ap.error(f"unknown kinds {unknown} for {a.fmt}; the plan has {', '.join(sorted(names))}")
    keys = [k for k in PLAN if k[0] == a.fmt and (not a.kinds or k[1].split("/")[0].split("@")[0] in a.kinds.split(",") or k[1] in a.kinds.split(","))]
    os.makedirs(a.out, exist_ok=True)
    log = open(os.path.join(a.out, f"{a.fmt}.log"), "w")
    log.write(f"# tree {provenance()}\n# sweep {a.fmt}: {len(keys)} kinds, {a.jobs} jobs, scale {a.scale}, slices {a.slices or 'all'}\n")
    print(f"# tree {provenance()}", flush=True)
    verdicts = []
    for fmt, key in keys:
        base, _, rule = key.partition("@")  # kind[/DATA_WIDTH[/EXT_DATA_WIDTH]][@rule]
        kind, data_width, ext_data_width = (base.split("/") + [None, None])[:3]
        t0 = time.time()
        try:
            exe = build(fmt, kind, data_width, ext_data_width, log, rule or None)
        except RuntimeError as e:
            verdicts.append(f"GATE {key} {fmt}: FAIL (build) {e}")
            continue
        plan = PLAN[(fmt, key)]
        sdir = os.path.join(a.out, f"{fmt}_{key.replace('/', '_').replace('@', '_')}")
        os.makedirs(sdir, exist_ok=True)
        if kind in PARAM_SETS:  # the sets, then the params mode split into windows of the harness's own size
            params = os.path.join(sdir, "params.txt")
            n_sets = write_params(kind, params)
            log.write(f"# {key}: {n_sets} parameter sets in {params}\n")
            expanded = []
            for m, args in plan:
                if "split" in args:
                    total, k = harness_size(exe, m, params), args["split"]
                    expanded += [(m, {"first": i * (total // k), "count": total // k + (total % k if i == k - 1 else 0), "params": params}) for i in range(k)]
                else:
                    expanded.append((m, dict(args, params=params)))
            plan = expanded
        if a.slices:
            plan = plan[:a.slices]
        if a.scale != 1.0:
            plan = [(m, {k: (max(1, int(v * a.scale)) if k in ("n", "count") else v) for k, v in args.items()}) for m, args in plan]
        per = max(1, SAMPLE // len(plan))
        lines, bad, n, miss, worst, fails, ungated, floor_only = [], 0, 0, 0, -1.0, [], 0, 0
        worst_steps, worst_relative, relative_rows = -1.0, -1.0, 0  # the int8 code kinds' |hw - t| in steps, and in percent of |t| where 1% decides
        with cf.ThreadPoolExecutor(a.jobs) as ex:
            futs = [ex.submit(run_slice, exe, m, args, os.path.join(sdir, f"s{i:03d}.txt"), per) for i, (m, args) in enumerate(plan)]
            for f in futs:
                cmd, rc, out, secs = f.result()
                s = [x for x in out.splitlines() if x.startswith("SWEEP ")]
                lines += [x for x in out.splitlines() if x.startswith("SWEEP")]
                ok = rc == 0 and "RESULT: PASSED" in out and len(s) == 1
                want = expected_kind(fmt, kind, data_width, ext_data_width, rule)
                wdw, wedw = fmt_pkg.kind_widths(fmt, kind, data_width and int(data_width), ext_data_width and int(ext_data_width))
                ran = re.search(r"data_width (\d+) ext_data_width (\d+)", s[0]) if s else None
                if not ran or (int(ran.group(1)), int(ran.group(2))) != (wdw, wedw):  # the widths the harness judged at, from the build
                    ok = False
                    fails.append(f"slice ran at widths {ran.groups() if ran else 'unknown'}, the plan key needs {(wdw, wedw)}")
                if s and s[0].split()[1] != want:  # a slice judged by another kind's rule (a width that did not reach the harness)
                    ok = False
                    fails.append(f"slice ran as {s[0].split()[1]}, the plan key needs {want}")
                if s:
                    m = re.search(r"n (\d+) miss (\d+) worst (\S+)", s[0])
                    n, miss = n + int(m.group(1)), miss + int(m.group(2))
                    u, fl = re.search(r" ungated (\d+)", s[0]), re.search(r" floor_only (\d+)", s[0])
                    if not u or not fl:  # an old harness's line: its counts are unknown
                        ok = False
                        fails.append("SWEEP line without ungated or floor_only")
                    ungated += int(u.group(1)) if u else 0
                    floor_only += int(fl.group(1)) if fl else 0
                    worst = max(worst, float(m.group(3)))
                    c = re.search(r" worst_steps (\S+) worst_relative (\S+) relative_rows (\d+)", s[0])
                    if not c:  # an old harness's line: the code kinds' accuracy would go unreported
                        ok = False
                        fails.append("SWEEP line without worst_steps, worst_relative or relative_rows")
                    else:
                        worst_steps, worst_relative = max(worst_steps, float(c.group(1))), max(worst_relative, float(c.group(2)))
                        relative_rows += int(c.group(3))
                if not ok:
                    bad += 1
                    fails.append(" ".join(os.path.basename(c) for c in cmd[:6]) + f": rc {rc}")
        for x in lines:
            log.write(x + "\n")
        samples = sorted(os.path.join(sdir, p) for p in os.listdir(sdir) if p.endswith(".txt") and p != "params.txt")
        rows = dis = 0
        for p in samples:
            if os.path.getsize(p) == 0:
                continue
            k_, f_, r_, d_, _ = truefn.recheck(p)
            rows, dis = rows + r_, dis + d_
        v = gate_verdict(bad, miss, dis, rows, n, ungated, floor_only)
        g = (f"GATE {key} {fmt}: {v}  n {n}  miss {miss}  ungated {ungated}  floor-decided {floor_only}  {accuracy(fmt, kind, worst, worst_steps, worst_relative, relative_rows)}"
             f"  slices {len(plan)} "
             f"(failed {bad})  recheck {rows} rows, {dis} disagreements  {time.time() - t0:.0f} s")
        verdicts.append(g)
        log.write(g + "\n")
        for x in fails[:5]:
            log.write(f"#   failed slice: {x}\n")
        log.flush()
        print(g, flush=True)
    n_pass = sum(" PASS " in v for v in verdicts)
    tail = f"SWEEP {a.fmt}: {n_pass} of {len(verdicts)} kinds pass the true function"
    log.write("\n".join(verdicts) + "\n" + tail + "\n")
    print(tail)
    print(f"RESULT: {'PASSED' if n_pass == len(verdicts) and verdicts else 'FAILED'}")
    sys.exit(0 if n_pass == len(verdicts) and verdicts else 1)


if __name__ == "__main__":
    main()
