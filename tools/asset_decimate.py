# -*- coding: utf-8 -*-
"""Mesh decimation through the Blender 2.79 MCP bridge (Decimate/collapse modifier).

    from asset_decimate import decimate
    out = decimate({"body": {"pos": P, "idx": I, "uv": UV, "ratio": 0.4}, ...}, workdir)
    out["body"] -> {"pos", "uv", "idx"}      (vertices split at uv seams, no normals -> use asset_mesh.smooth_normals)

Workflow: python -> OBJ (positions welded, per-corner uv) -> Blender import, one Decimate modifier per object,
OBJ export with modifiers applied -> python.  A private temporary scene is used and removed afterwards so the user's own
Blender scene is untouched.
"""
import json
import os
import subprocess
import sys

import numpy as np

MCP_CLI = r"C:\blender-claude\scripts\mcp_cli.py"

BLENDER_SCRIPT = r'''
import bpy, json, os
W = %(work)r
jobs = json.load(open(os.path.join(W, "jobs.json")))
old = bpy.context.screen.scene
sc = bpy.data.scenes.new("aw_tmp")
bpy.context.screen.scene = sc
try:
    bpy.ops.import_scene.obj(filepath=os.path.join(W, "in.obj"), axis_forward='-Z', axis_up='Y', use_split_objects=True,
                             use_split_groups=False, use_image_search=False, use_smooth_groups=False, use_edges=False)
    n = 0
    for ob in list(sc.objects):
        if ob.type != 'MESH':
            continue
        j = jobs.get(ob.name)
        if j is None:
            continue
        before = len(ob.data.polygons)
        r = float(j["ratio"])
        if r < 0.999:
            m = ob.modifiers.new("aw_dec", 'DECIMATE')
            m.decimate_type = 'COLLAPSE'
            m.ratio = r
            m.use_collapse_triangulate = True
        n += 1
    bpy.ops.export_scene.obj(filepath=os.path.join(W, "out.obj"), check_existing=False, axis_forward='-Z', axis_up='Y',
                             use_selection=False, use_animation=False, use_mesh_modifiers=True, use_edges=False,
                             use_smooth_groups=False, use_smooth_groups_bitflags=False, use_normals=False, use_uvs=True,
                             use_materials=False, use_triangles=True, use_nurbs=False, use_vertex_groups=False,
                             use_blen_objects=True, group_by_object=False, group_by_material=False, keep_vertex_order=False,
                             global_scale=1.0)
    print("aw_decimate processed", n, "objects")
finally:
    for ob in list(sc.objects):
        me = ob.data
        sc.objects.unlink(ob)
        bpy.data.objects.remove(ob)
        if me is not None and me.users == 0:
            bpy.data.meshes.remove(me)
    bpy.context.screen.scene = old
    bpy.data.scenes.remove(sc)
'''


def _write_obj(path, jobs, names):
    from asset_mesh import weld_by_position
    with open(path, "w") as f:
        voff = 1
        tof = 1
        for nm in names:
            j = jobs[nm]
            pos = np.asarray(j["pos"], dtype=np.float64)
            idx = np.asarray(j["idx"]).reshape(-1, 3)
            first, inv = weld_by_position(pos, 1e-5)
            wp = pos[first]
            wi = inv[idx]
            uv = j.get("uv")
            f.write("o %s\n" % nm)
            np.savetxt(f, wp, fmt="v %.6f %.6f %.6f")
            if uv is not None:
                uvq = np.round(np.asarray(uv, dtype=np.float64) * 1e5).astype(np.int64)
                uu, uinv = np.unique(uvq, axis=0, return_inverse=True)
                uinv = uinv.reshape(-1)
                np.savetxt(f, uu / 1e5, fmt="vt %.5f %.5f")
                ci = uinv[idx]
                a = wi + voff
                t = ci + tof
                lines = ["f %d/%d %d/%d %d/%d\n" % (a[k, 0], t[k, 0], a[k, 1], t[k, 1], a[k, 2], t[k, 2]) for k in range(len(a))]
                tof += len(uu)
            else:
                a = wi + voff
                lines = ["f %d %d %d\n" % (a[k, 0], a[k, 1], a[k, 2]) for k in range(len(a))]
            f.writelines(lines)
            voff += len(wp)


