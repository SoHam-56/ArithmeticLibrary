#!/usr/bin/env python3
"""Checks a TB_tfliteAdd dump (each constant set's 65,536 results, q1 outer and q2 inner, 32 hex bytes a line) against ipu.tflite_add or G0b's interpreter outputs."""
import argparse
import contextlib
import hashlib
import io
import json
import os
import subprocess
import sys
import tempfile

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_add_vectors as gv  # noqa: E402
from gen_add_vectors import ipu  # noqa: E402

LINE = 32  # results per dump line


def read_dump(path: str, n_sets: int) -> np.ndarray:
    rows = [ln.strip() for ln in open(path) if ln.strip()]
    want = n_sets * gv.PAIRS // LINE
    if len(rows) != want or any(len(r) != 2 * LINE for r in rows):
        raise ValueError(f"{path}: {len(rows)} lines, expected {want} of {2 * LINE} hex digits")
    return np.frombuffer(bytes.fromhex("".join(rows)), dtype=np.int8).astype(np.int64).reshape(n_sets, gv.PAIRS)


def model(c: dict, rounding: str) -> np.ndarray:
    return np.asarray(ipu.tflite_add(gv.Q1, gv.Q2, *[c[k] for k in gv.FIELDS], rounding), np.int64)


def check(dump: str, consts: list, rounding: str, oracle=None) -> int:
    got = read_dump(dump, len(consts))
    pin = gv.oracle_manifest(oracle)["rounding"] if oracle else None
    if oracle and consts != gv.oracle_consts(oracle):
        raise ValueError(f"{oracle}: the constant sets are not G0b's models' (write them with --consts oracle --oracle {oracle})")
    if oracle and rounding == pin:
        want, ref = gv.oracle_outputs(oracle, len(consts)), f"G0b's interpreter outputs ({oracle})"
        if want.shape != got.shape:
            raise ValueError(f"{oracle}: {want.shape[0]} models, the dump holds {got.shape[0]} sets")
    else:
        want, ref = np.stack([model(c, rounding) for c in consts]), f"ipu.tflite_add ({rounding})"
    bad = got != want
    print(f"check_add: {got.size} results of {len(consts)} constant sets against {ref}, {int(bad.sum())} mismatches")
    for s, i in list(zip(*np.nonzero(bad)))[:20]:
        print(f"  set {s} q1 {gv.Q1[i]} q2 {gv.Q2[i]}: rtl {got[s, i]}, want {want[s, i]}, constants {consts[s]}")
    if oracle and rounding != pin:
        print(f"  info: {int(np.sum(got != gv.oracle_outputs(oracle, len(consts))))} results differ from the interpreter ({pin}), as the other rounding should")
    print(f"RESULT: {'PASSED' if not bad.any() else 'FAILED'}")
    return 0 if not bad.any() else 1


def write_dump(path: str, rows: np.ndarray) -> None:
    """A dump as TB_tfliteAdd writes it, for the self-test."""
    b = (np.asarray(rows, np.int64) & 0xFF).astype(np.uint8).tobytes().hex()
    with open(path, "w") as f:
        f.write("".join(b[i:i + 2 * LINE] + "\n" for i in range(0, len(b), 2 * LINE)))


def fake_oracle(d: str, consts: list, rounding: str) -> np.ndarray:
    """A G0b directory in miniature: one npz per set of ipu.tflite_add's outputs, the manifest with each file's sha256."""
    os.makedirs(d)
    ys, models = [], []
    for j, c in enumerate(consts):
        y = model(c, rounding).astype(np.int8)
        fn = f"g0b_none_{j:03d}.npz"
        np.savez_compressed(os.path.join(d, fn), y=y)
        models.append(dict(file=fn, act="none", add={k: int(c[k]) for k in gv.FIELDS}, sha256=hashlib.sha256(y.tobytes()).hexdigest()))
        ys.append(y.astype(np.int64))
    json.dump(dict(tf_version="selftest", rounding=rounding, models=models), open(os.path.join(d, "manifest.json"), "w"))
    return np.stack(ys)


