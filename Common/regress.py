"""make regression's engine, shared by every repo that holds this library: points, each run in a private copy of the tree, one result per point, one table."""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

ANSI = re.compile(r"\x1b\[[0-9;]*m")
FIRING = re.compile(r"^.*(?:Assertion failed|%Error).*$", re.M)  # a firing assertion leaves the exit status clean, so the log is the witness
MAKE_VARS = ("MAKEFLAGS", "MAKELEVEL", "MFLAGS", "MAKEOVERRIDES", "SMALL", "FMT", "REG_DIR", "REG_RUN", "EXTRA_FLAGS", "SIM_ARGS",
             "PLUSARGS", "TRACE", "OPT_FAST", "SIM_THREADS")  # a point checks the design as checked in, not the caller's variables
COPY_SKIP_DIRS = (".git", "results", "__pycache__", "VCS")  # a tree without git: generated outputs a copy leaves out
COPY_SKIP_PREFIX = ("Verilator", "VIVADO")
SIZES, SIZES_SMALL = (8, 16, 32, 64), (8, 16)  # SMALL=1: what a 16 GB machine can build


def pow2_tiles(n: int) -> list:
    """Every power-of-2 tile size that divides N, e.g. N = 16: [2, 4, 8, 16]."""
    return [2 ** i for i in range(1, n.bit_length()) if n % 2 ** i == 0]


class Spec:
    """One repo's regression: its points and each point's command, environment, verdict and reason not to run."""

    title = "REGRESSION"
    formats = ()  # the format axis; empty: the points take no format
    sized = False  # True: points per N and tile size, and SMALL keeps N = 8 and 16
    reported = frozenset()  # points shown in the table but not counted in the verdict
    drop = ()  # the repo's own make variables, kept from a point's environment
    artifacts = ("testbenches/results",)  # a failing point keeps these trees of its copy

    def __init__(self, root: str, results: str):
        self.root, self.results = root, results

    def points(self, small: bool, formats: list) -> list:
        raise NotImplementedError

    def parse(self, name: str) -> dict:
        """The point's fields, 'n' among them (0 without a size); ValueError on a name the repo does not run."""
        raise NotImplementedError

    def argv(self, name: str, opts) -> list:
        raise NotImplementedError

    def env(self, name: str, env: dict) -> dict:
        return env

    def verdict(self, name: str, text: str, rc) -> str:
        return common_verdict(text, rc) or "PASS"

    def not_run(self, name: str, opts):
        return None


def common_verdict(text: str, rc):
    """FAIL on a non-zero exit or a firing assertion / %Error line, else None (the point's own verdict decides)."""
    if rc:
        return f"FAIL (exit {rc})"
    fired = FIRING.search(ANSI.sub("", text))
    return f"FAIL (log: {fired.group(0).strip()[:60]})" if fired else None


def marker_verdict(text: str, rc, need=(), bad=(), firing=True) -> str:
    """PASS when the exit and log are clean, every need pattern is in the log and no bad one is; the first unmet rule otherwise."""
    v = common_verdict(text, rc) if firing else (f"FAIL (exit {rc})" if rc else None)  # firing=False: a check whose log shows the error it provokes
    if v:
        return v
    text = ANSI.sub("", text)
    for b in bad:
        m = re.search(b, text, re.M)
        if m:
            line = text[text.rfind("\n", 0, m.start()) + 1:(text.find("\n", m.end()) + 1 or len(text) + 1) - 1]  # the whole line it is on
            return f"FAIL (log: {line.strip()[:60]})"
    for n in need:
        if not re.search(n, text, re.M):
            return f"FAIL (no '{n.strip('^$')}')"
    return "PASS"


