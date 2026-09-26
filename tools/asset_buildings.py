# -*- coding: utf-8 -*-
"""buildings.glb (10 low-poly buildings laid out in one scene) -> building_01.glb ... building_10.glb + buildings_meta.json

Mapping (source top-level node -> output): Building -> building_01, Building_01 -> building_02, ... Building_09 -> building_10.
Every output has its pivot at the bottom centre of the footprint, y up, street facade toward +Z (all source buildings already face +Z:
the area-weighted normals of their 'Shops_*' materials point to +Z, which is asserted below), metres.
Textures: <= 1024 (source already <= 1024), JPEG since none has alpha, UV tiling untouched (no atlasing).
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
    g = GLB(os.path.join(SRC, "buildings.glb"))
    groups = {}
    for p in g.primitives():
        i = p["node"]
        while True:
            par = g.parent.get(i)
            if par is None or g.nodes[par].get("name") == "RootNode":
                break
            i = par
        groups.setdefault(g.nodes[i]["name"], []).append(p)
    names = sorted(groups.keys(), key=lambda s: (s != "Building", s))
    assert len(names) == 10, names
    cache = ImageCache()
    metas = []
    for k, bname in enumerate(names):
        out_name = "building_%02d" % (k + 1)
        ps = groups[bname]
        P = np.concatenate([p["pos"] for p in ps])
        lo, hi = P.min(0), P.max(0)
        pivot = np.array([(lo[0] + hi[0]) / 2.0, lo[1], (lo[2] + hi[2]) / 2.0])
        mats = {}
        prims = []
        tris = 0
        shop_boxes = []
        facing = np.zeros(3)
        for p in ps:
            mi = p["mat"]
            info = g.material_info(mi)
            if mi not in mats:
                img = None
                if info["base_img"] is not None:
                    pil = g.pil_image(info["base_img"])
                    img = cache.get(("src", info["base_img"], out_name), pil, 1024, quality=88, name="%s_%s" % (out_name, info["name"]))
                mats[mi] = W.Material(info["name"], (1, 1, 1, 1), 0.0, 0.9, base_image=img, double_sided=True)
            pos = p["pos"] - pivot
            idx = p["idx"].reshape(-1, 3)
            nrm = p["nrm"]
            if p["flip"]:
                idx = idx[:, ::-1]
            tris += len(idx)
            prims.append(W.Prim(pos, idx, nrm=nrm, uv=p["uv"], material=mats[mi]))
            if info["name"].startswith("Shops"):
                v = pos[idx]
                n = np.cross(v[:, 1] - v[:, 0], v[:, 2] - v[:, 0])
                facing += n.sum(axis=0)
                shop_boxes.append((pos.min(0), pos.max(0)))
        assert facing[2] > 0 and abs(facing[2]) > 3 * abs(facing[0]), (bname, facing)
        # door guess: the shop closest to the middle of the facade, at street level, on the front plane
        shops = sorted(shop_boxes, key=lambda b: abs((b[0][0] + b[1][0]) / 2.0))
        sb = shops[0]
        door = [round(float((sb[0][0] + sb[1][0]) / 2.0), 3), 0.0, round(float(sb[1][2]), 3)]
        root = W.Node(out_name)
        root.add(W.Node(out_name + "_mesh", mesh=W.Mesh(out_name, prims)))
        info = W.write_glb(os.path.join(MODELS, out_name + ".glb"), [root], scene_name=out_name,
                           asset_extras={"source": "Buildings by Elbolillo (%s), CC-BY-4.0" % bname})
        size = hi - lo
        metas.append({"name": out_name, "source": bname, "size": [round(float(size[0]), 3), round(float(size[1]), 3), round(float(size[2]), 3)],
                      "triangles": int(tris), "hasShops": len(shop_boxes) > 0, "roofY": round(float(size[1]), 3), "doorLocal": door,
                      "bytes": info["bytes"]})
        print(out_name, bname, "tris", tris, "size", metas[-1]["size"], "bytes", info["bytes"], "door", door)
    json.dump({"buildings": metas}, open(os.path.join(DATA, "buildings_meta.json"), "w"), indent=1)


if __name__ == "__main__":
    build()
