# -*- coding: utf-8 -*-
"""Pedestrian archetypes: skinned Mixamo-style characters -> game-ready npc_<name>.glb + Data/npc_meta.json

Source assets are NOT modified. Every archetype goes through the same steps:

  1. rest-pose extraction   world positions come from the skin itself (sum w_k * J_k * IBM_k * p), so wrapper nodes, unit scale
                            (cm vs m) and Sketchfab axis fixes never matter.  All sources are T-pose, face +Z, +X = character left.
  2. skeleton baking        joints are re-created with identity rotations (world aligned) and metric translations, names cleaned
                            ("mixamorig:LeftArm_09" -> "LeftArm").  Inverse bind matrices become pure translations.
  3. decimation             Blender 2.79 (MCP bridge, collapse modifier) per source mesh; skin weights are transferred from the source
                            vertices with a 3-nearest inverse-distance lookup (top-4 joints kept).
  4. material grouping      meshes that share a texture become one primitive/material ("skin", "top", "bottom", "shoes", "hair", ...),
                            so an NPC costs ~6 draw calls.  Clothing / hair textures are converted to a bright neutral base so the game
                            can tint them with a palette colour at runtime (one texture, many looks).
  5. casual_female          has no skeleton in the source: it is rigged by nearest-vertex weight transfer from the christie rig after
                            warping that rig (arm length / height) onto the mesh.

    python asset_npc.py [name ...]      (default: all)
"""
import json
import os
import sys

import numpy as np
from scipy.spatial import cKDTree

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import glb_write as W                                       # noqa: E402
from glb_lib import GLB                                     # noqa: E402
from asset_common import ImageCache, MODELS, DATA, SCRATCH, ensure_dirs   # noqa: E402
from asset_decimate import decimate_cached                  # noqa: E402
import asset_mesh as M                                      # noqa: E402
from PIL import Image as PILImage                           # noqa: E402

ASSETS = os.environ.get("NPC_SRC", r"C:\Users\c0derz\Downloads\assets")


# ----------------------------------------------------------------------------------------------------------------------
# archetype description
#   parts: material-group -> list of (source mesh selector, target triangles)
#   selector: material name (all meshes with that material) or ("node", index) for one mesh node
# ----------------------------------------------------------------------------------------------------------------------
class Group(object):
    def __init__(self, name, sources, tris, tex=512, tint=None, alpha=False, rough=0.8, metal=0.0, gray=False, double=False):
        self.name = name              # output material / primitive name
        self.sources = sources        # list of material names and/or ("node", idx)
        self.tris = tris              # decimation target for the whole group (split over its meshes by triangle count)
        self.tex = tex
        self.tint = tint              # None or palette name ("clothes", "hair", "shoes", "hat")
        self.alpha = alpha            # BLEND
        self.rough = rough
        self.metal = metal
        self.gray = gray              # convert texture to neutral tintable base
        self.double = double


