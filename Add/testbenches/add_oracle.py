#!/usr/bin/env python3
"""Gate G0b: single-op int8 TFLite ADD models on the interpreter's BUILTIN_REF kernels against ipu.tflite_add on ipu.add_params, every (q1, q2); pins the ADD's rounding."""
import argparse
import hashlib
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_add_vectors as gv  # noqa: E402
from gen_add_vectors import ipu  # noqa: E402

ACTS = ("none", "relu", "relu6")
ROUNDINGS = ("DOUBLE", "SINGLE")
MIN_DISC = 10000  # pairs where DOUBLE and SINGLE differ, over the run: the pin must rest on evidence
FUSED = {"none": 0, "relu": 1, "relu6": 3}  # tflite ActivationFunctionType: NONE, RELU, RELU6
CONVERTER = "converter (before any resolver)"  # the label of problems found in the flatbuffer


def fq_range(s: float, z: int):
    """The fake-quant range whose scale is s and whose int8 zero point is z: [s (-128 - z), s (127 - z)]."""
    return s * (-128 - z), s * (127 - z)


N_TIE = 16  # tie models per activation: s1 = s2 = 2^e, s_out = 2^(e+1) or 2^(e+2), so outputs land on exact halves where the roundings differ


def model_specs(per_act: int, seed: int):
    """(act, scales, zero points, tie) per model: per activation, per_act random-scale models with every zero point at each position once, then N_TIE tie models."""
    rng = np.random.default_rng(seed)
    out = []
    for act in ACTS:
        perms = [rng.permutation(256) - 128 for _ in range(3)]
        for j in range(per_act):
            out.append((act, gv.draw_scales(rng), [int(p[j % 256]) for p in perms], False))
        for j in range(N_TIE):
            e = int(rng.integers(-10, 1))
            out.append((act, [2.0 ** e, 2.0 ** e, 2.0 ** (e + 1 + j % 2)], [int(v) for v in rng.integers(-128, 128, 3)], True))
    return out


def build(tf, s, z, act):
    """One ADD of two (1, PAIRS) int8 tensors with the activation fused, quantized by fake-quant ranges (scale s[i], zero point z[i])."""
    r = [fq_range(s[i], z[i]) for i in range(3)]
    fq = lambda x, k: tf.quantization.fake_quant_with_min_max_args(x, r[k][0], r[k][1], num_bits=8)
    f = {"none": tf.identity, "relu": tf.nn.relu, "relu6": tf.nn.relu6}[act]

    @tf.function(input_signature=[tf.TensorSpec((1, gv.PAIRS), tf.float32)] * 2)
    def add_fn(a, b):
        return fq(f(fq(a, 0) + fq(b, 1)), 2)

    rep = np.random.default_rng(0)
    holder = tf.Module()
    holder.f = add_fn
    conv = tf.lite.TFLiteConverter.from_concrete_functions([add_fn.get_concrete_function()], holder)
    conv.optimizations = [tf.lite.Optimize.DEFAULT]
    conv.representative_dataset = lambda: ([rep.uniform(*r[0], (1, gv.PAIRS)).astype(np.float32),
                                            rep.uniform(*r[1], (1, gv.PAIRS)).astype(np.float32)] for _ in range(4))
    conv.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
    conv.inference_input_type = tf.int8
    conv.inference_output_type = tf.int8
    return conv.convert()


def flatbuffer_ops(model):
    """The converter's own operators, read from the flatbuffer: (builtin name, input tensors, output tensors) per operator, every subgraph."""
    import tflite
    names = {v: k for k, v in vars(tflite.BuiltinOperator).items() if not k.startswith("_")}
    m = tflite.Model.GetRootAsModel(model, 0)
    out = []
    for g in (m.Subgraphs(i) for i in range(m.SubgraphsLength())):
        for op in (g.Operators(k) for k in range(g.OperatorsLength())):
            c = m.OperatorCodes(op.OpcodeIndex())
            code = max(c.BuiltinCode(), c.DeprecatedBuiltinCode())  # TFLite's GetBuiltinCode
            out.append((names.get(code, str(code)), [int(i) for i in op.InputsAsNumpy()], [int(i) for i in op.OutputsAsNumpy()]))
    return out


