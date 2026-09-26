# -*- coding: utf-8 -*-
"""Porsche 992 GT3 R  ->  car_player.glb / car_ai.glb / car_meta.json

Source GLB: Sketchfab export, world scale 1/100, glTF Y up, +Z front, +X left (already the game convention), 4.768 x 2.049 x 1.253 m.
Game space: metres, Y up, +Z front, +X left, origin on the ground midway between the axles.
"""
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import glb_write as W                                  # noqa: E402
from glb_lib import GLB                                # noqa: E402
from asset_common import (ImageCache, MODELS, DATA, SCRATCH, SRC, quat_from_matrix, ensure_dirs)  # noqa: E402
from asset_decimate import decimate_cached             # noqa: E402
import asset_mesh as M                                 # noqa: E402

S = 100.0


# =====================================================================================================================
# source loading
# =====================================================================================================================
class Src(object):
    """all source primitives in game space, addressable by their 'Object_N' name"""

    def __init__(self):
        self.g = GLB(os.path.join(SRC, "2024_porsche_992_gt3_r.glb"))
        parts = {}
        for p in self.g.primitives():
            pos = p["pos"] * S
            idx = p["idx"].reshape(-1, 3)
            if p["flip"]:
                idx = idx[:, ::-1]
            parts[p["name"]] = {"name": p["name"], "mat": p["mat"], "matname": self.g.material_name(p["mat"]), "pos": pos,
                                "idx": idx, "uv": p["uv"], "nrm": p["nrm"]}
        # ground & axle reference from the tyres
        tyres = [q for q in parts.values() if q["matname"].startswith("MI_Tyre")]
        self.y0 = min(q["pos"][:, 1].min() for q in tyres)
        cz = {}
        for q in tyres:
            lo, hi = q["pos"].min(0), q["pos"].max(0)
            cz[q["name"]] = (lo[2] + hi[2]) / 2.0
        zs = sorted(cz.values())
        front, rear = np.mean(zs[-2:]), np.mean(zs[:2])
        self.zmid = (front + rear) / 2.0
        for q in parts.values():
            q["pos"] = q["pos"] - np.array([0.0, self.y0, self.zmid])
        self.parts = parts
        # split the big body mesh: rear wing components
        b = parts.pop("Object_96")
        lab, nc = M.components(b["pos"], b["idx"])
        cen = np.zeros((nc, 3))
        for c in range(nc):
            m = lab == c
            P = b["pos"][b["idx"][m]].reshape(-1, 3)
            cen[c] = (P.min(0) + P.max(0)) / 2.0
        wing_c = [c for c in range(nc) if cen[c][2] < -1.89 and cen[c][1] > 0.95]
        wing_mask = np.isin(lab, wing_c)
        for nm, mask in (("body96", ~wing_mask), ("wing96", wing_mask)):
            pp, ii, uu = M.sub_mesh(b["pos"], b["idx"], mask, b["uv"])
            parts[nm] = {"name": nm, "mat": b["mat"], "matname": b["matname"], "pos": pp, "idx": ii, "uv": uu, "nrm": None}

    def wheel_parts(self):
        """returns {corner: {'tyre','rim','disc','caliper'}: source names}  corner in FL FR RL RR"""
        out = {}
        zref = 0.0
        for q in self.parts.values():
            mn = q["matname"]
            kind = None
            if mn.startswith("MI_Tyre"):
                kind = "tyre"
            elif mn.startswith("EXT_RIM_") and mn[8:].isdigit() and len(q["idx"]) > 5000:      # the 6.4k opaque rim, not the static/blur ones
                kind = "rim"
            elif mn.startswith("EXT_Disc"):
                kind = "disc"
            elif mn.startswith("EXT_CALIPER"):
                kind = "caliper"
            if kind is None:
                continue
            c = q["pos"].mean(0)
            corner = ("F" if c[2] > zref else "R") + ("L" if c[0] > 0 else "R")
            out.setdefault(corner, {})[kind] = q["name"]
        return out


