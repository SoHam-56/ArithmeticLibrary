#!/usr/bin/env python3
"""tfliteAdd's vectors and constant sets from ipu.tflite_add (and G0b's models): the one (q1, q2) order, corners, discriminators, random."""
import argparse
import itertools
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Common", "models"))
import ipu  # noqa: E402

PAIRS = 1 << 16
Q1 = (np.arange(PAIRS, dtype=np.int64) >> 8) - 128  # q1 outer
Q2 = (np.arange(PAIRS, dtype=np.int64) & 255) - 128  # q2 inner: the oracle's, the TB's exhaustive mode's and the checker's order
FIELDS = ("zp1", "zp2", "m1", "s1", "m2", "s2", "mo", "so", "zpo", "amin", "amax")  # a constant set, in the consts file's column order
LOG2_LO, LOG2_HI, LOG2_SPAN = -10.0, 2.0, 10.0  # scales 2^-10 to 2^2, ratios up to 2^10 (the spec's G0b ranges)
MIN, MAX = ipu.INT32_MIN, ipu.INT32_MAX


def act_range(act: str, scale, zp: int):
    """TFLite CalculateActivationRangeQuantized, int8: zp + round(f / scale), f / scale in float32."""
    q = lambda f: int(zp) + ipu.round_half_away(float(np.float32(f) / np.float32(scale)))
    return {"none": (-128, 127), "relu": (max(-128, q(0.0)), 127), "relu6": (max(-128, q(0.0)), min(127, q(6.0)))}[act]


def draw_scales(rng):
    """s1, s2, s_out log-uniform in [2^-10, 2^2] with max / min <= 2^10, as float32 values."""
    while True:
        e = rng.uniform(LOG2_LO, LOG2_HI, 3)
        if e.max() - e.min() <= LOG2_SPAN:
            return [float(np.float32(2.0 ** v)) for v in e]


def oracle_manifest(d: str) -> dict:
    return json.load(open(os.path.join(d, "manifest.json")))


def oracle_consts(d: str) -> list:
    """Every G0b model's ADD words, in manifest order: add_params of its scales, its zero points and its clamp."""
    return [m["add"] for m in oracle_manifest(d)["models"]]


def oracle_outputs(d: str) -> np.ndarray:
    """Every G0b model's interpreter outputs (BUILTIN_REF), one row of PAIRS per model, in manifest order."""
    return np.stack([np.load(os.path.join(d, m["file"]))["y"].astype(np.int64) for m in oracle_manifest(d)["models"]])


def main() -> None:
    argparse.ArgumentParser(description=__doc__).parse_args()  # the vector writers come with tfliteAdd's testbench


if __name__ == "__main__":
    main()
