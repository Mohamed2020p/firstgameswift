# -*- coding: utf-8 -*-
"""gaming_chair.glb (522k triangles, 6 flat-colour materials, no textures) -> Resources/Models/gaming_chair.glb (~5k triangles)

The source file is left untouched.  Meshes are merged per material, decimated in Blender (collapse modifier through the MCP bridge)
and written with welded smooth normals.  The bright blue piping of the original is replaced with a muted dark red so the office
keeps the restrained, realistic colour scheme of the game.  The chair is scaled by 1.15 (the model is a little small for a real
gaming chair), origin on the floor under the gas-lift, faces +Z.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import glb_write as W                                       # noqa: E402
from glb_lib import GLB                                     # noqa: E402
from asset_common import MODELS, SCRATCH, ensure_dirs       # noqa: E402
from asset_decimate import decimate_cached                  # noqa: E402

SRC = os.environ.get("CHAIR_SRC", r"C:\Users\c0derz\Downloads\assets\gaming_chair.glb")
SCALE = 1.15

# material name -> (target triangles, output colour rgb, metallic, roughness)
TARGETS = {
    "black_skin": (1500, (0.045, 0.045, 0.05), 0.0, 0.62),
    "outline": (900, (0.42, 0.07, 0.08), 0.0, 0.7),
    "black_plactic": (1300, (0.03, 0.03, 0.035), 0.05, 0.42),
    "metal": (200, (0.66, 0.67, 0.70), 1.0, 0.35),
    "Material.002": (500, (0.02, 0.02, 0.02), 0.0, 0.8),
    "Material.001": (700, (0.12, 0.12, 0.13), 1.0, 0.42),
}


def welded_normals(pos, idx):
    pos = np.asarray(pos, dtype=np.float64)
    idx = np.asarray(idx).reshape(-1, 3)
    p = pos[idx]
    fn = np.cross(p[:, 1] - p[:, 0], p[:, 2] - p[:, 0])
    key = np.round(pos * 20000).astype(np.int64)
    _, inv = np.unique(key, axis=0, return_inverse=True)
    inv = inv.reshape(-1)
    acc = np.zeros((inv.max() + 1, 3))
    for c in range(3):
        np.add.at(acc, inv[idx[:, c]], fn)
    n = acc[inv]
    ln = np.linalg.norm(n, axis=1, keepdims=True)
    n = n / np.maximum(ln, 1e-20)
    n[ln[:, 0] < 1e-20] = [0, 1, 0]
    return n.astype(np.float32)


def main():
    ensure_dirs()
    g = GLB(SRC)
    groups = {}
    for p in g.primitives():
        name = g.material_name(p["mat"])
        groups.setdefault(name, []).append(p)
    # one decimation job per source mesh (a merged group stalls Blender's collapse pass on dense, partly non-manifold parts)
    jobs = {}
    owner = {}
    for name, plist in groups.items():
        total = sum(len(p["idx"]) // 3 for p in plist)
        tgt = TARGETS.get(name, (500, (0.1, 0.1, 0.1), 0.0, 0.7))[0]
        print("  %-14s %7d tris in %2d meshes -> target %d" % (name, total, len(plist), tgt))
        for k, p in enumerate(plist):
            t = len(p["idx"]) // 3
            want = max(24, int(tgt * t / float(total)))
            idx = p["idx"].reshape(-1, 3)
            if p["flip"]:
                idx = idx[:, ::-1]
            key = "c%d_%d" % (list(groups.keys()).index(name), k)
            jobs[key] = {"pos": p["pos"].astype(np.float32), "idx": idx, "uv": None, "ratio": min(1.0, want / float(t))}
            owner[key] = (name, want)
    work = os.path.join(SCRATCH, "chair")
    os.makedirs(work, exist_ok=True)
    res = decimate_cached(jobs, work)
    for _ in range(3):
        again = {}
        for key, r in res.items():
            want = owner[key][1]
            have = len(r["idx"])
            if have > want * 1.4 and have > 60:
                again[key] = {"pos": r["pos"], "idx": r["idx"], "uv": None, "ratio": max(0.03, want / float(have))}
        if not again:
            break
        res.update(decimate_cached(again, work))

    # parts Blender cannot reduce (dense casters made of many loose pieces): vertex clustering
    import asset_mesh as M
    for key, r in list(res.items()):
        want = owner[key][1]
        if len(r["idx"]) > want * 1.4 and len(r["idx"]) > 60:
            p2, i2, _ = M.cluster_decimate(np.asarray(r["pos"], dtype=np.float64), r["idx"], None, target=want)
            res[key] = {"pos": p2.astype(np.float32), "idx": i2, "uv": None}

    prims = []
    total = 0
    allp = []
    for name in groups:
        P, I, off = [], [], 0
        for key, (nm, _) in owner.items():
            if nm != name:
                continue
            r = res[key]
            P.append(np.asarray(r["pos"], dtype=np.float64) * SCALE)
            I.append(np.asarray(r["idx"], dtype=np.int64) + off)
            off += len(r["pos"])
        pos = np.concatenate(P)
        idx = np.concatenate(I)
        nrm = welded_normals(pos, idx)
        _, col, metal, rough = TARGETS.get(name, (500, (0.1, 0.1, 0.1), 0.0, 0.7))
        mat = W.Material(name.replace(".", "_"), (col[0], col[1], col[2], 1.0), metal, rough, double_sided=True)
        prims.append(W.Prim(pos, idx.reshape(-1), nrm=nrm, material=mat))
        total += len(idx)
        allp.append(pos)
    allp = np.concatenate(allp)
    # origin: floor level under the centre of the base
    cx = 0.5 * (allp[:, 0].min() + allp[:, 0].max())
    cz = 0.5 * (allp[:, 2].min() + allp[:, 2].max())
    y0 = allp[:, 1].min()
    for p in prims:
        p.pos = (p.pos - np.array([cx, y0, cz], dtype=np.float32)).astype(np.float32)
    root = W.Node("gaming_chair", mesh=W.Mesh("gaming_chair", prims))
    out = os.path.join(MODELS, "gaming_chair.glb")
    info = W.write_glb(out, [root], scene_name="gaming_chair")
    print("wrote", out, info, "triangles", total, "height %.2f" % (allp[:, 1].max() - y0))


if __name__ == "__main__":
    main()