# =====================================================================================================================
# part table
# =====================================================================================================================
# node -> list of (source names, material key, target triangles for the *sum* of the sources)
def table_player():
    return {
        "body": [
            (["body96"], "carpaint", 31000),
            (["Object_208", "Object_242"], "carpaint", 5600),
            (["Object_90"], "body_details", 2000),
            (["Object_93"], "body_black", 2500),
            (["Object_138"], "body_black", 700),
            (["Object_486", "Object_489"], "body_black", 500),
            (["Object_141"], "body_black", 700),
            (["Object_153"], "body_metal", 250),
            (["Object_78", "Object_147", "Object_150"], "headlight", 2700),
            (["Object_75", "Object_144", "Object_99"], "taillight", 1300),
        ],
        "glass": [
            (["Object_81"], "glass", 1000),
        ],
        "interior": [
            (["Object_345", "Object_348"], "interior_seat", 4500),
            (["Object_342"], "interior_seat", 600),
            (["Object_321"], "interior_carbon", 9000),
            (["Object_318"], "interior_carbon", 600),
            (["Object_229", "Object_239"], "interior_carbon", 3600),
            (["Object_217", "Object_251"], "interior_trim", 1000),
            (["Object_378"], "interior_trim", 2000),
            (["Object_339"], "interior_dash", 3000),
            (["Object_336"], "interior_trim", 2200),
            (["Object_273"], "interior_metal", 1800),
            (["Object_160"], "interior_belt", 1500),
            (["Object_157"], "interior_net", 800),
            (["Object_305"], "interior_pedals", 600),
            (["Object_296", "Object_293", "Object_290"], "interior_trim", 900),
            (["Object_354"], "interior_display", 8),
            (["Object_360"], "interior_display2", 10),
        ],
        "steer": [
            (["Object_287"], "interior_steer", 5500),
            (["Object_284"], "interior_steer_plastic", 2400),
            (["Object_280"], "interior_steer_carbon", 3200),
            (["Object_277"], "interior_steer_decal", 500),
        ],
    }


def find_by_material(src, matname, pred):
    return [q["name"] for q in src.parts.values() if q["matname"] == matname and pred(q["pos"].mean(0))]


