#!/usr/bin/env python3
"""Gates a TB_int8QuantizedAdder dump on the true function of the real ratios (truth.gate_quantized_add): every exhaustive set, then the
encoded and the raw-word rows; bit-exact agreement with ipu.qadd is a diagnostic line. A missing, short or empty dump fails."""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "models"))
import fourstate  # noqa: E402
import ipu  # noqa: E402
import truth  # noqa: E402


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("dump", help="one result word (hex) per beat: every set's 65536 (q1, q2) in order (q1 outer), then the rows")
    p.add_argument("--vectors", required=True, help="the generator's row file; .npz beside it")
    a = p.parse_args()
    v = np.load(a.vectors + ".npz")
    sets, rows = v["sets"], v["rows"]
    n_want = sets.shape[0] * 65536 + rows.shape[0]
    got = np.loadtxt(a.dump, dtype=str, ndmin=1)
    if got.size != n_want:
        print(f"[FAIL] {got.size} results for {n_want} beats")
        print("RESULT: FAILED")
        sys.exit(1)
    try:  # a 4-state simulator's x or z in a word fails the test, named, rather than crashing int()
        y = np.array(fourstate.words(got, os.path.basename(a.dump)), dtype=np.int64)
    except fourstate.Unknown as e:
        print(fourstate.fail_line(e))
        print("RESULT: FAILED")
        sys.exit(1)
    q = np.arange(65536)
    q1, q2 = truth.int8_codes(q >> 8), truth.int8_codes(q & 0xFF)
    rs, same, ok = [], 0, True
    for k, s in enumerate(sets):
        z1, z2, m1, m2, e, zo, lo, hi = (int(x) for x in s)
        yk = y[k * 65536:(k + 1) * 65536]
        r = truth.gate_quantized_add(q1, q2, v["set_r1"][k], z1, v["set_r2"][k], z2, 1.0, zo, lo, hi, yk)
        same += int(np.sum(ipu.qadd(q1, q2, z1, z2, m1, m2, e, zo, lo, hi) == truth.int8_codes(yk)))
        if not r.ok:
            print(f"set {k} (r1 {v['set_r1'][k]!r}, r2 {v['set_r2'][k]!r}, zp {z1} {z2} {zo}, clamp [{lo}, {hi}]): " + truth.stage_line(r))
        rs.append(r)
    m = truth.merge(rs)
    print(f"exhaustive, {sets.shape[0]} sets x 65536: " + truth.stage_line(m))
    ok &= m is not None and m.ok
    yr = y[sets.shape[0] * 65536:]
    c = [rows[:, i] for i in range(10)]
    for name, sel in (("encoded rows", ~v["raw"]), ("raw-word rows", v["raw"])):
        r = truth.gate_quantized_add(c[0][sel], c[1][sel], v["r1"][sel], c[2][sel], v["r2"][sel], c[3][sel], 1.0, c[7][sel], c[8][sel],
                                     c[9][sel], yr[sel])
        print(f"{name}: " + truth.stage_line(r))
        for f in r.first:
            print(f"  miss: row {f[0]}, q1 {f[1]}, q2 {f[2]}, got {f[3]}, true {f[4]:.4f}")
        ok &= r.ok
    same += int(np.sum(ipu.qadd(*c) == truth.int8_codes(yr)))
    print(f"diagnostic: {same} of {n_want} equal ipu.qadd bit for bit")
    print(f"RESULT: {'PASSED' if ok else 'FAILED'}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