ARCH = {
    "christie": dict(
        src="christie_female_3d_model.glb", height=1.72, female=True, weight=1.0,
        groups=[
            Group("skin", ["Body_m", "Arms_m", "Legs_m"], 2600, tex=512, rough=0.75),
            Group("face", ["Facedetails_m", "Ears_m", "Lips_m"], 1500, tex=512, rough=0.7),
            Group("eyes", ["Sclera_m", "Irises_m", "Pupils_m"], 260, tex=256, rough=0.3),
            Group("lash", ["Eyelashes_m"], 220, tex=256, alpha=True, rough=0.9),
            Group("top", ["Dress_m", "DressStraps_m"], 2300, tex=512, tint="clothes", gray=True, rough=0.85),
            Group("shoes", ["SandalsSole_m", "SandalsSoleTop_m", "SandalsHeels_m", "SandalsStrap_m"], 900, tex=256, tint="shoes", gray=True),
            Group("hair", ["HairCap_m", "HairBack_m", "HairBangs1_m", "HairFront1_m", "HairSide1_m"], 2400, tex=512, tint="hair", gray=True,
                  alpha=True, rough=0.6),
        ]),
    "jamal": dict(
        src="jamal_-_lod_man_character.glb", height=1.72, female=False, weight=1.0, scale=0.01,
        groups=[
            Group("skin", ["Bodymat"], 3400, tex=512, rough=0.7),
            Group("top", ["Topmat"], 1500, tex=512, tint="clothes", gray=True, rough=0.85),
            Group("bottom", ["Bottommat"], 800, tex=512, tint="clothes", gray=True, rough=0.85),
            Group("shoes", ["Shoesmat"], 900, tex=256, tint="shoes", gray=True),
            Group("hat", ["Hatmat"], 450, tex=256, tint="hat", gray=True),
        ]),
    "peter": dict(
        src="peter_-_lod_man_character.glb", height=1.88, female=False, weight=1.0, scale=0.01,
        # three LOD sets are stored in the file; the middle one (nodes 20..28) is the right size for a background pedestrian
        groups=[
            Group("skin", [("node", 28)], 3400, tex=512, rough=0.7),
            Group("top", [("node", 20)], 1400, tex=512, tint="clothes", gray=True, rough=0.85),
            Group("bottom", [("node", 26)], 900, tex=512, tint="clothes", gray=True, rough=0.85),
            Group("shoes", [("node", 22)], 900, tex=256, tint="shoes", gray=True),
            Group("hat", [("node", 24)], 380, tex=256, tint="hat", gray=True),
        ]),
    "suit": dict(
        src="male_character_in_suit.glb", height=1.81, female=False, weight=1.0,
        groups=[
            Group("skin", ["AvatarBody"], 700, tex=512, rough=0.75),
            Group("face", ["AvatarHead"], 2100, tex=512, rough=0.7),
            Group("eyes", ["AvatarLeftEyeball", "AvatarRightEyeball"], 260, tex=256, rough=0.3),
            Group("top", ["outfit"], 3400, tex=512, tint="suit", gray=True, rough=0.8),
            Group("hair", ["haircut"], 1500, tex=512, tint="hair", gray=True, rough=0.6),
        ]),
    "biker": dict(
        src="bike_rider_3d.glb", height=1.75, female=False, weight=1.0,
        groups=[
            Group("skin", ["Wolf3D_Skin"], 4200, tex=512, rough=0.7),
            Group("eyes", ["Wolf3D_Eye"], 300, tex=256, rough=0.3),
            Group("top", ["Wolf3D_Outfit_Top"], 2200, tex=512, tint="clothes", gray=True, rough=0.85),
            Group("shoes", ["Wolf3D_Outfit_Footwear"], 900, tex=256, tint="shoes", gray=True),
            Group("hat", ["Wolf3D_Headwear"], 500, tex=256, tint="hat", gray=True, alpha=True),
        ]),
}

PALETTES = {
    "clothes": [
        ["black", [0.10, 0.10, 0.11]], ["white", [0.93, 0.93, 0.92]], ["navy", [0.10, 0.16, 0.36]], ["green", [0.16, 0.42, 0.24]],
        ["gray", [0.48, 0.49, 0.52]], ["red", [0.68, 0.14, 0.14]], ["blue", [0.20, 0.42, 0.78]], ["mustard", [0.78, 0.60, 0.16]],
        ["teal", [0.12, 0.52, 0.52]], ["brown", [0.40, 0.27, 0.18]], ["beige", [0.78, 0.70, 0.55]], ["maroon", [0.40, 0.10, 0.18]],
        ["olive", [0.40, 0.42, 0.20]], ["purple", [0.42, 0.24, 0.55]],
    ],
    "suit": [["charcoal", [0.16, 0.17, 0.19]], ["navy", [0.09, 0.13, 0.28]], ["black", [0.07, 0.07, 0.08]], ["gray", [0.38, 0.39, 0.41]],
             ["brown", [0.30, 0.20, 0.14]], ["burgundy", [0.32, 0.09, 0.14]]],
    "hair": [["black", [0.06, 0.05, 0.05]], ["dark brown", [0.16, 0.10, 0.07]], ["brown", [0.28, 0.17, 0.10]], ["blond", [0.72, 0.58, 0.32]],
             ["auburn", [0.42, 0.16, 0.09]], ["gray", [0.55, 0.55, 0.56]], ["white", [0.85, 0.85, 0.84]]],
    "shoes": [["black", [0.08, 0.08, 0.08]], ["white", [0.88, 0.88, 0.86]], ["brown", [0.30, 0.19, 0.11]], ["gray", [0.42, 0.42, 0.44]],
              ["navy", [0.10, 0.14, 0.30]], ["red", [0.60, 0.12, 0.12]]],
    "hat": [["black", [0.09, 0.09, 0.10]], ["gray", [0.45, 0.46, 0.48]], ["navy", [0.10, 0.15, 0.34]], ["red", [0.66, 0.13, 0.13]],
            ["khaki", [0.60, 0.54, 0.36]], ["white", [0.90, 0.90, 0.88]]],
}


