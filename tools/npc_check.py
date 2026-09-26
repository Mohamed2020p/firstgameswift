# -*- coding: utf-8 -*-
"""Sanity check of a baked npc_*.glb: linear blend skinning in numpy with a test pose, flat-colour preview renders.

    python npc_check.py christie [out_prefix]      -> <prefix>_rest_front.png, <prefix>_pose_front.png, <prefix>_pose_side.png
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from glb_lib import GLB                      # noqa: E402
from asset_common import MODELS, SCRATCH     # noqa: E402
from asset_preview import render             # noqa: E402


def rot(axis, ang):
    a = np.asarray(axis, dtype=np.float64)
    a = a / np.linalg.norm(a)
    c, s = np.cos(ang), np.sin(ang)
    x, y, z = a
    return np.array([[c + x * x * (1 - c), x * y * (1 - c) - z * s, x * z * (1 - c) + y * s],
                     [y * x * (1 - c) + z * s, c + y * y * (1 - c), y * z * (1 - c) - x * s],
                     [z * x * (1 - c) - y * s, z * y * (1 - c) + x * s, c + z * z * (1 - c)]])


def load(path):
    g = GLB(path)
    j = g.json
    sk = j["skins"][0]
    jn = sk["joints"]
    names = [j["nodes"][i]["name"] for i in jn]
    ibm = np.transpose(g.accessor(sk["inverseBindMatrices"]).reshape(-1, 4, 4).astype(np.float64), (0, 2, 1))
    return g, jn, names, ibm


def pose_matrices(g, jn, names, rots):
    """global joint matrices for local rotations `rots` {name: 3x3} (rotation about the joint origin, world-aligned frames)"""
    idx = {n: k for k, n in enumerate(jn)}
    G = {}

    def rec(i):
        if i in G:
            return G[i]
        node = g.nodes[i]
        t = np.array(node.get("translation", [0, 0, 0]), dtype=np.float64)
        L = np.eye(4)
        L[:3, 3] = t
        R = rots.get(node["name"])
        if R is not None:
            L[:3, :3] = R
        p = g.parent.get(i)
        G[i] = (rec(p).dot(L)) if (p is not None and p in idx) else L
        return G[i]

    return np.array([rec(i) for i in jn])


def skin_prims(g, jn, ibm, G):
    S = np.array([G[k].dot(ibm[k]) for k in range(len(jn))])
    parts = []
    for i, node in enumerate(g.nodes):
        if "mesh" not in node:
            continue
        for p in g.meshes[node["mesh"]]["primitives"]:
            at = p["attributes"]
            pos = g.accessor(at["POSITION"]).astype(np.float64)
            J = g.accessor(at["JOINTS_0"]).astype(np.int64)
            Wt = g.accessor(at["WEIGHTS_0"]).astype(np.float64)
            idx = g.accessor(p["indices"]).astype(np.int64).reshape(-1, 3)
            hp = np.concatenate([pos, np.ones((len(pos), 1))], axis=1)
            out = np.zeros((len(pos), 3))
            for c in range(4):
                out += Wt[:, c:c + 1] * np.einsum("nij,nj->ni", S[J[:, c]], hp)[:, :3]
            mi = g.material_info(p.get("material"))
            col = np.array(mi["base"][:3])
            if mi["base_img"] is not None:
                im = g.pil_image(mi["base_img"]).convert("RGBA").resize((16, 16))
                a = np.asarray(im).astype(np.float64) / 255.0
                w = a[..., 3:4]
                col = col * (a[..., :3] * w).sum((0, 1)) / max(w.sum(), 1e-6)
            nm = g.materials[p["material"]]["name"] if p.get("material") is not None else ""
            tint = {"top": (0.2, 0.35, 0.7), "bottom": (0.25, 0.25, 0.3), "shoes": (0.15, 0.1, 0.08), "hair": (0.25, 0.15, 0.08), "hat": (0.6, 0.1, 0.1)}
            if nm in tint:
                col = col * np.array(tint[nm]) * 1.4
            parts.append((out, idx, tuple(np.clip(col, 0, 1))))
    return parts


def main():
    name = sys.argv[1]
    prefix = sys.argv[2] if len(sys.argv) > 2 else os.path.join(SCRATCH, "chk_" + name)
    g, jn, names, ibm = load(os.path.join(MODELS, "npc_%s.glb" % name))
    rest = pose_matrices(g, jn, names, {})
    parts = skin_prims(g, jn, ibm, rest)
    allp = np.concatenate([p[0] for p in parts])
    print("bbox", allp.min(0).round(3), allp.max(0).round(3), "joints", len(jn))
    render(parts, prefix + "_rest_front.png", view="front", size=(700, 900))
    rots = {
        "LeftArm": rot([0, 0, 1], -1.1), "RightArm": rot([0, 0, 1], 1.1),
        "LeftForeArm": rot([1, 0, 0], -0.9), "RightUpLeg": rot([1, 0, 0], -0.7), "RightLeg": rot([1, 0, 0], 0.9),
        "LeftUpLeg": rot([1, 0, 0], 0.35), "Head": rot([0, 1, 0], 0.5), "Spine1": rot([1, 0, 0], 0.25),
    }
    posed = skin_prims(g, jn, ibm, pose_matrices(g, jn, names, rots))
    render(posed, prefix + "_pose_front.png", view="front", size=(700, 900))
    render(posed, prefix + "_pose_side.png", view="side_r", size=(900, 900))
    print("wrote", prefix + "_*.png")


if __name__ == "__main__":
    main()