# =====================================================================================================================
# materials
# =====================================================================================================================
class MatFactory(object):
    def __init__(self, src, tex_scale=1.0, livery=2048):
        self.src = src
        self.cache = ImageCache()
        self.mats = {}
        self.livery = livery
        self.ts = tex_scale

    def img(self, idx, size, **kw):
        return self.cache.get(("src", idx), self.src.g.pil_image(idx), int(size * self.ts), name="tex%d" % idx, **kw)

    def get(self, key):
        if key in self.mats:
            return self.mats[key]
        m = self._make(key)
        self.mats[key] = m
        return m

    def _make(self, k):
        M_ = W.Material
        if k == "carpaint":
            return M_("carpaint", (1, 1, 1, 1), 0.35, 0.28, base_image=self.cache.get(("src", 12), self.src.g.pil_image(12), self.livery, quality=84,
                                                                                        name="livery", force_rgb=True))
        if k == "glass":
            return M_("glass", (0.03, 0.045, 0.06, 0.32), 0.0, 0.06, alpha_mode="BLEND", double_sided=True)
        if k == "glass_dark":
            return M_("glass", (0.02, 0.025, 0.03, 1.0), 0.3, 0.08)
        if k == "tyre":
            return M_("tyre", (1, 1, 1, 1), 0.0, 0.92, base_image=self.img(2, 512, quality=85))
        if k == "tyre_plain":
            return M_("tyre", (0.035, 0.035, 0.035, 1), 0.0, 0.9)
        if k == "rim":
            return M_("rim", (0.11, 0.11, 0.12, 1), 0.85, 0.32)
        if k == "disc":
            return M_("disc", (1, 1, 1, 1), 0.7, 0.5, base_image=self.img(17, 512, quality=85))
        if k == "caliper":
            return M_("caliper", (0.85, 0.02, 0.02, 1), 0.15, 0.35)
        if k == "body_details":
            return M_("body_details", (1, 1, 1, 1), 0.2, 0.6, base_image=self.img(9, 512, quality=85))
        if k == "body_black":
            return M_("body_black", (0.025, 0.025, 0.028, 1), 0.2, 0.6)
        if k == "body_metal":
            return M_("body_metal", (0.55, 0.55, 0.57, 1), 0.8, 0.3)
        if k == "body_mirror":
            return M_("body_mirror", (1, 1, 1, 1), 0.9, 0.05, base_image=self.img(22, 128))
        if k == "headlight":
            return M_("headlight", (1, 1, 1, 1), 0.2, 0.25, base_image=self.img(4, 512, quality=86))
        if k == "taillight":
            return M_("taillight", (1, 1, 1, 1), 0.1, 0.3, base_image=self.img(4, 512, quality=86))
        if k == "interior_seat":
            return M_("interior_seat", (0.045, 0.045, 0.05, 1), 0.0, 0.92)
        if k == "interior_carbon":
            return M_("interior_carbon", (0.05, 0.05, 0.055, 1), 0.3, 0.45)
        if k == "interior_trim":
            return M_("interior_trim", (0.07, 0.07, 0.075, 1), 0.0, 0.65)
        if k == "interior_dash":
            return M_("interior_dash", (0.06, 0.06, 0.065, 1), 0.0, 0.7)
        if k == "interior_metal":
            return M_("interior_metal", (0.42, 0.42, 0.44, 1), 0.85, 0.4)
        if k == "interior_belt":
            return M_("interior_belt", (1, 1, 1, 1), 0.0, 0.85, base_image=self.img(16, 256))
        if k == "interior_net":
            return M_("interior_net", (1, 1, 1, 1), 0.0, 0.9, base_image=self.img(14, 256))
        if k == "interior_pedals":
            return M_("interior_pedals", (1, 1, 1, 1), 0.6, 0.5, base_image=self.img(28, 256))
        if k == "interior_display":
            im = self.img(31, 512)
            return M_("interior_display", (1, 1, 1, 1), 0.0, 0.3, emissive=(1, 1, 1), base_image=im, emissive_image=im)
        if k == "interior_display2":
            im = self.img(32, 256)
            return M_("interior_display2", (1, 1, 1, 1), 0.0, 0.3, emissive=(1, 1, 1), base_image=im, emissive_image=im)
        if k == "interior_steer":
            return M_("interior_steer", (1, 1, 1, 1), 0.0, 0.7, base_image=self.img(23, 256))
        if k == "interior_steer_plastic":
            return M_("interior_steer_plastic", (0.05, 0.05, 0.055, 1), 0.0, 0.5)
        if k == "interior_steer_carbon":
            return M_("interior_steer_carbon", (0.04, 0.04, 0.045, 1), 0.3, 0.4)
        if k == "interior_steer_decal":
            return M_("interior_steer_decal", (1, 1, 1, 1), 0.0, 0.6, base_image=self.img(20, 512, quality=85))
        raise KeyError(k)


TEXTURED = {"carpaint", "tyre", "disc", "body_details", "body_mirror", "headlight", "taillight", "interior_belt", "interior_net",
            "interior_pedals", "interior_display", "interior_display2", "interior_steer", "interior_steer_decal"}


# =====================================================================================================================
# building
# =====================================================================================================================
def gather_parts(src, spec, jobs, prefix=""):
    """queue decimation jobs for a node spec; returns entries [(matkey, [jobnames])]"""
    entries = []
    for i, (names, mat, target) in enumerate(spec):
        total = sum(len(src.parts[n]["idx"]) for n in names)
        ratio = min(1.0, float(target) / max(total, 1))
        jn = []
        for n in names:
            q = src.parts[n]
            jname = "%s%s" % (prefix, n.replace("Object_", "o"))
            jobs[jname] = {"pos": q["pos"], "idx": q["idx"], "uv": q["uv"] if mat in TEXTURED else None, "ratio": ratio}
            jn.append(jname)
        entries.append((mat, jn))
    return entries