# ----------------------------------------------------------------------------------------------------------------------
# skin evaluation
# ----------------------------------------------------------------------------------------------------------------------
def col_major_to_rows(acc):
    return np.transpose(acc.reshape(-1, 4, 4).astype(np.float64), (0, 2, 1))


class SourceRig(object):
    """A source glTF with one skin: rest joint matrices, joint tree and per-mesh rest-pose geometry."""

    def __init__(self, path, scale=1.0):
        self.g = GLB(path)
        j = self.g.json
        self.scale = scale
        sk = j["skins"][0]
        self.joint_nodes = list(sk["joints"])
        self.names = [self.clean(j["nodes"][i].get("name", "j%d" % i)) for i in self.joint_nodes]
        ibm = col_major_to_rows(self.g.accessor(sk["inverseBindMatrices"]))
        self.M = np.array([self.g.world_matrix(i).dot(ibm[k]) for k, i in enumerate(self.joint_nodes)])       # (J,4,4) rest skin matrices
        self.world = np.array([self.g.world_matrix(i)[:3, 3] for i in self.joint_nodes]) * scale
        idx_of = {n: k for k, n in enumerate(self.joint_nodes)}
        self.parent = []
        for i in self.joint_nodes:
            p = self.g.parent.get(i)
            self.parent.append(idx_of.get(p, -1))

    @staticmethod
    def clean(n):
        if n.startswith("mixamorig:"):
            n = n[len("mixamorig:"):]
        us = n.rfind("_")
        if us > 0 and n[us + 1:].isdigit():
            n = n[:us]
        return n

    def name_index(self):
        return {n: k for k, n in enumerate(self.names)}

    def mesh_prims(self):
        """list of dict(node, name, mat, pos(m), nrm, uv, idx, joints, weights) in rest pose (world, metric); computed once."""
        if getattr(self, "_prims", None) is None:
            self._prims = list(self._mesh_prims())
        return self._prims

    def _mesh_prims(self):
        g = self.g
        j = g.json
        for i, node in enumerate(g.nodes):
            if "mesh" not in node or node.get("skin") is None:
                continue
            mesh = g.meshes[node["mesh"]]
            for p in mesh["primitives"]:
                at = p["attributes"]
                pos = g.accessor(at["POSITION"]).astype(np.float64)
                nrm = g.accessor(at["NORMAL"]).astype(np.float64) if "NORMAL" in at else None
                uv = g.accessor(at["TEXCOORD_0"]).astype(np.float32) if "TEXCOORD_0" in at else None
                jn = g.accessor(at["JOINTS_0"]).astype(np.int64)
                wt = g.accessor(at["WEIGHTS_0"]).astype(np.float64)
                s = wt.sum(axis=1, keepdims=True)
                wt = wt / np.maximum(s, 1e-9)
                hp = np.concatenate([pos, np.ones((len(pos), 1))], axis=1)
                out = np.zeros((len(pos), 3))
                on = np.zeros((len(pos), 3))
                for c in range(4):
                    w = wt[:, c]
                    if not (w > 0).any():
                        continue
                    Mk = self.M[jn[:, c]]                                   # (N,4,4)
                    out += w[:, None] * np.einsum("nij,nj->ni", Mk, hp)[:, :3]
                    if nrm is not None:
                        R = Mk[:, :3, :3]
                        # rigid / uniform-scale rest matrices: the rotation part is enough for normals
                        on += w[:, None] * np.einsum("nij,nj->ni", R, nrm)
                if nrm is not None:
                    ln = np.linalg.norm(on, axis=1, keepdims=True)
                    on = on / np.maximum(ln, 1e-12)
                idx = g.accessor(p["indices"]).astype(np.int64).reshape(-1) if "indices" in p else np.arange(len(pos))
                yield {"node": i, "name": node.get("name"), "mat": p.get("material"), "matname": g.material_name(p.get("material")),
                       "pos": out * self.scale, "nrm": on if nrm is not None else None, "uv": uv, "idx": idx, "joints": jn, "weights": wt}


