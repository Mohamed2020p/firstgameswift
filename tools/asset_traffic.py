# -*- coding: utf-8 -*-
"""ford_mondeo_taxi.glb, ford_ranger_police.glb, free_fire_solo_house_by_no_rules_yt.glb -> game-ready GLBs + Data/traffic_meta.json

Source files are read only.  For the two vehicles:
  * the four wheels are separated from the body (they are loose components of the source meshes) and recentred on their hub, so the
    game can steer (steer_FL / steer_FR pivots), spin (wheel_XX) and move them on their suspension independently;
  * everything is scaled to the real vehicle length, wheels touch y = 0, the origin sits midway between the axles, the car faces +Z
    with +X on the left;
  * the three identical 2048 px atlases are merged into one 1024 px JPEG;
  * the police light bar's two lamps become their own nodes / materials so they can flash.
The house is scaled to ~7 x 10 m, footprint centred, foundation on the ground.
"""
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import glb_write as W                                       # noqa: E402
from glb_lib import GLB                                     # noqa: E402
from asset_common import ImageCache, MODELS, DATA, ensure_dirs   # noqa: E402
import asset_mesh as M                                      # noqa: E402

ASSETS = os.environ.get("NPC_SRC", r"C:\Users\c0derz\Downloads\assets")

VEHICLES = {
    "taxi": dict(src="ford_mondeo_taxi.glb", length=4.87, rough=0.45, metal=0.25),
    "police": dict(src="ford_ranger_police.glb", length=5.36, rough=0.5, metal=0.25),
}


def wheel_components(pos, idx):
    """component labels + list of wheel component ids (thin in x, round in yz, out at the sides)"""
    lab, nc = M.components(pos, idx)
    wheels = []
    for c in range(nc):
        f = idx[lab == c]
        q = pos[np.unique(f)]
        mn, mx = q.min(0), q.max(0)
        ext = mx - mn
        cx = 0.5 * (mn[0] + mx[0])
        if ext[0] < 15 and 26 < ext[1] < 38 and 26 < ext[2] < 38 and abs(cx) > 25 and len(f) >= 40:
            wheels.append(c)
    return lab, wheels


def build_vehicle(name, cfg, cache):
    print("== %s" % name)
    g = GLB(os.path.join(ASSETS, cfg["src"]))
    body = {}                # material index -> list of (pos, nrm, uv, idx)
    wheels = []              # (hub, pos, nrm, uv, idx)
    lamps = []
    allp = []
    for p in g.primitives():
        pos, idx = p["pos"], p["idx"].reshape(-1, 3)
        if p["flip"]:
            idx = idx[:, ::-1]
        lab, wl = wheel_components(pos, idx)
        nc = int(lab.max()) + 1 if len(lab) else 0
        lamp_ids = []
        if name == "police" and g.material_name(p["mat"]) == "wire_028089177":
            # light bar: component 0 = bar, 1 and 2 = the two lamps (small, off to the sides)
            for c in range(nc):
                q = pos[np.unique(idx[lab == c])]
                if (q.max(0) - q.min(0))[0] < 6 and abs(q[:, 0].mean()) > 15:
                    lamp_ids.append(c)
        for c in range(nc):
            mask = lab == c
            f = idx[mask]
            sub_p, sub_i, sub_n, sub_uv = M.sub_mesh(pos, idx, mask, p["nrm"], p["uv"])
            if c in wl:
                hub = 0.5 * (sub_p.min(0) + sub_p.max(0))
                wheels.append((hub, sub_p, sub_n, sub_uv, sub_i))
            elif c in lamp_ids:
                lamps.append((sub_p, sub_n, sub_uv, sub_i))
            else:
                body.setdefault(p["mat"], []).append((sub_p, sub_n, sub_uv, sub_i))
            allp.append(sub_p)
    allp = np.concatenate(allp)
    assert len(wheels) == 4, "expected 4 wheels, found %d" % len(wheels)
    # ---- frame: length -> metres, ground at the wheel bottoms, origin midway between the axles
    S = cfg["length"] / float(allp[:, 2].max() - allp[:, 2].min())
    ground = min(h[0][1] - (w[1][:, 1].max() - w[1][:, 1].min()) * 0.5 for h, w in [(x, (x[0], x[1])) for x in wheels])
    hubs = np.array([w[0] for w in wheels])
    zc = 0.5 * (hubs[:, 2].max() + hubs[:, 2].min())
    print("   scale %.5f  ground %.2f  axle mid z %.2f" % (S, ground, zc))

    def T(p):
        q = (np.asarray(p, dtype=np.float64) - np.array([0.0, ground, zc])) * S
        return q.astype(np.float32)

    # ---- material: one merged atlas
    src_mat = None
    counts = {}
    for mi, lst in body.items():
        counts[mi] = sum(len(x[3]) for x in lst)
    src_mat = max(counts, key=lambda k: counts[k])
    info = g.material_info(src_mat)
    tex = cache.get(("veh", name), g.pil_image(info["base_img"]), 1024, quality=88, name="%s_atlas" % name)
    paint = W.Material("paint", (1, 1, 1, 1), cfg["metal"], cfg["rough"], base_image=tex, double_sided=False)
    lampL = W.Material("lampL", (0.10, 0.20, 0.85, 1), 0.0, 0.4, double_sided=True)
    lampR = W.Material("lampR", (0.85, 0.08, 0.08, 1), 0.0, 0.4, double_sided=True)

    def prim_from(parts, mat, shift=None):
        P, N, U, I, off = [], [], [], [], 0
        for (sp, sn, suv, si) in parts:
            q = T(sp)
            if shift is not None:
                q = q - shift
            P.append(q)
            N.append(sn)
            U.append(suv)
            I.append(si + off)
            off += len(sp)
        return W.Prim(np.concatenate(P), np.concatenate(I).reshape(-1), nrm=np.concatenate(N), uv=np.concatenate(U), material=mat)

    body_parts = []
    for mi, lst in body.items():
        body_parts += lst
    root = W.Node(name)
    root.add(W.Node("body", mesh=W.Mesh("body", [prim_from(body_parts, paint)])))
    if lamps:
        for (sp, sn, suv, si) in lamps:
            left = sp[:, 0].mean() > 0
            root.add(W.Node("lamp_L" if left else "lamp_R", mesh=W.Mesh("lamp", [prim_from([(sp, sn, suv, si)], lampL if left else lampR)])))
    tags = {}
    wheel_r = 0.0
    for (hub, sp, sn, suv, si) in wheels:
        left = hub[0] > 0
        front = hub[2] > zc
        tag = ("F" if front else "R") + ("L" if left else "R")
        hub_m = T(hub)
        wheel_r = 0.5 * (sp[:, 1].max() - sp[:, 1].min()) * S
        wp = prim_from([(sp, sn, suv, si)], paint, shift=hub_m)
        wn = W.Node("wheel_" + tag, mesh=W.Mesh("wheel_" + tag, [wp]))
        if front:
            st = W.Node("steer_" + tag, translation=[float(x) for x in hub_m])
            st.add(wn)
            root.add(st)
        else:
            wn.translation = [float(x) for x in hub_m]
            root.add(wn)
        tags[tag] = [round(float(x), 4) for x in hub_m]
    out = os.path.join(MODELS, "%s.glb" % name)
    inf = W.write_glb(out, [root], scene_name=name)
    print("   ->", out, inf)
    allq = T(allp)
    size = allq.max(0) - allq.min(0)
    fl, fr, rl, rr = tags["FL"], tags["FR"], tags["RL"], tags["RR"]
    return {
        "file": name, "length": round(float(size[2]), 3), "width": round(float(size[0]), 3), "height": round(float(allq[:, 1].max()), 3),
        "wheelRadius": round(float(wheel_r), 3), "frontAxleZ": fl[2], "rearAxleZ": rl[2],
        "trackFront": round(abs(fl[0] - fr[0]), 3), "trackRear": round(abs(rl[0] - rr[0]), 3), "hubY": fl[1],
        "wheelbase": round(fl[2] - rl[2], 3), "bodyMinZ": round(float(allq[:, 2].min()), 3), "bodyMaxZ": round(float(allq[:, 2].max()), 3),
        "hubs": tags,
    }


