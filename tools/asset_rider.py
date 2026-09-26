# -*- coding: utf-8 -*-
"""bike_rider_3d.glb (Ready-Player-Me style rigged avatar, 68 joints, T-pose) -> rider.glb + rider_meta.json

The source is already metric, Y up, facing +Z, +X = avatar left, feet on y = 0 (the Sketchfab wrapper nodes cancel out),
so the skin is copied 1:1: same joints/order/names, same inverse bind matrices, same vertex weights (re-normalised).
Only the wrapper nodes are dropped, extra UV sets/tangents are removed and textures are re-encoded (<= 1024).
"""
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import glb_write as W                                   # noqa: E402
from glb_lib import GLB                                 # noqa: E402
from asset_common import ImageCache, MODELS, DATA, SRC, ensure_dirs   # noqa: E402


def build():
    ensure_dirs()
    g = GLB(os.path.join(SRC, "bike_rider_3d.glb"))
    j = g.json
    skin_src = j["skins"][0]
    joint_ids = skin_src["joints"]
    assert len(joint_ids) == 68
    cache = ImageCache()

    # ---- materials (drop MR/normal maps: they would need tangents and the metallic factor of 1.0 would turn cloth into metal)
    mats = {}
    for mi, m in enumerate(g.materials):
        info = g.material_info(mi)
        base_img = None
        if info["base_img"] is not None:
            base_img = cache.get(("src", info["base_img"]), g.pil_image(info["base_img"]), 1024, quality=88, name="tex%d" % info["base_img"])
        blend = info["alpha"] == "BLEND"
        name = info["name"]
        if "Outfit" in name or "Headwear" in name:
            metal, rough = 0.0, 0.85
        elif "Skin" in name:
            metal, rough = 0.0, 0.7
        else:
            metal, rough = 0.0, 0.6
        mats[mi] = W.Material(name, info["base"], metal, rough, base_image=base_img, alpha_mode="BLEND" if blend else "OPAQUE",
                              double_sided=info["double"] or blend)

    # ---- joint hierarchy (only the armature part of the scene graph)
    node_of = {}

    def clone(i):
        n = g.nodes[i]
        nn = W.Node(n.get("name", "node%d" % i), translation=n.get("translation"), rotation=n.get("rotation"), scale=n.get("scale"))
        node_of[i] = nn
        for c in n.get("children", []):
            if c in joint_set or c in armature_chain:
                nn.add(clone(c))
        return nn

    joint_set = set(joint_ids)
    armature_chain = {3, 4, 5}
    root = W.Node("rider")
    arm = clone(3)                       # Armature_71 -> GLTF_created_0 -> GLTF_created_0_rootJoint -> Hips ...
    root.add(arm)
    ibm = g.accessor(skin_src["inverseBindMatrices"]).reshape(-1, 4, 4).astype(np.float32)
    ibm_rows = np.transpose(ibm, (0, 2, 1))              # accessor memory is column-major -> row-major matrices
    skin = W.Skin("rider_skin", [node_of[i] for i in joint_ids], ibm_rows, skeleton=node_of[skin_src.get("skeleton", joint_ids[0])])

    tris = 0
    for i, n in enumerate(g.nodes):
        if "mesh" not in n:
            continue
        child_names = [g.nodes[c].get("name") for c in n.get("children", [])]
        mesh = g.meshes[n["mesh"]]
        prims = []
        for p in mesh["primitives"]:
            at = p["attributes"]
            pos = g.accessor(at["POSITION"]).astype(np.float32)
            nrm = g.accessor(at["NORMAL"]).astype(np.float32)
            uv = g.accessor(at["TEXCOORD_0"]).astype(np.float32)
            jn = g.accessor(at["JOINTS_0"]).astype(np.int64)
            wt = g.accessor(at["WEIGHTS_0"]).astype(np.float32)
            s = wt.sum(axis=1, keepdims=True)
            wt = wt / np.maximum(s, 1e-8)
            # unweighted vertices (should not exist) are bound to the hips
            bad = (s[:, 0] < 1e-6)
            if bad.any():
                jn[bad] = 0
                wt[bad] = [1, 0, 0, 0]
            idx = g.accessor(p["indices"]).astype(np.int64).reshape(-1)
            tris += len(idx) // 3
            prims.append(W.Prim(pos, idx, nrm=nrm, uv=uv, material=mats[p["material"]], joints=jn, weights=wt))
        nm = child_names[0] if child_names else n.get("name")
        root.add(W.Node(nm, mesh=W.Mesh(nm, prims), skin=skin))
    info = W.write_glb(os.path.join(MODELS, "rider.glb"), [root], scene_name="rider",
                       asset_extras={"source": "bike rider 3d by Atrikumar Das (ganash3691), CC-BY-4.0"})
    print("rider.glb", info)

    # ---- meta
    rest = {}
    for i in joint_ids:
        rest[g.nodes[i]["name"]] = [round(float(v), 4) for v in g.world_matrix(i)[:3, 3]]
    allpos = np.concatenate([g.accessor(pp["attributes"]["POSITION"]) for m in g.meshes for pp in m["primitives"]])
    height = float(allpos[:, 1].max() - allpos[:, 1].min())
    meta = {
        "height": round(height, 3),
        "hipHeight": round(rest["Hips_66"][1], 3),
        "eyeHeight": round(rest["LeftEye_1"][1], 3),
        "feetY": round(float(allpos[:, 1].min()), 4),
        "shoulderWidth": round(abs(rest["LeftArm_27"][0] - rest["RightArm_51"][0]), 3),
        "armLength": round(float(np.linalg.norm(np.array(rest["LeftHand_25"]) - np.array(rest["LeftArm_27"]))), 3),
        "notes": "T-pose, faces +Z, +X = avatar left, 68 Mixamo-named bones with numeric suffixes e.g. Hips_66; skin node parent = 'rider'; "
                 "bone rest positions are model-space metres (skeleton root at origin).",
        "skinnedMeshNodes": [n.name for n in root.children if n.mesh is not None],
        "boneWorldRest": rest,
        "triangles": tris,
    }
    json.dump(meta, open(os.path.join(DATA, "rider_meta.json"), "w"), indent=1)
    print("rider_meta.json height=%.3f hips=%.3f" % (meta["height"], meta["hipHeight"]))


if __name__ == "__main__":
    build()