# ----------------------------------------------------------------------------------------------------------------------
# textures
# ----------------------------------------------------------------------------------------------------------------------
def diffuse_image_index(g, mi):
    info = g.material_info(mi)
    if info["base_img"] is not None:
        return info["base_img"]
    ext = g.materials[mi].get("extensions", {}).get("KHR_materials_pbrSpecularGlossiness", {})
    dt = ext.get("diffuseTexture")
    if dt is not None:
        return g.texture_image_index(dt["index"])
    return None


def tintable(pil, size, keep_alpha):
    """neutral, bright grayscale base that keeps the luminance detail (stitches, folds, prints); alpha is preserved when asked for."""
    im = pil.convert("RGBA")
    if max(im.size) > size:
        f = size / float(max(im.size))
        im = im.resize((max(4, int(round(im.size[0] * f))), max(4, int(round(im.size[1] * f)))), PILImage.LANCZOS)
    a = np.asarray(im).astype(np.float32) / 255.0
    lum = 0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]
    m = a[..., 3] > 0.5
    ref = np.percentile(lum[m], 92) if m.any() else 1.0
    g = np.clip(lum / max(ref, 0.05) * 0.95, 0.0, 1.0)
    g = 0.25 + 0.75 * g                     # keep detail but never fully black so dark tints still show folds
    out = np.stack([g, g, g, a[..., 3] if keep_alpha else np.ones_like(g)], axis=-1)
    return PILImage.fromarray((out * 255).astype(np.uint8), "RGBA")


def group_texture(cache, g, mat_index, grp, keep_alpha):
    ii = diffuse_image_index(g, mat_index)
    if ii is None:
        return None
    pil = g.pil_image(ii)
    key = ("npc", id(g), ii, grp.gray, grp.tex, keep_alpha)
    if grp.gray:
        im = tintable(pil, grp.tex, keep_alpha)
        return cache.get(key, im, grp.tex, quality=86, force_png=keep_alpha, name="%s_tex" % grp.name)
    if pil.mode in ("RGBA", "LA", "P"):
        rgba = pil.convert("RGBA")
        if not keep_alpha:
            bg = PILImage.new("RGB", rgba.size, (128, 128, 128))
            bg.paste(rgba, mask=rgba.split()[3])
            pil = bg
    return cache.get(key, pil, grp.tex, quality=86, force_png=keep_alpha, name="%s_tex" % grp.name)


# ----------------------------------------------------------------------------------------------------------------------
# decimation + weight transfer
# ----------------------------------------------------------------------------------------------------------------------
def transfer_weights(src_pos, src_joints, src_weights, dst_pos, k=3):
    tree = cKDTree(src_pos)
    d, ii = tree.query(dst_pos, k=min(k, len(src_pos)))
    if ii.ndim == 1:
        ii = ii[:, None]
        d = d[:, None]
    w = 1.0 / (d + 1e-4)
    n = len(dst_pos)
    J = np.zeros((n, 4), dtype=np.int64)
    Wt = np.zeros((n, 4), dtype=np.float64)
    for v in range(n):
        acc = {}
        for c in range(ii.shape[1]):
            sv = ii[v, c]
            for s in range(4):
                sw = src_weights[sv, s]
                if sw <= 0:
                    continue
                jj = int(src_joints[sv, s])
                acc[jj] = acc.get(jj, 0.0) + sw * w[v, c]
        top = sorted(acc.items(), key=lambda kv: -kv[1])[:4]
        tot = sum(x[1] for x in top) or 1.0
        for s, (jj, ww) in enumerate(top):
            J[v, s] = jj
            Wt[v, s] = ww / tot
        if not top:
            Wt[v, 0] = 1.0
    return J, Wt


def gather_group(rig, grp):
    """all source meshes of a group: list of dict(pos,nrm,uv,idx,joints,weights,mat)"""
    out = []
    for p in rig.mesh_prims():
        for s in grp.sources:
            if isinstance(s, tuple):
                if p["node"] == s[1]:
                    out.append(p)
            elif p["matname"] == s:
                out.append(p)
    return out



def welded_normals(pos, idx):
    """smooth vertex normals; vertices that share a position (uv seams) share one normal so there are no visible seams"""
    pos = np.asarray(pos, dtype=np.float64)
    idx = np.asarray(idx).reshape(-1, 3)
    p = pos[idx]
    fn = np.cross(p[:, 1] - p[:, 0], p[:, 2] - p[:, 0])              # area weighted
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