def raises(f) -> bool:
    """True when f raises ValueError; any other exception counts as not raising it."""
    try:
        f()
    except ValueError:
        return True
    except Exception:  # noqa: BLE001
        return False
    return False


def selftest_checks(errs: list) -> None:
    cs = gv.corner_consts()
    if len(cs) != 154:
        errs.append(f"{len(cs)} corner sets, expected 154")
    if len({tuple(int(c[k]) for k in gv.FIELDS) for c in cs}) != len(cs):
        errs.append(f"{len({tuple(int(c[k]) for k in gv.FIELDS) for c in cs})} distinct corner sets of {len(cs)}")
    if not raises(lambda: gv.discriminators(np.random.default_rng(1), want=10 ** 6)):
        errs.append("discriminators did not raise ValueError when the pool holds too few")
    rr = gv.random_rows(2000, np.random.default_rng(3))
    for r in ipu.ROUNDINGS:
        if not np.array_equal(gv.staged(rr, r, r, r), gv.expected(rr, r)):
            errs.append(f"staged() with every stage {r} differs from ipu.tflite_add")
    if np.array_equal(gv.staged(rr, "DOUBLE", "DOUBLE", "SINGLE"), gv.expected(rr, "DOUBLE")):
        errs.append("staged() ignores the output stage's rounding")
    idisc = gv.input_discriminators(np.random.default_rng(1), want=50)
    if idisc["q1"].size != 300 or len({tuple(int(idisc[k][i]) for k in gv.COLS) for i in range(idisc["q1"].size)}) != 300:
        errs.append(f"{idisc['q1'].size} input-rounding discriminators, expected 300 distinct")
    for b in ipu.ROUNDINGS:
        for name, (i1, i2) in gv.SWAPS.items():
            n = int(np.sum(gv.staged(idisc, gv.other(b) if i1 else b, gv.other(b) if i2 else b, b) != gv.expected(idisc, b)))
            if n < 50:
                errs.append(f"{n} input-rounding discriminators change a {b} result when {name} swap rounding, expected at least 50")
    if not raises(lambda: gv.input_discriminators(np.random.default_rng(1), want=10 ** 5)):
        errs.append("input_discriminators did not raise ValueError when the pool holds too few")
    vp = gv.vector_parts(10, 1)
    if sum(x["q1"].size for x in vp) != gv.vector_count(10) or [x["q1"].size for x in vp[1:]] != [2000, 1200, 10]:
        errs.append(f"vector_parts gives {[x['q1'].size for x in vp]} rows, vector_count(10) {gv.vector_count(10)}")
    with tempfile.TemporaryDirectory() as d:
        gv.write_consts(os.path.join(d, "c.txt"), cs)
        if gv.read_consts(os.path.join(d, "c.txt")) != [{k: int(c[k]) for k in gv.FIELDS} for c in cs]:
            errs.append("consts do not round-trip")
        two = cs[:1] + cs[-1:]
        good = np.stack([model(c, "DOUBLE") for c in two])
        write_dump(os.path.join(d, "ok.txt"), good)
        if check(os.path.join(d, "ok.txt"), two, "DOUBLE") != 0:
            errs.append("a correct dump failed")
        bad = good.copy()
        bad[1, 12345] ^= 1
        write_dump(os.path.join(d, "bad.txt"), bad)
        if check(os.path.join(d, "bad.txt"), two, "DOUBLE") != 1:
            errs.append("a dump with one wrong result passed")
        try:
            check(os.path.join(d, "ok.txt"), cs[:3], "DOUBLE")
            errs.append("a short dump was read")
        except ValueError:
            pass
        cols = gv.corner_rows()
        gv.write_vectors(os.path.join(d, "v.txt"), cols, "SINGLE")
        tab = np.loadtxt(os.path.join(d, "v.txt"), dtype=str, ndmin=2)
        w = np.array([int(x, 16) for x in tab[:, -1]], np.int64)
        if not np.array_equal(ipu.sx(w, 8), gv.expected(cols, "SINGLE")) or tab.shape != (154 * 49, 14):
            errs.append("vector file does not round-trip")
        o = os.path.join(d, "g0b")
        ys = fake_oracle(o, two, "DOUBLE")
        if not np.array_equal(gv.oracle_outputs(o, 2), ys) or gv.oracle_consts(o) != two:
            errs.append("oracle outputs or constants do not round-trip")
        if check(os.path.join(d, "ok.txt"), two, "DOUBLE", o) != 0:
            errs.append("a correct dump failed against the oracle")
        if check(os.path.join(d, "bad.txt"), two, "DOUBLE", o) != 1:
            errs.append("a dump with one wrong result passed against the oracle")
        if not raises(lambda: check(os.path.join(d, "ok.txt"), two[::-1], "DOUBLE", o)):
            errs.append("constants other than the oracle's were checked against its outputs")
        if not raises(lambda: check(os.path.join(d, "ok.txt"), two[::-1], "SINGLE", o)):
            errs.append("constants other than the oracle's were checked with --oracle in the other rounding")
        cli = subprocess.run([sys.executable, os.path.abspath(__file__), os.path.join(d, "ok.txt"), "--consts", os.path.join(d, "c.txt"),
                              "--rounding", "DOUBLE"], capture_output=True, text=True)
        if cli.returncode != 1 or "RESULT: FAILED" not in cli.stdout or "expected" not in cli.stdout or "Traceback" in cli.stderr:
            errs.append(f"a short dump on the command line: exit {cli.returncode}, no error line and RESULT: FAILED on stdout")
        if not raises(lambda: gv.oracle_outputs(o, 3)):
            errs.append("an oracle with 2 models passed a check for 3")
        np.savez_compressed(os.path.join(o, "g0b_none_001.npz"), y=bad[1].astype(np.int8))
        if not raises(lambda: gv.oracle_outputs(o)):
            errs.append("an oracle file whose sha256 differs from the manifest's was read")
        np.savez_compressed(os.path.join(o, "g0b_none_001.npz"), y=ys[1].astype(np.int8))
        np.savez_compressed(os.path.join(o, "g0b_none_002.npz"), y=ys[1].astype(np.int8))
        if not raises(lambda: gv.oracle_outputs(o)):
            errs.append("an oracle directory with more model files than its manifest was read")