def make_prims(entries, result, mf, crease=40.0):
    """merge per material and compute normals -> Prim list"""
    by_mat = {}
    order = []
    for mat, jn in entries:
        if mat not in by_mat:
            by_mat[mat] = []
            order.append(mat)
        for j in jn:
            r = result[j]
            by_mat[mat].append(r)
    prims = []
    for mat in order:
        meshes = by_mat[mat]
        textured = mat in TEXTURED
        merged = M.merge([{"pos": r["pos"], "idx": r["idx"], "uv": r["uv"] if textured else None} for r in meshes]
                         ) if not textured else M.merge([{"pos": r["pos"], "idx": r["idx"], "uv": r["uv"]} for r in meshes])
        pos, idx = merged["pos"], merged["idx"]
        idx = M.remove_degenerate(pos, idx)
        uv = merged.get("uv") if textured else None
        pos, idx, uv = M.compact(pos, idx, uv)
        angle = 55.0 if mat in ("tyre", "rim", "disc") else crease
        p2, n2, uv2, idx2 = M.smooth_normals(pos, idx, uv, angle)
        prims.append(W.Prim(p2, idx2, nrm=n2, uv=uv2, material=mf.get(mat if mat != "glass" else "glass")))
    return prims


def build_player(quick=False):
    ensure_dirs()
    src = Src()
    print("source loaded; y0=%.4f zmid=%.4f" % (src.y0, src.zmid))
    mf = MatFactory(src, livery=2048)
    table = table_player()
    jobs = {}
    node_entries = {}
    for node, spec in table.items():
        node_entries[node] = gather_parts(src, spec, jobs)
    # mirrors (small): keep as-is
    mir = find_by_material(src, "MIRROR", lambda c: True)
    node_entries.setdefault("body", [])
    body_mirrors = [n for n in mir if abs(src.parts[n]["pos"].mean(0)[0]) > 0.5]
    int_mirrors = [n for n in mir if abs(src.parts[n]["pos"].mean(0)[0]) <= 0.5]
    node_entries["body"] += gather_parts(src, [(body_mirrors, "body_mirror", 400)], jobs)
    node_entries["interior"] += gather_parts(src, [(int_mirrors, "body_mirror", 100)], jobs)
    # front aux lights + small rear lights
    aux = find_by_material(src, "AUX_LIGHT_Porsche992", lambda c: abs(abs(c[0]) - 0.74) < 0.05 and abs(c[1] - 0.646) < 0.05)
    node_entries["body"] += gather_parts(src, [(aux, "headlight", 400)], jobs)
    rear_small = [q["name"] for q in src.parts.values() if q["matname"].startswith("EXT_Emissive_Light_Rear_0") and len(q["idx"]) < 100]
    node_entries["body"] += gather_parts(src, [(rear_small, "taillight", 400)], jobs)
    door_glass = [q["name"] for q in src.parts.values() if q["matname"] == "EXT_Windows_0"]
    node_entries["glass"] += gather_parts(src, [(door_glass, "glass", 200)], jobs)
    # wing (2 variants from the same source)
    node_entries["wing"] = gather_parts(src, [(["wing96"], "carpaint", 3000)], jobs)
    # wheels
    wp = src.wheel_parts()
    wheel_entries = {}
    for corner, d in wp.items():
        wheel_entries[corner] = {
            "wheel": gather_parts(src, [([d["rim"]], "rim", 3400), ([d["tyre"]], "tyre", 1800), ([d["disc"]], "disc", 700)], jobs, prefix=corner + "_"),
            "brake": gather_parts(src, [([d["caliper"]], "caliper", 500)], jobs, prefix=corner + "_"),
        }
    print("decimation jobs:", len(jobs), "input tris:", sum(len(j["idx"]) for j in jobs.values()))
    result = decimate_cached(jobs, SCRATCH)
    print("decimated tris:", sum(len(r["idx"]) for r in result.values()))

    # ---- wheel pivots from the tyres
    pivots = {}
    radii = {}
    for corner, d in wp.items():
        q = src.parts[d["tyre"]]
        lo, hi = q["pos"].min(0), q["pos"].max(0)
        pivots[corner] = (lo + hi) / 2.0
        radii[corner] = float((hi[1] - lo[1]) / 2.0)
        pivots[corner][1] = radii[corner]                      # tyre sits exactly on y = 0
    # ---- meshes
    car = W.Node("car")
    body_prims = make_prims(node_entries["body"], result, mf)
    car.add(W.Node("body", mesh=W.Mesh("body", body_prims)))

    wing_r = result["wing96".replace("Object_", "o")] if False else result["wing96"]
    wing_e = node_entries["wing"]
    wing_prims = make_prims(wing_e, result, mf)
    car.add(W.Node("wing_gt3", mesh=W.Mesh("wing_gt3", wing_prims)))
    # bigger wing: scale about the trailing mount
    origin = np.array([0.0, 0.95, -1.95])
    sc = np.array([1.08, 1.32, 1.35])
    big_prims = []
    for p in wing_prims:
        pp = (p.pos - origin) * sc + origin + np.array([0.0, 0.0, -0.10])
        nn = p.nrm / sc
        nn = nn / np.maximum(np.linalg.norm(nn, axis=1, keepdims=True), 1e-9)
        big_prims.append(W.Prim(pp, p.idx, nrm=nn, uv=p.uv, material=p.material))
    car.add(W.Node("wing_big", mesh=W.Mesh("wing_big", big_prims), extras={"defaultHidden": True}))

    car.add(W.Node("glass", mesh=W.Mesh("glass", make_prims(node_entries["glass"], result, mf))))
    car.add(W.Node("interior", mesh=W.Mesh("interior", make_prims(node_entries["interior"], result, mf))))

    # ---- steering wheel
    steer = steering_frame(src)
    R0 = steer["R"]                # columns: local X, Y, Z in car space
    hub = steer["hub"]
    st_prims_world = make_prims(node_entries["steer"], result, mf)
    st_prims = []
    for p in st_prims_world:
        loc = (p.pos.astype(np.float64) - hub).dot(R0)              # world->local (R0 orthonormal)
        nl = p.nrm.astype(np.float64).dot(R0)
        st_prims.append(W.Prim(loc, p.idx, nrm=nl, uv=p.uv, material=p.material))
    mount = W.Node("steering_mount", translation=hub, rotation=quat_from_matrix(R0))
    mount.add(W.Node("steering_wheel", mesh=W.Mesh("steering_wheel", st_prims)))
    car.add(mount)

    # ---- wheels / brakes
    for corner in ("FL", "FR", "RL", "RR"):
        pv = pivots[corner]
        wpr = make_prims(wheel_entries[corner]["wheel"], result, mf)
        bpr = make_prims(wheel_entries[corner]["brake"], result, mf)
        for p in wpr + bpr:
            p.pos = (p.pos.astype(np.float64) - pv).astype(np.float32)
        wn = W.Node("wheel_" + corner, mesh=W.Mesh("wheel_" + corner, wpr))
        bn = W.Node("brake_" + corner, mesh=W.Mesh("brake_" + corner, bpr))
        if corner[0] == "F":
            sn = W.Node("steer_" + corner, translation=pv, children=[wn, bn])
            car.add(sn)
        else:
            wn.translation = pv
            bn.translation = pv
            car.add(wn)
            car.add(bn)
    info = W.write_glb(os.path.join(MODELS, "car_player.glb"), [car], scene_name="car_player",
                       asset_extras={"source": "2024 Porsche 992 GT3 R by Dave Love (Tyler_Dave), CC-BY-4.0"})
    print("car_player.glb", info)
    meta = contract_meta(compute_meta(src, pivots, radii, steer, result))
    json.dump(meta, open(os.path.join(DATA, "car_meta.json"), "w"), indent=1)
    return info