# ----------------------------------------------------------------------------------------------------------------------
# build
# ----------------------------------------------------------------------------------------------------------------------
def skeleton_nodes(rig, drop_names=("_rootJoint", "rootJoint")):
    """baked joints: identity rotation, metric translation. Returns (root, joint_nodes(list, same order as kept joints), keep index map)."""
    keep = [k for k, n in enumerate(rig.names) if n not in drop_names]
    remap = {}
    for new, old in enumerate(keep):
        remap[old] = new
    # dropped joints redirect to their nearest kept ancestor (usually Hips)
    for old in range(len(rig.names)):
        if old in remap:
            continue
        a = rig.parent[old]
        while a >= 0 and a not in remap:
            a = rig.parent[a]
        remap[old] = remap[a] if a >= 0 else 0
    nodes = {}
    roots = []
    for old in keep:
        nodes[old] = W.Node(rig.names[old], translation=[0, 0, 0])
    for old in keep:
        p = rig.parent[old]
        while p >= 0 and p not in nodes:
            p = rig.parent[p]
        if p < 0:
            roots.append(old)
            nodes[old].translation = [float(x) for x in rig.world[old]]
        else:
            nodes[old].translation = [float(x) for x in (rig.world[old] - rig.world[p])]
            nodes[p].add(nodes[old])
    assert len(roots) == 1, "expected a single root joint, got %s" % [rig.names[r] for r in roots]
    return nodes[roots[0]], [nodes[o] for o in keep], keep, remap


def build_archetype(name, cfg, cache, work):
    print("== %s" % name)
    path = os.path.join(ASSETS, cfg["src"])
    rig = SourceRig(path, scale=cfg.get("scale", 1.0))
    root_joint, joint_nodes, keep, remap = skeleton_nodes(rig)
    world = rig.world[keep]
    ibm = np.zeros((len(keep), 4, 4))
    for k in range(len(keep)):
        m = np.eye(4)
        m[:3, 3] = -world[k]
        ibm[k] = m
    return finish_archetype(name, cfg, rig, cache, work, root_joint, joint_nodes, remap, ibm, world, rig.names, keep)


