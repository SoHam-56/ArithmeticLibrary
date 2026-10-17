#!/usr/bin/env python3
"""Gates a TB_int8Requantizer dump on the true function of each row's real scale (truth.gate_requantize), per row kind; bit-exact
agreement with ipu.requantize and the scale codes against gate_scale are diagnostic lines. A missing, short or empty dump fails."""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Common", "models"))
import ipu  # noqa: E402
import truth  # noqa: E402


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("dump", help="one result word (hex) per row, in row order")
    p.add_argument("--vectors", required=True, help="the generator's row file; its .npz holds the scales")
    a = p.parse_args()
    v = np.load(a.vectors + ".npz")
    got = np.loadtxt(a.dump, dtype=str, ndmin=1)
    ok = True
    if got.size != v["acc"].size:
        print(f"[FAIL] {got.size} results for {v['acc'].size} rows")
        ok = False
        got = np.zeros(0, dtype=str)
    q = np.array([int(x, 16) for x in got], dtype=np.int64)
    rs = []
    for i, k in enumerate(v["kinds"]):
        sel = v["kind"] == i
        if q.size:
            r = truth.gate_requantize(v["acc"][sel], v["scale"][sel], v["zp"][sel], v["lo"][sel], v["hi"][sel], q[sel])
        else:
            r = truth.gate_requantize([], [], [], [], [], [])
        print(f"{k}: " + truth.stage_line(r))
        for f in r.first:
            print(f"  miss: row {f[0]} of {k}, acc {f[1]}, got {f[2]}, true {f[3]:.4f}")
        rs.append(r)
        ok &= r.ok
    m = truth.merge(rs)
    print("all: " + truth.stage_line(m))
    if q.size:
        same = int(np.sum(ipu.requantize(v["acc"], v["mult"], v["shift"], v["zp"], v["lo"], v["hi"]) == truth.int8_codes(q)))
        print(f"diagnostic: {same} of {q.size} equal ipu.requantize bit for bit")
        enc = np.isin(v["kind"], [list(v["kinds"]).index(k) for k in ("saturation", "dense")])  # rows whose words encode_scale chose
        print("diagnostic: encode_scale codes " + truth.stage_line(truth.gate_scale(v["scale"][enc], v["mult"][enc], v["shift"][enc])))
    print(f"RESULT: {'PASSED' if ok and m.ok else 'FAILED'}")
    sys.exit(0 if ok and m.ok else 1)


if __name__ == "__main__":
    main()
