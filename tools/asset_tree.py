# -*- coding: utf-8 -*-
"""mango_tree.glb -> tree_lod0.glb / tree_lod1.glb / tree_lod2.glb + tree_meta.json

Source: 130k triangles (51k = 8008 separate leaf blades, 41k trunk+branches, 38k mangos), 6.8 m tall.
  lod0  trunk/branches decimated in Blender (Decimate collapse) + ~900 folded leaf cards (alpha tested) + a few low-poly mangos
  lod1  trunk decimated further + ~240 larger folded cards
  lod2  tapered trunk prism + 3 crossed crown cards + a flat canopy disc (alpha tested)
Leaf cards use the leaf-spray texture of the source (black background converted to alpha, 512 px, MASK, doubleSided).
Pivot = trunk base at (0, 0, 0), upright.
"""
import json
import os
import sys

import numpy as np
from PIL import Image as PILImage, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import glb_write as W                                   # noqa: E402
from glb_lib import GLB                                 # noqa: E402
from asset_common import ImageCache, MODELS, DATA, SRC, SCRATCH, ensure_dirs   # noqa: E402
from asset_decimate import decimate_cached              # noqa: E402
import asset_mesh as M                                  # noqa: E402


def leaf_texture(g, size=512):
    """leaf spray with alpha from the black background; the background colour is bled from the leaves (no dark fringes when mipmapped)"""
    from scipy.ndimage import gaussian_filter
    im = g.pil_image(3).convert("RGB")
    a = np.asarray(im).astype(np.float32)
    lum = a.max(axis=2)
    alpha = np.clip((lum - 18.0) / 30.0, 0, 1)
    alpha = np.asarray(PILImage.fromarray((alpha * 255).astype(np.uint8)).filter(ImageFilter.MinFilter(3))).astype(np.float32) / 255.0
    known = (alpha > 0.5).astype(np.float32)
    result = a.copy()
    filled = known.copy()
    for r in (2, 4, 8, 16, 32, 64):
        num = np.stack([gaussian_filter(result[..., c] * filled, r) for c in range(3)], axis=2)
        den = gaussian_filter(filled, r)
        est = num / np.maximum(den, 1e-4)[..., None]
        newpix = (filled < 0.5) & (den > 0.01)
        result[newpix] = est[newpix]
        filled[newpix] = 1.0
    result = np.where((known > 0.5)[..., None], a, result)
    out = np.dstack([np.clip(result, 0, 255), alpha * 255]).astype(np.uint8)
    return PILImage.fromarray(out, "RGBA").resize((size, size), PILImage.LANCZOS)