def steering_frame(src):
    """steering wheel local frame: Z = column axis toward the driver, Y ~ up, X = Y x Z (car right when the wheel is upright)."""
    P = np.concatenate([src.parts[n]["pos"] for n in ("Object_280", "Object_284")])
    c = P.mean(0)
    u, s, vt = np.linalg.svd(P - c, full_matrices=False)
    n = vt[2]                                     # smallest variance direction = wheel plane normal
    if n[2] > 0:
        n = -n                                    # toward the driver (rear)
    z = n / np.linalg.norm(n)
    up = np.array([0.0, 1.0, 0.0])
    y = up - z * z.dot(up)
    y /= np.linalg.norm(y)
    x = np.cross(y, z)
    R = np.stack([x, y, z], axis=1)
    loc = (P - c).dot(R)
    lo, hi = loc.min(0), loc.max(0)
    centre_local = (lo + hi) / 2.0
    hub = c + R.dot(centre_local)
    half_w = (hi[0] - lo[0]) / 2.0
    half_h = (hi[1] - lo[1]) / 2.0
    return {"R": R, "hub": hub, "half_w": float(half_w), "half_h": float(half_h), "axis": z, "sv": s}


def compute_meta(src, pivots, radii, steer, result):
    allp = np.concatenate([q["pos"] for n, q in src.parts.items() if n not in ("Object_141",)])
    body = src.parts["body96"]["pos"]
    lo, hi = body.min(0), body.max(0)
    ext_all = np.concatenate([src.parts["body96"]["pos"], src.parts["wing96"]["pos"]])
    lo, hi = ext_all.min(0), ext_all.max(0)
    fl, fr, rl, rr = pivots["FL"], pivots["FR"], pivots["RL"], pivots["RR"]
    axleF = float((fl[2] + fr[2]) / 2.0)
    axleR = float((rl[2] + rr[2]) / 2.0)
    # seat: pan + back
    seat = np.concatenate([src.parts["Object_345"]["pos"], src.parts["Object_348"]["pos"]])
    return {"_seat_bbox": [seat.min(0).tolist(), seat.max(0).tolist()], "length": float(hi[2] - lo[2]), "width": float(hi[0] - lo[0]),
            "height": float(hi[1] - lo[1]), "wheelbase": axleF - axleR, "frontAxleZ": axleF, "rearAxleZ": axleR,
            "steer_hub": steer["hub"].tolist(), "steer_axis": steer["axis"].tolist(), "steer_half": [steer["half_w"], steer["half_h"]],
            "pivots": {k: v.tolist() for k, v in pivots.items()}, "radii": radii}