def fused_activation(model) -> int:
    """The fused activation of the model's only operator, read from the flatbuffer."""
    import tflite
    op = tflite.Model.GetRootAsModel(model, 0).Subgraphs(0).Operators(0)
    opt = tflite.AddOptions()
    t = op.BuiltinOptions()
    opt.Init(t.Bytes, t.Pos)
    return opt.FusedActivationFunction()


def run(tf, model, resolver, name: str, gated: bool):
    """(output codes, input1/input2/output quantization, the interpreter's node names) for the pair grid; a gated pass must carry no DELEGATE node."""
    (_, ins, outs), = flatbuffer_ops(model)  # the caller checked: one ADD
    i1, i2, io = ins[0], ins[1], outs[0]
    it = tf.lite.Interpreter(model_content=model, experimental_op_resolver_type=resolver)
    it.allocate_tensors()
    nodes = [o["op_name"] for o in it._get_ops_details()]  # private in TF 2.x: the execution plan, delegate nodes included
    if gated and "DELEGATE" in nodes:
        raise RuntimeError(f"{name}: the interpreter carries a DELEGATE node ({nodes}): its outputs are not TFLite's reference kernels'")
    det = {d["index"]: d for d in it.get_input_details()}
    if set(det) != {i1, i2} or it.get_output_details()[0]["index"] != io:
        raise RuntimeError(f"{name}: the ADD's inputs and output are not the graph's")
    it.set_tensor(i1, gv.Q1[None].astype(np.int8))
    it.set_tensor(i2, gv.Q2[None].astype(np.int8))
    it.invoke()
    td = {t["index"]: t for t in it.get_tensor_details()}
    q = {k: (float(np.float32(td[k]["quantization"][0])), int(td[k]["quantization"][1])) for k in (i1, i2, io)}
    return it.get_tensor(io)[0].astype(np.int64), q[i1], q[i2], q[io], nodes


def reference(a: dict, rounding: str, left_shift: int = ipu.ADD_LEFT_SHIFT):
    """ipu.tflite_add over the pair grid; left_shift 19 is the negative control, AddFunc with 19 in place of 20, which must mismatch."""
    return ipu.tflite_add(gv.Q1, gv.Q2, *[a[k] for k in gv.FIELDS], rounding, left_shift=left_shift)