def finish_archetype(name, cfg, rig, cache, work, root_joint, joint_nodes, remap, ibm, world, names, keep):
    g = rig.g
    # ---- gather + decimate
    jobs = {}
    meta_of = {}
    for grp in cfg["groups"]:
        srcs = gather_group(rig, grp)
        if not srcs:
            raise RuntimeError("%s: group %s found no meshes" % (name, grp.name))
        total = sum(len(s["idx"]) // 3 for s in srcs)
        for n, s in enumerate(srcs):
            t = len(s["idx"]) // 3
            target = max(40, int(grp.tris * t / float(total)))
            key = "%s_%s_%d" % (name[:3], grp.name[:4], n)
            ratio = min(1.0, target / float(t))
            jobs[key] = {"pos": s["pos"].astype(np.float32), "idx": s["idx"].reshape(-1, 3), "uv": s["uv"], "ratio": ratio}
            meta_of[key] = (grp, s)
    res = decimate_cached(jobs, work)

    prims_by_group = {}
    tri_count = 0
    for key, (grp, s) in meta_of.items():
        r = res[key]
        pos = np.asarray(r["pos"], dtype=np.float64)
        uv = r["uv"]
        idx = np.asarray(r["idx"], dtype=np.int64)
        J, Wt = transfer_weights(s["pos"], s["joints"], s["weights"], pos)
        # remap dropped joints (e.g. _rootJoint -> Hips) and merge duplicates
        for v in range(len(J)):
            acc = {}
            for c in range(4):
                if Wt[v, c] <= 0:
                    continue
                jj = remap[int(J[v, c])]
                acc[jj] = acc.get(jj, 0.0) + Wt[v, c]
            items = sorted(acc.items(), key=lambda kv: -kv[1])[:4]
            tot = sum(x[1] for x in items) or 1.0
            J[v] = 0
            Wt[v] = 0
            for c, (jj, ww) in enumerate(items):
                J[v, c] = jj
                Wt[v, c] = ww / tot
        prims_by_group.setdefault(grp.name, []).append((grp, s, pos, uv, idx, J, Wt))

    mats = []
    prims = []
    for grp in cfg["groups"]:
        parts = prims_by_group[grp.name]
        # merge all parts of the group into one primitive
        P, U, I, JJ, WW = [], [], [], [], []
        off = 0
        for (_, s, pos, uv, idx, J, Wt) in parts:
            P.append(pos)
            U.append(uv if uv is not None else np.zeros((len(pos), 2), dtype=np.float32))
            I.append(idx + off)
            JJ.append(J)
            WW.append(Wt)
            off += len(pos)
        P = np.concatenate(P)
        U = np.concatenate(U)
        I = np.concatenate(I).reshape(-1, 3)
        JJ = np.concatenate(JJ)
        WW = np.concatenate(WW)
        nrm = welded_normals(P, I)
        first = parts[0][1]
        tex = group_texture(cache, g, first["mat"], grp, grp.alpha) if first["mat"] is not None else None
        base = [1, 1, 1, 1]
        mat = W.Material(grp.name, base, grp.metal, grp.rough, base_image=tex, alpha_mode="BLEND" if grp.alpha else "OPAQUE",
                         double_sided=grp.alpha or grp.double or True)
        mats.append(mat)
        prims.append(W.Prim(P, I.reshape(-1), nrm=nrm, uv=U, material=mat, joints=JJ, weights=WW))
        tri_count += len(I)
        print("   %-7s %6d tris  %s" % (grp.name, len(I), "tex" if tex is not None else "no-tex"))

    root = W.Node("npc_" + name)
    root.add(root_joint)
    skin = W.Skin(name + "_skin", joint_nodes, ibm, skeleton=root_joint)
    mesh_node = W.Node("body", mesh=W.Mesh("body", prims), skin=skin)
    root.add(mesh_node)
    out = os.path.join(MODELS, "npc_%s.glb" % name)
    info = W.write_glb(out, [root], scene_name="npc_" + name)
    print("   ->", out, info)
    allpos = np.concatenate([p.pos for p in prims])
    idx_of = {n: k for k, n in enumerate([names[o] for o in keep])}
    meta = {
        "file": "npc_%s" % name,
        "height": round(float(allpos[:, 1].max() - allpos[:, 1].min()), 3),
        "hipHeight": round(float(world[idx_of["Hips"]][1]), 3),
        "female": bool(cfg["female"]),
        "weight": cfg["weight"],
        "triangles": tri_count,
        "slots": [{"material": grp.name, "palette": grp.tint} for grp in cfg["groups"] if grp.tint],
    }
    return meta


def build_casual_female(cache, work, ref_meta):
    """rigs female_character_with_casual_clothing.glb (static T-pose mesh) with the christie skeleton"""
    print("== casual_female (auto-rig)")
    ref = SourceRig(os.path.join(ASSETS, ARCH["christie"]["src"]))
    tgt = GLB(os.path.join(ASSETS, "female_character_with_casual_clothing.glb"))
    # ---- target geometry (world, metric)
    tp = []
    for p in tgt.primitives():
        tp.append(p)
    P_all = np.concatenate([p["pos"] for p in tp])
    hmin, hmax = P_all[:, 1].min(), P_all[:, 1].max()
    print("   target bbox", P_all.min(0).round(3), P_all.max(0).round(3))
    # ---- warp the reference rig onto the target: uniform height scale + arm extension beyond the shoulder
    ref_h = 1.861                                   # christie head top
    sy = (hmax - hmin) / ref_h
    sh = 0.16
    ref_wrist = 0.481 + 0.0
    tgt_arm_x = float(P_all[:, 0].max())
    ref_arm_x = 0.638
    ax = (tgt_arm_x - sh) / (ref_arm_x - sh)
    print("   height scale %.3f arm scale %.3f" % (sy, ax))

    def warp(P):
        Q = P.copy()
        Q[:, 1] = Q[:, 1] * sy + hmin
        x = np.abs(Q[:, 0])
        big = x > sh
        Q[big, 0] = np.sign(Q[big, 0]) * (sh + (x[big] - sh) * ax)
        return Q

    # ---- reference skinned geometry (whole christie body + dress, no hair / face details) for the weight transfer
    RP, RJ, RW = [], [], []
    for p in ref.mesh_prims():
        if p["matname"] in ("Body_m", "Arms_m", "Legs_m", "Dress_m", "DressStraps_m", "Facedetails_m", "Ears_m", "SandalsSole_m", "SandalsStrap_m",
                            "HairBack_m", "HairCap_m"):
            RP.append(p["pos"])
            RJ.append(p["joints"])
            RW.append(p["weights"])
    RP = warp(np.concatenate(RP))
    RJ = np.concatenate(RJ)
    RW = np.concatenate(RW)
    ref.world = warp(ref.world)
    root_joint, joint_nodes, keep, remap = skeleton_nodes(ref)
    world = ref.world[keep]
    ibm = np.zeros((len(keep), 4, 4))
    for k in range(len(keep)):
        m = np.eye(4)
        m[:3, 3] = -world[k]
        ibm[k] = m

    # ---- decimate + weights
    jobs = {}
    for n, p in enumerate(tp):
        t = len(p["idx"]) // 3
        target = 3300 if t > 5000 else 600
        jobs["cas_%d" % n] = {"pos": p["pos"].astype(np.float32), "idx": p["idx"].reshape(-1, 3), "uv": p["uv"], "ratio": min(1.0, target / float(t))}
    res = decimate_cached(jobs, work)
    P, U, I, JJ, WW = [], [], [], [], []
    off = 0
    for n, p in enumerate(tp):
        r = res["cas_%d" % n]
        pos = np.asarray(r["pos"], dtype=np.float64)
        J, Wt = transfer_weights(RP, RJ, RW, pos, k=4)
        for v in range(len(J)):
            acc = {}
            for c in range(4):
                if Wt[v, c] <= 0:
                    continue
                jj = remap[int(J[v, c])]
                acc[jj] = acc.get(jj, 0.0) + Wt[v, c]
            items = sorted(acc.items(), key=lambda kv: -kv[1])[:4]
            tot = sum(x[1] for x in items) or 1.0
            J[v] = 0
            Wt[v] = 0
            for c, (jj, ww) in enumerate(items):
                J[v, c] = jj
                Wt[v, c] = ww / tot
        P.append(pos)
        U.append(r["uv"])
        I.append(np.asarray(r["idx"], dtype=np.int64) + off)
        JJ.append(J)
        WW.append(Wt)
        off += len(pos)
    P = np.concatenate(P)
    U = np.concatenate(U)
    I = np.concatenate(I).reshape(-1, 3)
    JJ = np.concatenate(JJ)
    WW = np.concatenate(WW)
    nrm = welded_normals(P, I)
    mi = tp[0]["mat"]
    ii = diffuse_image_index(tgt, mi)
    tex = cache.get(("cas", ii), tgt.pil_image(ii), 1024, quality=86, name="casual_tex")
    mat = W.Material("skin", [1, 1, 1, 1], 0.0, 0.75, base_image=tex, double_sided=True)
    prim = W.Prim(P, I.reshape(-1), nrm=nrm, uv=U, material=mat, joints=JJ, weights=WW)
    root = W.Node("npc_casual")
    root.add(root_joint)
    skin = W.Skin("casual_skin", joint_nodes, ibm, skeleton=root_joint)
    root.add(W.Node("body", mesh=W.Mesh("body", [prim]), skin=skin))
    out = os.path.join(MODELS, "npc_casual.glb")
    info = W.write_glb(out, [root], scene_name="npc_casual")
    print("   ->", out, info, "tris", len(I))
    names = [ref.names[o] for o in keep]
    idx_of = {n: k for k, n in enumerate(names)}
    return {"file": "npc_casual", "height": round(float(P[:, 1].max() - P[:, 1].min()), 3), "hipHeight": round(float(world[idx_of["Hips"]][1]), 3),
            "female": True, "weight": 1.0, "triangles": len(I), "slots": []}


def main():
    ensure_dirs()
    want = sys.argv[1:] or (list(ARCH.keys()) + ["casual"])
    work = os.path.join(SCRATCH, "npc")
    os.makedirs(work, exist_ok=True)
    cache = ImageCache()
    meta = {}
    mp = os.path.join(DATA, "npc_meta.json")
    if os.path.exists(mp):
        try:
            meta = json.load(open(mp)).get("archetypes", {})
        except Exception:
            meta = {}
    for name in want:
        if name == "casual":
            meta["casual"] = build_casual_female(cache, work, meta)
        else:
            meta[name] = build_archetype(name, ARCH[name], cache, work)
    doc = {"archetypes": meta, "palettes": {k: [{"name": n, "rgb": c} for n, c in v] for k, v in PALETTES.items()}}
    json.dump(doc, open(mp, "w"), indent=1)
    print("npc_meta.json written:", sorted(meta.keys()))


if __name__ == "__main__":
    main()