def build_house(cache):
    print("== house_ff")
    g = GLB(os.path.join(ASSETS, "free_fire_solo_house_by_no_rules_yt.glb"))
    prims = list(g.primitives())
    allp = np.concatenate([p["pos"] for p in prims])
    mn, mx = allp.min(0), allp.max(0)
    S = 0.65
    cx, cz = 0.5 * (mn[0] + mx[0]), 0.5 * (mn[2] + mx[2])
    y0 = mn[1] + 1.83 - 0.1                        # the stone plinth (about 1.8 units) sinks into the ground
    root = W.Node("house_ff")
    mats = {}
    for p in prims:
        mi = p["mat"]
        if mi not in mats:
            info = g.material_info(mi)
            tex = cache.get(("hff", info["base_img"]), g.pil_image(info["base_img"]), 512, quality=86, name="hff%d" % mi)
            mats[mi] = W.Material(g.material_name(mi).split(".")[0][:24], (1, 1, 1, 1), 0.0, 0.85, base_image=tex, double_sided=True)
        idx = p["idx"].reshape(-1, 3)
        if p["flip"]:
            idx = idx[:, ::-1]
        pos = ((p["pos"] - np.array([cx, y0, cz])) * S).astype(np.float32)
        root.add(W.Node(p["name"][:40], mesh=W.Mesh("m", [W.Prim(pos, idx.reshape(-1), nrm=p["nrm"], uv=p["uv"], material=mats[mi])])))
    out = os.path.join(MODELS, "house_ff.glb")
    inf = W.write_glb(out, [root], scene_name="house_ff")
    print("   ->", out, inf)
    size = (mx - mn) * S
    return {"file": "house_ff", "size": [round(float(size[0]), 2), round(float(mx[1] - y0) * S, 2), round(float(size[2]), 2)]}


def main():
    ensure_dirs()
    cache = ImageCache()
    meta = {}
    for name, cfg in VEHICLES.items():
        meta[name] = build_vehicle(name, cfg, cache)
    meta["house_ff"] = build_house(cache)
    json.dump(meta, open(os.path.join(DATA, "traffic_meta.json"), "w"), indent=1)
    print(json.dumps(meta, indent=1)[:1800])


if __name__ == "__main__":
    main()
