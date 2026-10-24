#!/usr/bin/env python3
"""Equivalence of each per-width integer unit with the generic integer unit it replaces (results and done cycles, 0 differences). The float
pairs (the bf16 units against fpMultiplier, fpAdder, fpMulWiden and fpNarrow at (8, 7), and the fp32 copy gate) left with those generic units.
Builds each eq_tops.sv top, runs its slices on every core, writes one EQUIV line per pair to results/equiv/equiv.log."""
import argparse
import concurrent.futures as cf
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PAIRS16_SLICES = [("pairs16", {"lo": hb}) for hb in range(256)]  # every 16-bit pair: 2^32
RANDOM_SLICES = lambda n, k=8: [("random", {"n": n // k, "seed": 500 + i}) for i in range(k)]
PLAN = {  # top: (operand bits, combinational, slices, what it proves)
    "eq_int8_mul": (8, False, [("pairs8", {})], "int8Multiplier == intMultiplier #(8), all 2^16 pairs"),
    "eq_int16_mul": (16, False, PAIRS16_SLICES, "int16Multiplier == intMultiplier #(16), all 2^32 pairs"),
    "eq_int24_mul": (24, False, [("corners", {})] + RANDOM_SLICES(10**8),
                     "int24Multiplier checked against intMultiplier #(24) on corners + 10^8 random (not a proof; its text is the generic one at 24 bits)"),
    "eq_int32_add": (32, False, [("corners", {})] + RANDOM_SLICES(10**8),
                     "int32Adder checked against intAdder #(32) on corners + 10^8 random (not a proof; its text is the generic one at 32 bits)"),
}


def provenance():
    """The tree's revision and status: git where the tree has it, else TREE_REVISION (a farm snapshot carries no .git; the launcher sets it)."""
    try:
        rev = subprocess.run(["git", "-C", HERE, "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
        dirty = subprocess.run(["git", "-C", HERE, "status", "--short"], capture_output=True, text=True, check=True).stdout.strip()
        return f"{rev} ({'clean' if not dirty else str(len(dirty.splitlines())) + ' files changed'})"
    except (subprocess.CalledProcessError, FileNotFoundError):
        return os.environ.get("TREE_REVISION", "unknown: no git in this tree and TREE_REVISION unset")


def build(top, bits, comb, log):
    r = subprocess.run(["make", "-s", "--no-print-directory", "-C", HERE, "eq-build", f"TOP={top}", f"BITS={bits}"] + (["COMB=1"] if comb else []),
                       capture_output=True, text=True)
    log.write(r.stdout + r.stderr)
    built = [x.split()[-1] for x in r.stdout.splitlines() if x.startswith(f"eq-build {top}: /")]
    if r.returncode or len(built) != 1:
        raise RuntimeError(f"eq-build {top}: {r.stdout[-300:]}{r.stderr[-300:]}")
    return built[0]  # the harness, from its own line: under a parent make, -C also prints its directory


def run(exe, mode, args):
    cmd = [exe, "--mode", mode] + sum(([f"--{k}", str(v)] for k, v in args.items()), [])
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--tops", default="", help="comma-separated tops (default: all)")
    ap.add_argument("--jobs", type=int, default=len(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else os.cpu_count())
    ap.add_argument("--scale", type=float, default=1.0, help="multiply every random count (a quick run uses < 1)")
    ap.add_argument("--slices", type=int, default=0, help="run only the first k slices of each pair (a quick run)")
    ap.add_argument("--out", default=os.path.join(HERE, "results", "equiv"))
    a = ap.parse_args()
    unknown = [t for t in a.tops.split(",") if t and t not in PLAN]
    if unknown:
        ap.error(f"unknown tops {unknown}; the plan has {', '.join(PLAN)}")
    tops = [t for t in PLAN if not a.tops or t in a.tops.split(",")]
    os.makedirs(a.out, exist_ok=True)
    log = open(os.path.join(a.out, "equiv.log"), "w")
    log.write(f"# tree {provenance()}\n")
    print(f"# tree {provenance()}", flush=True)
    lines = []
    for top in tops:
        bits, comb, plan, what = PLAN[top]
        t0 = time.time()
        try:
            exe = build(top, bits, comb, log)
        except RuntimeError as e:
            lines.append(f"EQUIV {top}: FAIL (build) {e}")
            continue
        full = len(plan)
        plan = plan[:a.slices] if a.slices else plan
        if a.slices or a.scale != 1.0:  # a quick run claims only what it ran
            what = f"QUICK RUN ({len(plan)} of {full} slices, random counts x {a.scale:g}), not the proof of: {what}"
        if a.scale != 1.0:
            plan = [(m, {k: (max(1, int(v * a.scale)) if k == "n" else v) for k, v in args.items()}) for m, args in plan]
        n = rd = dd = bad = 0
        with cf.ThreadPoolExecutor(a.jobs) as ex:
            for rc, out in ex.map(lambda p: run(exe, *p), plan):
                m = re.search(r"checked (\d+) result_diff (\d+) done_diff (\d+)", out)
                for x in out.splitlines():
                    if x.startswith("EQ"):
                        log.write(x + "\n")
                if rc or not m or "RESULT: PASSED" not in out:
                    bad += 1
                if m:
                    n, rd, dd = n + int(m.group(1)), rd + int(m.group(2)), dd + int(m.group(3))
        v = "PASS" if bad == 0 and rd == 0 and dd == 0 and n > 0 else "FAIL"
        g = f"EQUIV {top}: {v}  {what}: checked {n}, result differences {rd}, done differences {dd}, slices {len(plan)} (failed {bad})  {time.time() - t0:.0f} s"
        lines.append(g)
        log.write(g + "\n")
        log.flush()
        print(g, flush=True)
    ok = sum(" PASS " in x for x in lines)
    tail = f"EQUIV: {ok} of {len(lines)} pairs equal"
    log.write(tail + "\n")
    print(tail)
    print(f"RESULT: {'PASSED' if lines and ok == len(lines) else 'FAILED'}")
    sys.exit(0 if lines and ok == len(lines) else 1)


if __name__ == "__main__":
    main()