def selftest() -> int:
    """The checks' own output (check() on deliberately bad dumps prints RESULT: FAILED) is shown only when a check fails."""
    errs, log = [], io.StringIO()
    with contextlib.redirect_stdout(log):
        selftest_checks(errs)
    if errs:
        print(log.getvalue(), end="")
    for e in errs:
        print(f"[FAIL] {e}")
    print(f"check_add selftest: {len(errs)} failures")
    print(f"RESULT: {'PASSED' if not errs else 'FAILED'}")
    return 1 if errs else 0


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("dump", nargs="?")
    p.add_argument("--consts")
    p.add_argument("--rounding", choices=ipu.ROUNDINGS)
    p.add_argument("--oracle", help="G0b's output directory: in its pinned rounding the reference is the interpreter")
    p.add_argument("--selftest", action="store_true")
    a = p.parse_args()
    if a.selftest:
        sys.exit(selftest())
    if not (a.dump and a.consts and a.rounding):
        p.error("give DUMP, --consts and --rounding")
    try:
        rc = check(a.dump, gv.read_consts(a.consts), a.rounding, a.oracle)
    except (ValueError, OSError) as e:  # a bad dump, consts file or oracle directory is a failed check, not a crash
        print(f"check_add: {e}")
        print("RESULT: FAILED")
        rc = 1
    sys.exit(rc)


if __name__ == "__main__":
    main()