def contract_meta(m):
    """keys the Swift side reads (docs/ARCHITECTURE.md car_meta): driver / wheel / door / pedal anchors in car space"""
    hub = m["steer_hub"]
    axis = m["steer_axis"]
    m2 = dict(m)
    m2.update({
        "trackFront": 2 * abs(m["pivots"]["FL"][0]), "trackRear": 2 * abs(m["pivots"]["RL"][0]),
        "wheelRadiusFront": m["radii"]["FL"], "wheelRadiusRear": m["radii"]["RL"], "cgZ": -0.126,
        "driverHip": [0.31, 0.28, -0.20], "driverEye": [0.31, 0.95, -0.10],
        "steeringHub": hub, "steeringAxis": axis, "steeringRadius": max(m["steer_half"]),
        # wheel node local space at angle 0; the mount is turned ~180 deg about Y, so the avatar's LEFT hand (car +X) is at local -X
        "gripLeft": [-0.139, 0.02, 0.02], "gripRight": [0.139, 0.02, 0.02],
        "doorDriver": [1.02, 0.62, 0.1], "pedalThrottle": [0.23, 0.28, 0.66], "pedalBrake": [0.34, 0.28, 0.66],
        "exhausts": [[0.42, 0.42, -2.28], [-0.42, 0.42, -2.28]], "headlights": [[0.66, 0.64, 2.2]], "taillights": [[0.6, 0.78, -2.3]],
        "wingNodes": ["wing_gt3", "wing_big"]})
    return m2


if __name__ == "__main__":
    build_player()