def selftest() -> int:
    """No TensorFlow: the fake-quant ranges, the clamp rule, the scale draws, the model list and the reference's left shift."""
    errs = []
    lo, hi = fq_range(0.5, -3)
    if (round(-128 - lo / ((hi - lo) / 255)), (hi - lo) / 255) != (-3, 0.5):
        errs.append(f"fq_range(0.5, -3) = {lo, hi}")
    if gv.act_range("relu", 0.1, -20) != (-20, 127) or gv.act_range("relu6", 0.1, -20) != (-20, 40) or gv.act_range("none", 1, 5) != (-128, 127):
        errs.append("act_range")
    specs = model_specs(256, 1)
    if len(specs) != 3 * (256 + N_TIE) or sum(sp[3] for sp in specs) != 3 * N_TIE:
        errs.append("model list")
    for act in ACTS:
        zs = [sp[2] for sp in specs if sp[0] == act and not sp[3]]
        if any(len({z[k] for z in zs}) != 256 for k in range(3)):
            errs.append(f"{act}: not every zero point at every position")
    sc = np.array([sp[1] for sp in specs])
    if sc.min() < 2.0 ** -10 or sc.max() > 4.0 or (np.log2(sc.max(axis=1)) - np.log2(sc.min(axis=1))).max() > 10 + 1e-6:
        errs.append("scale draws out of range")
    if not (gv.Q1[0], gv.Q2[0], gv.Q1[1], gv.Q2[1], gv.Q1[-1]) == (-128, -128, -128, -127, 127):
        errs.append("pair order")
    a = dict(zp1=0, zp2=0, **ipu.add_params(0.5, 0.5, 1.0), zpo=0, amin=-128, amax=127)  # y = (q1 + q2) / 2
    y20, y19 = reference(a, "DOUBLE"), reference(a, "DOUBLE", left_shift=19)
    if y20[gv.PAIRS - 1] != 127 or y20[(10 + 128) * 256 + 6 + 128] != 8 or y19[(10 + 128) * 256 + 6 + 128] != 4:
        errs.append("reference: (10 + 6) / 2 at left shift 20, / 4 at 19")
    for e in errs:
        print(f"[FAIL] {e}")
    print(f"add_oracle selftest: {len(errs)} failures")
    print(f"RESULT: {'PASSED' if not errs else 'FAILED'}")
    return 1 if errs else 0


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out", help="directory for the models' outputs (npz), manifest.json and rounding_add.txt")
    p.add_argument("--report", default=os.path.join(os.environ.get("RES", "."), "g0b_add_oracle.log"))
    p.add_argument("--models-per-act", type=int, default=256)
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--selftest", action="store_true")
    a = p.parse_args()
    if a.selftest:
        sys.exit(selftest())
    if not a.out:
        p.error("--out is required")
    import tensorflow as tf
    os.makedirs(a.out, exist_ok=True)
    ref, auto = tf.lite.experimental.OpResolverType.BUILTIN_REF, tf.lite.experimental.OpResolverType.AUTO
    L = [f"G0b TFLite ADD oracle: TensorFlow {tf.__version__}, numpy {np.__version__}, resolver BUILTIN_REF (gated, no DELEGATE node allowed), "
         f"{a.models_per_act} random-scale and {N_TIE} tie models per activation ({', '.join(ACTS)}), every (q1, q2) pair, seed {a.seed}"]
    tot = {"outputs": 0, "DOUBLE": 0, "SINGLE": 0, "disc": 0, "neg": 0, "auto_DOUBLE": 0, "auto_SINGLE": 0, "auto_models": 0, "auto_delegate": 0}
    problems, auto_errs, models, zps = [], [], [], {act: [set(), set(), set()] for act in ACTS}
    disc_random = 0  # discriminating outputs of the random-scale models alone
    for j, (act, s, z, tie) in enumerate(model_specs(a.models_per_act, a.seed)):
        idx = j % (a.models_per_act + N_TIE)
        tag = f"{act} {idx}{' (tie)' if tie else ''}"
        try:
            model = build(tf, s, z, act)
            ops = [o[0] for o in flatbuffer_ops(model)]
            if ops != ["ADD"]:
                raise RuntimeError(f"{CONVERTER}: expected one ADD, the flatbuffer holds {ops}")
            if fused_activation(model) != FUSED[act]:
                raise RuntimeError(f"{CONVERTER}: fused activation {fused_activation(model)}, expected {act}")
            y, q1, q2, qo, _ = run(tf, model, ref, "BUILTIN_REF", True)
            try:
                add = dict(zp1=q1[1], zp2=q2[1], **ipu.add_params(q1[0], q2[0], qo[0]), zpo=qo[1])
            except ValueError as e:
                raise RuntimeError(f"BUILTIN_REF: add_params of its scales: {e}")
            add["amin"], add["amax"] = gv.act_range(act, qo[0], qo[1])
        except RuntimeError as e:
            problems.append(f"{tag}: {e}")
            continue
        want = {r: reference(add, r) for r in ROUNDINGS}
        mism = {r: int(np.sum(y != want[r])) for r in ROUNDINGS}
        disc = int(np.sum(want["DOUBLE"] != want["SINGLE"]))
        neg = int(np.sum(y != reference(add, "DOUBLE", left_shift=19)))
        try:  # the default resolver: reported, never gated
            y_auto, _, _, _, auto_nodes = run(tf, model, auto, "AUTO", False)
            tot["auto_models"] += 1
            tot["auto_delegate"] += "DELEGATE" in auto_nodes
            for r in ROUNDINGS:
                tot["auto_" + r] += int(np.sum(y_auto != want[r]))
        except RuntimeError as e:
            auto_errs.append(f"{tag}: {e}")
        if not tie:
            disc_random += disc
            for k, v in enumerate((q1[1], q2[1], qo[1])):
                zps[act][k].add(v)
        tot["outputs"] += y.size
        tot["disc"] += disc
        tot["neg"] += neg
        for r in ROUNDINGS:
            tot[r] += mism[r]
        fn = f"g0b_{act}_{idx:03d}.npz"
        np.savez_compressed(os.path.join(a.out, fn), y=y.astype(np.int8))
        models.append(dict(file=fn, act=act, scales=[q1[0], q2[0], qo[0]], add={k: int(v) for k, v in add.items()},
                           sha256=hashlib.sha256(y.astype(np.int8).tobytes()).hexdigest()))
        L.append(f"{tag}: s {q1[0]:.6g} {q2[0]:.6g} {qo[0]:.6g} zp {q1[1]} {q2[1]} {qo[1]} clamp [{add['amin']}, {add['amax']}] "
                 f"m {add['m1']} {add['m2']} {add['mo']} s {add['s1']} {add['s2']} {add['so']}: mismatches DOUBLE {mism['DOUBLE']} "
                 f"SINGLE {mism['SINGLE']}, discriminating {disc}, left shift 19 {neg}")
    L.append(f"totals: {len(models)} models, outputs {tot['outputs']}, mismatches DOUBLE {tot['DOUBLE']} SINGLE {tot['SINGLE']}, "
             f"discriminating {tot['disc']} ({disc_random} from the random-scale models), negative control (left shift 19) {tot['neg']}")
    L.append(f"default resolver (AUTO, info, not gated): {tot['auto_models']} models, mismatches DOUBLE {tot['auto_DOUBLE']} SINGLE {tot['auto_SINGLE']}, "
             f"DELEGATE node in {tot['auto_delegate']}, errors {len(auto_errs)}")
    L += [f"AUTO (info): {m}" for m in auto_errs]
    for act in ACTS:
        n = [len(x) for x in zps[act]]
        L.append(f"{act}: distinct zero points input1 {n[0]}, input2 {n[1]}, output {n[2]} (of 256)")
        if min(n) < 256:
            problems.append(f"BUILTIN_REF: {act}: not every zero point reached every position ({n})")
    winners = [r for r in ROUNDINGS if tot[r] == 0]
    if len(winners) != 1:
        problems.append(f"BUILTIN_REF: {len(winners)} roundings match every output; exactly one must")
    if tot["disc"] < MIN_DISC:
        problems.append(f"BUILTIN_REF: only {tot['disc']} discriminating outputs (need {MIN_DISC})")
    if tot["neg"] == 0:
        problems.append("BUILTIN_REF: the negative control (left shift 19) matched every output: the comparison cannot fail")
    if problems:
        L += [f"problem: {m}" for m in problems] + ["G0b: FAIL"]
    else:
        r = winners[0]
        conv = ipu.REQ_ROUNDING
        L.append(f"ADD ROUNDING: {r}; the conv's G0 pin is {conv}: " + ("the same" if r == conv else "DIFFERENT, the ADD needs its own pin"))
        json.dump(dict(tf_version=tf.__version__, rounding=r, models=models), open(os.path.join(a.out, "manifest.json"), "w"), indent=1)
        open(os.path.join(a.out, "rounding_add.txt"), "w").write(r + "\n")
        L.append("G0b: PASS")
    os.makedirs(os.path.dirname(os.path.abspath(a.report)), exist_ok=True)
    open(a.report, "w").write("\n".join(L) + "\n")
    print("\n".join(L[:1] + L[-8:]))
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