def sim_threads(flags: str, cpus: int):
    """Simulation threads of one point: None alone (each build keeps its default), cores / N under make -jN, 1 under an unlimited -j."""
    jobs = re.search(r"(?:^|\s)-j(\d*)(?=\s|$)", flags or "")
    if not jobs:
        return None
    return str(max(1, cpus // int(jobs.group(1))) if jobs.group(1) else 1)  # Verilator's threads spin: N simulations of all cores crawl


def _cores() -> int:
    """The cores this process may use: its affinity where the OS has one (Linux), else every core."""
    return len(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else os.cpu_count() or 1


def point_env(spec: Spec, name: str, flags: str = None, cpus: int = None) -> dict:
    """A point's environment: none of the caller's make variables, no waveforms, -O0 builds from N = 32 (-Os takes hours there), its share of the cores."""
    env = {k: v for k, v in os.environ.items() if k not in MAKE_VARS + tuple(spec.drop)}
    env["TRACE"] = "0"
    if spec.parse(name)["n"] >= 32:
        env["OPT_FAST"] = "-O0"
    t = sim_threads(os.environ.get("MAKEFLAGS", "") if flags is None else flags, cpus or _cores())
    if t:
        env["SIM_THREADS"] = t
    return spec.env(name, env)


def _repo_files(repo: str, rel: str = "") -> list:
    """Tracked and untracked, not ignored, files of a git checkout and its submodules, relative to the top."""
    git = lambda *a: subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True, check=True).stdout.split("\0")
    links = {x.split("\t", 1)[1] for x in git("ls-files", "-z", "-s") if x.startswith("160000 ")}
    out = []
    for f in filter(None, git("ls-files", "-z", "--cached", "--others", "--exclude-standard")):
        if f in links:
            if os.path.exists(os.path.join(repo, f, ".git")):
                out += _repo_files(os.path.join(repo, f), os.path.join(rel, f))
        elif "__pycache__" not in f.split("/"):
            out.append(os.path.join(rel, f))
    return out


def copy_tree(src: str, dst: str) -> None:
    """Copies the tree as a fresh checkout holds it: git's files without the ignored outputs (stale stimulus, builds, results)."""
    if os.path.exists(os.path.join(src, ".git")):
        files = _repo_files(src)
    else:
        files = []
        for r, ds, fs in os.walk(src):
            ds[:] = [x for x in ds if x not in COPY_SKIP_DIRS and not x.startswith(COPY_SKIP_PREFIX)]
            files += [os.path.relpath(os.path.join(r, f), src) for f in fs if not f.endswith((".vcd", ".fst"))]
    for f in files:
        s, t = os.path.join(src, f), os.path.join(dst, f)
        if os.path.lexists(s) and not os.path.isdir(s):
            os.makedirs(os.path.dirname(t), exist_ok=True)
            shutil.copy2(s, t, follow_symlinks=False)


def _formats(spec: Spec, text: str) -> list:
    """The formats a comma-separated --formats names; every format of the repo when empty."""
    if not spec.formats:
        return []
    fs = [f for f in (text or "").split(",") if f]
    bad = [f for f in fs if f not in spec.formats]
    if bad:
        sys.exit(f"--formats {','.join(bad)}: formats are {', '.join(spec.formats)}")
    return fs if text is not None else list(spec.formats)


def run_point(spec: Spec, a) -> None:
    """Runs one point in a private copy of the tree; writes <results>/<name>.log and .json; exit 1 unless it passed (0 with --keep-going)."""
    try:
        spec.parse(a.name)
    except ValueError as e:
        sys.exit(f"error: {e}")
    base = os.path.join(os.path.abspath(a.results), a.name)
    os.makedirs(os.path.dirname(base), exist_ok=True)
    for x in (".json", ".log"):  # a result left by an earlier run must not stand for this one
        if os.path.exists(base + x):
            os.remove(base + x)
    shutil.rmtree(base + ".artifacts", ignore_errors=True)
    rec = {"name": a.name, "run": a.run, "rc": None, "secs": 0.0, "not_run": spec.not_run(a.name, a),
           "host": os.uname().nodename, "start": time.strftime("%Y-%m-%d %H:%M:%S")}
    t0 = time.time()
    with open(base + ".log", "w") as log:
        log.write(f"# point {a.name}  run {a.run or '-'}  host {rec['host']}  start {rec['start']}\n")
        if rec["not_run"]:
            log.write(f"NOT RUN: {rec['not_run']}\n")
        else:
            work = tempfile.mkdtemp(prefix="regression_point.")
            try:
                copy_tree(spec.root, work)
                cmd, env = spec.argv(a.name, a), point_env(spec, a.name)
                log.write(f"# command: {' '.join(cmd)}\n# env: {' '.join(f'{k}={env[k]}' for k in ('TRACE', 'OPT_FAST', 'SIM_THREADS') if k in env)}\n")
                log.flush()
                rec["rc"] = subprocess.run(cmd, cwd=work, env=env, stdout=log, stderr=subprocess.STDOUT).returncode
                if rec["rc"]:  # a failing point keeps its per-test logs and dumps
                    for sub in spec.artifacts:
                        r = os.path.join(work, sub)
                        if os.path.isdir(r):
                            shutil.copytree(r, os.path.join(base + ".artifacts", sub), dirs_exist_ok=True)
            except Exception as e:  # noqa: BLE001  a point that cannot copy or start fails; it does not stop make regression
                log.write(f"point did not run: {e!r}\n")
                rec["rc"] = 127
            finally:
                shutil.rmtree(work, ignore_errors=True)
        rec["secs"] = round(time.time() - t0, 1)
        log.write(f"# exit {rec['rc']} after {rec['secs']} s\n")
    json.dump(rec, open(base + ".json", "w"))
    v = f"NOT RUN ({rec['not_run']})" if rec["not_run"] else spec.verdict(a.name, open(base + ".log", errors="replace").read(), rec["rc"])
    print(f"{a.name}: {v}  {rec['secs']:.0f} s  {base}.log", flush=True)
    sys.exit(0 if v == "PASS" or a.keep_going else 1)


def summary(spec: Spec, a) -> None:
    """Reads every expected point's result under --results and writes <results>/regression.log; exit 1 on any gated FAIL or NOT RUN, or no points."""
    fmts = _formats(spec, a.formats)
    pts = spec.points(a.small, fmts)
    if not pts:
        print(f"{spec.title} FAIL: no points selected")
        sys.exit(1)
    res, rows = os.path.abspath(a.results), []
    for p in pts:
        base = os.path.join(res, p)
        try:
            rec = json.load(open(base + ".json"))
        except (OSError, ValueError):
            rec = None
        if rec is None:
            v, secs = f"NOT RUN (no result in {res})", 0.0
        elif a.run and rec.get("run") != a.run:
            v, secs = f"NOT RUN (stale: result of run {rec.get('run') or '-'}, not {a.run})", rec.get("secs", 0.0)
        elif rec.get("not_run"):
            v, secs = f"NOT RUN ({rec['not_run']})", 0.0
        else:
            text = open(base + ".log", errors="replace").read() if os.path.exists(base + ".log") else ""
            v, secs = (spec.verdict(p, text, rec.get("rc")) if text else "NOT RUN (result without its log)"), rec.get("secs", 0.0)
        rows.append((p, v, p not in spec.reported, secs, base + ".log", rec is not None))
    gated = [r for r in rows if r[2]]
    passed = sum(r[1] == "PASS" for r in gated)
    failed = sum(r[1].startswith("FAIL") for r in gated)
    not_run = sum(r[1].startswith("NOT RUN") for r in gated)
    sel = ("N = 8, 16" if a.small else "N = 8 to 64") + ", every tile size" if spec.sized else ""
    sel += (", " if sel else "") + " ".join(fmts) if spec.formats else ""
    w, vw = max(len(p) for p in pts) + 2, max([len(r[1]) + 22 for r in rows] + [40])
    table = [f"{spec.title}: {sel + '; ' if sel else ''}run {a.run or 'any'}; {len(pts)} points", f"{'point':<{w}}{'verdict':<{vw}}{'secs':>9}  log"]
    table += [f"{p:<{w}}{(v if g else v + ', reported, not gated'):<{vw}}{s:9.1f}  {lp}" for p, v, g, s, lp, _ in rows]
    ok_all = bool(gated) and passed == len(gated)
    last = f"{spec.title} {'PASS' if ok_all else 'FAIL'}: {passed} of {len(gated)} gated points passed"
    last += (f", {failed} FAIL" if failed else "") + (f", {not_run} NOT RUN" if not_run else "") + (" (no point ran)" if not any(r[5] for r in rows) else "")
    last += f"; {len(rows) - len(gated)} reported, not gated" if len(rows) > len(gated) else ""
    hints = sorted({r[1][9:-1] for r in rows if r[1].startswith("NOT RUN (") and "no result" not in r[1] and "stale" not in r[1] and "without its log" not in r[1]})
    table += [f"not run: {h}" for h in hints] + [last]
    os.makedirs(res, exist_ok=True)
    open(os.path.join(res, "regression.log"), "w").write("\n".join(table) + "\n")
    print("\n".join(table) + f"\ntable: {os.path.join(res, 'regression.log')}")
    sys.exit(0 if ok_all else 1)


def main(spec: Spec, argv=None) -> None:
    """--action points (the list), point (one point), summary (the table)."""
    ap = argparse.ArgumentParser(description=f"{spec.title}: make regression's points and table", allow_abbrev=False)
    ap.add_argument("--action", choices=("points", "point", "summary"), required=True)
    ap.add_argument("--name", help="point: its name, as --action points lists it")
    ap.add_argument("--results", default=spec.results)
    ap.add_argument("--run", default="", help="the run a result belongs to; summary: accept only this run's (empty: any)")
    ap.add_argument("--keep-going", action="store_true", help="point: exit 0 whatever the verdict (the summary decides)")
    ap.add_argument("--small", action="store_true", help="N = 8 and 16 only")
    ap.add_argument("--formats", default=None, help="comma-separated formats (default: every format)")
    ap.add_argument("--model-dir", default="", help="points that need a model directory")
    a = ap.parse_args(argv)
    a.model_dir = os.path.abspath(a.model_dir) if a.model_dir else ""  # a point runs in a private copy, where a relative path names nothing
    if a.action == "points":
        print("\n".join(spec.points(a.small, _formats(spec, a.formats))))
    elif a.action == "point":
        if not a.name:
            ap.error("--action point needs --name")
        run_point(spec, a)
    else:
        summary(spec, a)