def crown_card_texture(leaf_rgba, size=256, seed=3):
    """procedural foliage clump for the LOD2 cards: many rotated leaf sprays inside an ellipse"""
    rng = np.random.RandomState(seed)
    canvas = PILImage.new("RGBA", (size, size), (0, 0, 0, 0))
    spray = leaf_rgba.resize((size // 3, size // 3), PILImage.LANCZOS)
    for _ in range(90):
        x = rng.uniform(-1, 1)
        y = rng.uniform(-1, 1)
        if (x * x + y * y * 1.3) > 0.85:
            continue
        s = spray.rotate(rng.uniform(0, 360), expand=True, resample=PILImage.BILINEAR)
        px = int((x * 0.5 + 0.5) * size - s.size[0] / 2)
        py = int((y * 0.5 + 0.5) * size - s.size[1] / 2)
        _paste_clip(canvas, s, px, py)
    a = np.asarray(canvas).copy()
    # darken slightly toward the bottom so the card reads as volume
    yy = np.linspace(0.85, 1.05, size)[:, None]
    a[..., :3] = np.clip(a[..., :3].astype(np.float32) * yy[..., None], 0, 255).astype(np.uint8)
    return PILImage.fromarray(a, "RGBA")


def _paste_clip(canvas, s, px, py):
    tmp = PILImage.new("RGBA", canvas.size, (0, 0, 0, 0))
    tmp.paste(s, (px, py))
    canvas.alpha_composite(tmp)


def make_cards(centres, normals, size, rng, crown_c, fold=0.35, jitter=0.35):
    """folded (V shaped) leaf cards: 4 triangles each.  returns pos, nrm, uv, idx"""
    n = len(centres)
    pos = np.zeros((n, 6, 3))
    uv = np.zeros((n, 6, 2))
    # local frame
    nz = normals / np.maximum(np.linalg.norm(normals, axis=1, keepdims=True), 1e-9)
    nz = nz + rng.normal(scale=jitter, size=nz.shape)
    nz /= np.linalg.norm(nz, axis=1, keepdims=True)
    ref = np.where(np.abs(nz[:, 1:2]) > 0.9, np.array([[1.0, 0, 0]]), np.array([[0, 1.0, 0]]))
    ex = np.cross(ref, nz)
    ex /= np.linalg.norm(ex, axis=1, keepdims=True)
    ey = np.cross(nz, ex)
    ang = rng.uniform(0, 2 * np.pi, size=n)
    c, s = np.cos(ang)[:, None], np.sin(ang)[:, None]
    ux = ex * c + ey * s
    uy = -ex * s + ey * c
    sz = size * rng.uniform(0.85, 1.25, size=n)[:, None]
    h = sz * 0.5
    # 3 columns: left edge, middle fold, right edge ; 2 rows -> use 6 verts (2 quads sharing the middle edge)
    for k, (xx, zz) in enumerate([(-1, 0), (0, 1), (1, 0)]):
        for r, yy in enumerate((-1, 1)):
            vi = k * 2 + r
            pos[:, vi] = centres + ux * (xx * h) + uy * (yy * h) + nz * (zz * fold * h)
            uv[:, vi] = np.stack([np.full(n, (xx + 1) * 0.5), np.full(n, (1 - yy) * 0.5)], axis=1)
    idx = []
    base = (np.arange(n) * 6)[:, None]
    quad = np.array([[0, 1, 3], [0, 3, 2], [2, 3, 5], [2, 5, 4]])
    idx = (base[:, :, None] + quad[None, :, :]).reshape(-1, 3)
    P = pos.reshape(-1, 3)
    radial = P - crown_c
    radial /= np.maximum(np.linalg.norm(radial, axis=1, keepdims=True), 1e-9)
    N = radial * 0.7 + np.array([0, 0.3, 0])
    N /= np.linalg.norm(N, axis=1, keepdims=True)
    return P.astype(np.float32), N.astype(np.float32), uv.reshape(-1, 2).astype(np.float32), idx


def prism(radius0, radius1, y0, y1, sides, cx=0.0, cz=0.0):
    """closed-side tapered prism (no caps): returns pos, idx"""
    pos = []
    for y, r in ((y0, radius0), (y1, radius1)):
        for i in range(sides):
            a = 2 * np.pi * i / sides
            pos.append((cx + r * np.cos(a), y, cz + r * np.sin(a)))
    idx = []
    for i in range(sides):
        j = (i + 1) % sides
        idx += [(i, sides + i, sides + j), (i, sides + j, j)]
    return np.array(pos), np.array(idx)


def octa(c, r):
    v = np.array([[r, 0, 0], [-r, 0, 0], [0, r * 1.3, 0], [0, -r * 1.6, 0], [0, 0, r], [0, 0, -r]]) + c
    f = np.array([[2, 4, 0], [2, 1, 4], [2, 5, 1], [2, 0, 5], [3, 0, 4], [3, 4, 1], [3, 1, 5], [3, 5, 0]])
    return v, f


def build():
    ensure_dirs()
    g = GLB(os.path.join(SRC, "mango_tree.glb"))
    src = {}
    for p in g.primitives():
        idx = p["idx"].reshape(-1, 3)
        if p["flip"]:
            idx = idx[:, ::-1]
        src[g.material_name(p["mat"])] = {"pos": p["pos"], "idx": idx, "uv": p["uv"], "nrm": p["nrm"]}
    trunk, leaves, fruit = src["Material.002"], src["Material.001"], src["Material.004"]
    # pivot: trunk base centre
    low = trunk["pos"][:, 1] < trunk["pos"][:, 1].min() + 0.25
    cx, cz = trunk["pos"][low, 0].mean(), trunk["pos"][low, 2].mean()
    y0 = trunk["pos"][:, 1].min() + 0.04
    shift = np.array([cx, y0, cz])
    for d in (trunk, leaves, fruit):
        d["pos"] = d["pos"] - shift
    allp = np.concatenate([trunk["pos"], leaves["pos"]])
    height = float(allp[:, 1].max())
    crown_lo = leaves["pos"].min(0)
    crown_hi = leaves["pos"].max(0)
    crown_c = (crown_lo + crown_hi) / 2.0
    crown_r = float(max(crown_hi[0] - crown_lo[0], crown_hi[2] - crown_lo[2]) / 2.0)
    print("tree height %.2f crown radius %.2f crown centre %s" % (height, crown_r, np.round(crown_c, 2)))

    # ---- leaf blades: centroids + normals
    lab, nc = M.components(leaves["pos"], leaves["idx"], 1e-4)
    cen = np.zeros((nc, 3))
    nrm = np.zeros((nc, 3))
    v = leaves["pos"][leaves["idx"]]
    fn = np.cross(v[:, 1] - v[:, 0], v[:, 2] - v[:, 0])
    fc = v.mean(axis=1)
    fa = np.linalg.norm(fn, axis=1)
    np.add.at(cen, lab, fc * fa[:, None])
    np.add.at(nrm, lab, fn)
    area = np.bincount(lab, weights=fa, minlength=nc)
    cen /= np.maximum(area, 1e-12)[:, None]
    print("leaf blades:", nc, "mean blade area %.4f m2" % (area.mean() / 2))

    # ---- textures
    leaf_img_pil = leaf_texture(g, 512)
    cache = ImageCache()
    bark_img = cache.get("bark", g.pil_image(1), 512, quality=86, name="bark", force_rgb=True)
    from asset_common import has_real_alpha
    leaf_data = W.png_bytes(leaf_img_pil)
    leaf_img = W.Image("leaves", leaf_data, "image/png")
    crown_pil = crown_card_texture(leaf_img_pil, 256)
    crown_img = W.Image("crown", W.png_bytes(crown_pil), "image/png")

    mat_bark = W.Material("bark", (1.0, 0.92, 0.82, 1), 0.0, 0.95, base_image=bark_img, double_sided=True)
    mat_leaf = W.Material("leaves", (1, 1, 1, 1), 0.0, 0.9, base_image=leaf_img, alpha_mode="MASK", alpha_cutoff=0.5, double_sided=True)
    mat_crown = W.Material("leaves", (1, 1, 1, 1), 0.0, 0.9, base_image=crown_img, alpha_mode="MASK", alpha_cutoff=0.5, double_sided=True)
    mat_fruit = W.Material("mango", (0.86, 0.55, 0.12, 1), 0.0, 0.5)

    # ---- trunk decimation through Blender: the twig soup (1455 loose components) cannot be collapsed by Blender, so only the
    #      main connected stem/branch structure is kept for the LODs (the leaf cards hide the twigs anyway)
    tl, tnc = M.components(trunk["pos"], trunk["idx"], 1e-5)
    main = np.argmax(np.bincount(tl))
    mpos, midx, muv = M.sub_mesh(trunk["pos"], trunk["idx"], tl == main, trunk["uv"])
    print("main trunk component tris:", len(midx))
    jobs = {"trunk0": {"pos": mpos, "idx": midx, "uv": muv, "ratio": 2000.0 / len(midx)}}
    res = decimate_cached(jobs, SCRATCH)
    # lod1: vertex clustering of the lod0 stem (Blender cannot collapse the branch tubes below ~2.3k triangles)
    r0 = res["trunk0"]
    cp, ci, cu = M.cluster_decimate(r0["pos"], r0["idx"], r0["uv"], target=430)
    res["trunk1"] = {"pos": cp.astype(np.float32), "idx": ci, "uv": cu.astype(np.float32)}
    print("trunk lod tris:", len(res["trunk0"]["idx"]), len(res["trunk1"]["idx"]))

    def trunk_prim(r):
        pos, idx, uv = r["pos"], r["idx"], r["uv"]
        idx = M.remove_degenerate(pos, idx)
        pos, idx, uv = M.compact(pos, idx, uv)
        p2, n2, uv2, i2 = M.smooth_normals(pos, idx, uv, 60.0)
        return W.Prim(p2, i2, nrm=n2, uv=uv2, material=mat_bark)

    info_all = {}
    rng = np.random.RandomState(7)
    order = rng.permutation(nc)

    # LOD0
    t0 = trunk_prim(res["trunk0"])
    sel = order[:900]
    P, N, UV, I = make_cards(cen[sel], nrm[sel], 0.78, np.random.RandomState(11), crown_c)
    leaf0 = W.Prim(P, I, nrm=N, uv=UV, material=mat_leaf)
    # fruits (a few, low poly)
    fp = fruit["pos"]
    flab, fnc = M.components(fp, fruit["idx"], 1e-4)
    fcen = np.array([fp[fruit["idx"][flab == c]].reshape(-1, 3).mean(0) for c in range(fnc)])
    fverts, fidx = [], []
    off = 0
    for k in np.random.RandomState(5).permutation(fnc)[:36]:
        v_, f_ = octa(fcen[k] - np.array([0, 0.06, 0]), 0.055)
        fverts.append(v_)
        fidx.append(f_ + off)
        off += len(v_)
    fv, fi = np.concatenate(fverts), np.concatenate(fidx)
    p2, n2, _, i2 = M.smooth_normals(fv, fi, None, 80.0)
    fr0 = W.Prim(p2, i2, nrm=n2, material=mat_fruit)
    tri0 = write_lod("tree_lod0", [t0, leaf0, fr0], "tree_lod0")
    # LOD1
    t1 = trunk_prim(res["trunk1"])
    sel1 = order[:250]
    P, N, UV, I = make_cards(cen[sel1], nrm[sel1], 1.5, np.random.RandomState(13), crown_c)
    leaf1 = W.Prim(P, I, nrm=N, uv=UV, material=mat_leaf)
    tri1 = write_lod("tree_lod1", [t1, leaf1], "tree_lod1")
    # LOD2 : trunk prism + 3 crossed crown cards + flat disc, <= 80 triangles
    tp, ti = prism(0.42, 0.22, 0.0, crown_c[1] + 0.3, 6)
    tn = tp.copy()
    tn[:, 1] = 0
    tn /= np.maximum(np.linalg.norm(tn, axis=1, keepdims=True), 1e-9)
    trunk2 = W.Prim(tp, ti, nrm=tn, material=W.Material("bark", (0.30, 0.20, 0.13, 1), 0.0, 0.95))
    cw = crown_r * 2.0 * 1.05
    ch = (crown_hi[1] - crown_lo[1]) * 1.05
    cy = crown_c[1]
    cp, cuv, ci = [], [], []
    for k in range(3):
        a = np.pi * k / 3.0
        d = np.array([np.cos(a), 0, np.sin(a)])
        for (sx, sy, u, vv) in ((-1, -1, 0, 1), (1, -1, 1, 1), (1, 1, 1, 0), (-1, 1, 0, 0)):
            cp.append(np.array([crown_c[0], cy, crown_c[2]]) + d * (sx * cw / 2) + np.array([0, sy * ch / 2, 0]))
            cuv.append((u, vv))
        b = k * 4
        ci += [(b, b + 1, b + 2), (b, b + 2, b + 3)]
    # horizontal disc (4 tris, octagon fan-less: 2 quads)
    b = len(cp)
    for (sx, sz, u, vv) in ((-1, -1, 0, 0), (1, -1, 1, 0), (1, 1, 1, 1), (-1, 1, 0, 1)):
        cp.append(np.array([crown_c[0] + sx * crown_r * 0.95, crown_lo[1] + ch * 0.35, crown_c[2] + sz * crown_r * 0.95]))
        cuv.append((u, vv))
    ci += [(b, b + 2, b + 1), (b, b + 3, b + 2)]
    cp = np.array(cp)
    cn = np.tile(np.array([0, 1.0, 0]), (len(cp), 1))
    crown2 = W.Prim(cp, np.array(ci), nrm=cn, uv=np.array(cuv, dtype=np.float32), material=mat_crown)
    tri2 = write_lod("tree_lod2", [trunk2, crown2], "tree_lod2")

    trunk_r = float(np.percentile(np.linalg.norm(trunk["pos"][low][:, [0, 2]], axis=1), 90))
    meta = {"height": round(height, 3), "crownRadius": round(crown_r, 3), "trunkRadius": round(trunk_r, 3),
            "crownBottomY": round(float(crown_lo[1]), 3), "crownCenterY": round(float(crown_c[1]), 3),
            "lods": [{"name": "tree_lod0", "triangles": tri0, "maxDistance": 45},
                     {"name": "tree_lod1", "triangles": tri1, "maxDistance": 140},
                     {"name": "tree_lod2", "triangles": tri2, "maxDistance": 1000}]}
    json.dump(meta, open(os.path.join(DATA, "tree_meta.json"), "w"), indent=1)
    print("tree_meta", meta)


def write_lod(name, prims, mesh_name):
    root = W.Node(name)
    root.add(W.Node(name + "_mesh", mesh=W.Mesh(mesh_name, prims)))
    info = W.write_glb(os.path.join(MODELS, name + ".glb"), [root], scene_name=name,
                       asset_extras={"source": "Mango Tree by stealth86, CC-BY-4.0"})
    print(name, info)
    return info["triangles"]


if __name__ == "__main__":
    build()