def _read_obj(path):
    out = {}
    cur = None
    v, vt = [], []
    faces = {}
    order = []
    with open(path, "r") as f:
        for line in f:
            if line.startswith("o "):
                cur = line[2:].strip()
                order.append(cur)
                faces[cur] = []
            elif line.startswith("v "):
                s = line.split()
                v.append((float(s[1]), float(s[2]), float(s[3])))
            elif line.startswith("vt "):
                s = line.split()
                vt.append((float(s[1]), float(s[2])))
            elif line.startswith("f "):
                s = line.split()[1:]
                tri = []
                for c in s:
                    p = c.split("/")
                    tri.append((int(p[0]) - 1, int(p[1]) - 1 if len(p) > 1 and p[1] else -1))
                for k in range(1, len(tri) - 1):
                    faces[cur].append((tri[0], tri[k], tri[k + 1]))
    V = np.array(v, dtype=np.float64).reshape(-1, 3)
    T = np.array(vt, dtype=np.float64).reshape(-1, 2)
    for nm in order:
        fc = np.array(faces[nm], dtype=np.int64).reshape(-1, 3, 2)
        if len(fc) == 0:
            out[nm] = None
            continue
        key = fc.reshape(-1, 2)
        has_uv = bool((key[:, 1] >= 0).all())
        if has_uv:
            uk, inv = np.unique(key, axis=0, return_inverse=True)
            inv = inv.reshape(-1)
            pos = V[uk[:, 0]]
            uv = T[uk[:, 1]]
        else:
            uk, inv = np.unique(key[:, 0], return_inverse=True)
            inv = inv.reshape(-1)
            pos = V[uk]
            uv = None
        idx = inv.reshape(-1, 3)
        out[nm] = {"pos": pos.astype(np.float32), "uv": None if uv is None else uv.astype(np.float32), "idx": idx}
    return out


def decimate(jobs, workdir, timeout=900, keep_files=False):
    """jobs: {name: dict(pos, idx, uv|None, ratio)}; names must be short ascii. Returns {name: dict(pos, uv, idx)}."""
    os.makedirs(workdir, exist_ok=True)
    names = sorted(jobs.keys())
    _write_obj(os.path.join(workdir, "in.obj"), jobs, names)
    json.dump({nm: {"ratio": float(jobs[nm]["ratio"])} for nm in names}, open(os.path.join(workdir, "jobs.json"), "w"))
    script = os.path.join(workdir, "run.py")
    with open(script, "w") as f:
        f.write(BLENDER_SCRIPT % {"work": workdir})
    for fn in ("out.obj",):
        p = os.path.join(workdir, fn)
        if os.path.exists(p):
            os.remove(p)
    r = subprocess.run([sys.executable, MCP_CLI, "exec", script, str(timeout)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       universal_newlines=True)
    txt = r.stdout
    if r.returncode != 0 or not os.path.exists(os.path.join(workdir, "out.obj")):
        raise RuntimeError("Blender decimate failed:\n" + txt[-3000:])
    res = _read_obj(os.path.join(workdir, "out.obj"))
    if not keep_files:
        for fn in ("in.obj", "out.obj", "jobs.json", "run.py"):
            try:
                os.remove(os.path.join(workdir, fn))
            except OSError:
                pass
    return res


def decimate_cached(jobs, workdir, timeout=900):
    """Like decimate() but memoises every job on disk (key = hash of geometry + ratio)."""
    import hashlib
    import pickle
    cache_dir = os.path.join(workdir, "cache")
    os.makedirs(cache_dir, exist_ok=True)
    keys = {}
    result = {}
    todo = {}
    for nm, j in jobs.items():
        h = hashlib.md5()
        h.update(np.ascontiguousarray(np.asarray(j["pos"], dtype=np.float32)).tobytes())
        h.update(np.ascontiguousarray(np.asarray(j["idx"], dtype=np.int64)).tobytes())
        if j.get("uv") is not None:
            h.update(np.ascontiguousarray(np.asarray(j["uv"], dtype=np.float32)).tobytes())
        h.update(("%.5f" % float(j["ratio"])).encode())
        keys[nm] = h.hexdigest()
        fp = os.path.join(cache_dir, keys[nm] + ".pkl")
        if os.path.exists(fp):
            with open(fp, "rb") as f:
                result[nm] = pickle.load(f)
        elif float(j["ratio"]) >= 0.999:
            # no decimation: weld + uv-split through the same path anyway (keeps the pipeline uniform)
            todo[nm] = j
        else:
            todo[nm] = j
    if todo:
        # batch to keep every Blender job moderate
        names = sorted(todo.keys())
        batch, cnt = {}, 0
        chunks = []
        for nm in names:
            batch[nm] = todo[nm]
            cnt += len(todo[nm]["idx"])
            if cnt > 150000:
                chunks.append(batch)
                batch, cnt = {}, 0
        if batch:
            chunks.append(batch)
        for ch in chunks:
            out = decimate(ch, workdir, timeout)
            for nm in ch:
                r = out.get(nm)
                if r is None:
                    raise RuntimeError("decimate produced no mesh for %s" % nm)
                result[nm] = r
                with open(os.path.join(cache_dir, keys[nm] + ".pkl"), "wb") as f:
                    pickle.dump(r, f)
    return result
