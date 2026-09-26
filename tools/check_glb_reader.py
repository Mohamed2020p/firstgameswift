# -*- coding: utf-8 -*-
"""
Python mirror of Supercars/Assets/GLBLoader.swift data decoding.

  python tools/check_glb_reader.py [file.glb ...]        (default: assets_src/*.glb and Supercars/Resources/Models/*.glb)
  python tools/check_glb_reader.py --quiet               (only problems + one summary line per file)

The Swift loader (there is no Swift compiler on the authoring machine) implements EXACTLY the rules below, so running this on
the real input files validates the format assumptions the Swift code relies on:

  * GLB container:  12 byte header (magic 'glTF', version 2, total length), then chunks (uint32 length, uint32 type, payload);
                    JSON chunk 0x4E4F534A (space padded), BIN chunk 0x004E4942 (zero padded), 4-byte aligned.
  * accessor read:  base = bufferView.byteOffset + accessor.byteOffset ; element size = components * componentSize ;
                    stride = bufferView.byteStride (if present and != 0) else element size ; element i starts at base + i*stride ;
                    every element must fit inside the bufferView (and the buffer). Interleaved views therefore just work.
                    normalized integer accessors convert u8/u16 -> v/255, v/65535 ; i8/i16 -> max(v/127, -1), max(v/32767, -1).
                    an accessor without bufferView is all zeros. Sparse accessors are NOT supported (warned).
  * meshes:         triangles only (mode 4 / absent); TRIANGLE_STRIP(5) and TRIANGLE_FAN(6) are converted; points/lines skipped.
                    index types u8/u16/u32 -> u32 ; non-indexed primitives get sequential indices.
  * skins:          joints (node indices, in skin order) ; inverseBindMatrices MAT4 float32 column-major (count must == joints,
                    identity when absent) ; JOINTS_0 u8/u16 VEC4 ; WEIGHTS_0 float / normalized u8/u16 VEC4, renormalised.
  * images:         bufferView + mimeType (PNG/JPEG) or data: URI or external file (relative to the .glb).
  * materials:      pbrMetallicRoughness (baseColorFactor/Texture, metallicFactor, roughnessFactor, metallicRoughnessTexture: G = roughness,
                    B = metalness), normalTexture, occlusionTexture (R), emissiveFactor/Texture, alphaMode, alphaCutoff, doubleSided,
                    KHR_materials_emissive_strength. Everything else (KHR_materials_specular ...) is ignored.
Exit code 1 when a problem is found.
"""
import io
import json
import math
import os
import struct
import sys

import numpy as np

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    Image = None

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

COMP_DTYPE = {5120: np.int8, 5121: np.uint8, 5122: np.int16, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
COMP_SIZE = {5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4}
TYPE_COMPS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16}
UNSUPPORTED_REQUIRED = {"KHR_draco_mesh_compression", "EXT_meshopt_compression", "KHR_texture_basisu"}


class GLBError(Exception):
    pass


# --------------------------------------------------------------------------------------------- container

def parse_glb(path):
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 20:
        raise GLBError("file too small")
    magic, version, length = struct.unpack_from("<III", data, 0)
    if magic != 0x46546C67:
        raise GLBError("bad magic")
    if version != 2:
        raise GLBError("unsupported glTF version %d" % version)
    if length > len(data):
        raise GLBError("header length %d > file size %d" % (length, len(data)))
    off = 12
    js = None
    binc = None
    while off + 8 <= length:
        clen, ctype = struct.unpack_from("<II", data, off)
        body = data[off + 8: off + 8 + clen]
        if len(body) != clen:
            raise GLBError("truncated chunk")
        if ctype == 0x4E4F534A and js is None:
            js = json.loads(body.decode("utf-8").rstrip(" \t\r\n\x00"))
        elif ctype == 0x004E4942 and binc is None:
            binc = body
        off += 8 + clen
        off = (off + 3) & ~3  # chunks are 4-byte aligned (writers already pad, be lenient anyway)
    if js is None:
        raise GLBError("no JSON chunk")
    return js, binc


# --------------------------------------------------------------------------------------------- accessors

class Reader:
    def __init__(self, js, binc, base_dir):
        self.js = js
        self.bin = binc
        self.base_dir = base_dir
        self.buffers = {}
        self.warnings = []

    def buffer_bytes(self, idx):
        if idx in self.buffers:
            return self.buffers[idx]
        b = self.js["buffers"][idx]
        uri = b.get("uri")
        if uri is None:
            if idx != 0 or self.bin is None:
                raise GLBError("buffer %d has no uri and no BIN chunk" % idx)
            data = self.bin
        elif uri.startswith("data:"):
            import base64
            data = base64.b64decode(uri.split(",", 1)[1])
        else:
            with open(os.path.join(self.base_dir, uri), "rb") as f:
                data = f.read()
        if len(data) < b["byteLength"]:
            raise GLBError("buffer %d shorter (%d) than byteLength (%d)" % (idx, len(data), b["byteLength"]))
        self.buffers[idx] = data
        return data

    def view_bytes(self, bv_idx):
        bv = self.js["bufferViews"][bv_idx]
        buf = self.buffer_bytes(bv["buffer"])
        off = bv.get("byteOffset", 0)
        ln = bv["byteLength"]
        if off + ln > len(buf):
            raise GLBError("bufferView %d exceeds buffer" % bv_idx)
        return buf, off, ln, bv.get("byteStride", 0)

    def accessor(self, idx, as_float=None):
        """returns ndarray (count, comps). float32 for float/normalized accessors (or as_float=True), else integer dtype."""
        a = self.js["accessors"][idx]
        ct = a["componentType"]
        ncomp = TYPE_COMPS[a["type"]]
        count = a["count"]
        if "sparse" in a:
            self.warnings.append("accessor %d is sparse (unsupported, base data only)" % idx)
        dtype = COMP_DTYPE[ct]
        csize = COMP_SIZE[ct]
        if "bufferView" not in a:
            arr = np.zeros((count, ncomp), dtype=dtype)
        else:
            buf, bv_off, bv_len, bv_stride = self.view_bytes(a["bufferView"])
            elem = ncomp * csize
            stride = bv_stride if bv_stride else elem
            if stride < elem:
                raise GLBError("accessor %d stride %d < element size %d" % (idx, stride, elem))
            base = a.get("byteOffset", 0)
            if count > 0 and base + (count - 1) * stride + elem > bv_len:
                raise GLBError("accessor %d overruns bufferView %d (base %d count %d stride %d elem %d len %d)"
                               % (idx, a["bufferView"], base, count, stride, elem, bv_len))
            arr = np.ndarray(shape=(count, ncomp), dtype=np.dtype(dtype).newbyteorder("<"), buffer=buf,
                             offset=bv_off + base, strides=(stride, csize)).astype(dtype)
        normalized = a.get("normalized", False)
        if as_float is None:
            as_float = normalized or ct == 5126
        if as_float:
            if ct == 5126:
                return arr.astype(np.float32)
            f = arr.astype(np.float32)
            if normalized:
                if ct == 5121:
                    f = f / 255.0
                elif ct == 5123:
                    f = f / 65535.0
                elif ct == 5120:
                    f = np.maximum(f / 127.0, -1.0)
                elif ct == 5122:
                    f = np.maximum(f / 32767.0, -1.0)
            return f
        return arr


# --------------------------------------------------------------------------------------------- scene

def quat_to_mat(q):
    x, y, z, w = q
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def node_local(n):
    if "matrix" in n:
        return np.array(n["matrix"], dtype=np.float64).reshape(4, 4).T  # column-major
    m = np.eye(4)
    s = n.get("scale", [1, 1, 1])
    r = n.get("rotation", [0, 0, 0, 1])
    t = n.get("translation", [0, 0, 0])
    m[:3, :3] = quat_to_mat(r) * np.array(s)[None, :]
    m[:3, 3] = t
    return m


def triangles_from(mode, idx):
    if mode == 4:
        n = len(idx) // 3 * 3
        return idx[:n]
    if mode == 5:
        tris = []
        for i in range(len(idx) - 2):
            tris.extend((idx[i], idx[i + 1], idx[i + 2]) if i % 2 == 0 else (idx[i + 1], idx[i], idx[i + 2]))
        return np.array(tris, dtype=np.uint32)
    if mode == 6:
        tris = []
        for i in range(1, len(idx) - 1):
            tris.extend((idx[0], idx[i], idx[i + 1]))
        return np.array(tris, dtype=np.uint32)
    return None


class Report:
    def __init__(self, name, quiet):
        self.name = name
        self.quiet = quiet
        self.problems = []
        self.facts = []

    def problem(self, msg):
        self.problems.append(msg)

    def fact(self, msg):
        self.facts.append(msg)


def check_file(path, quiet=False):
    rep = Report(os.path.basename(path), quiet)
    js, binc = parse_glb(path)
    rd = Reader(js, binc, os.path.dirname(path))
    req = set(js.get("extensionsRequired", []))
    bad = req & UNSUPPORTED_REQUIRED
    if bad:
        rep.problem("requires unsupported extensions %s" % sorted(bad))
    rep.fact("extensionsUsed=%s required=%s" % (js.get("extensionsUsed"), sorted(req)))
    nodes = js.get("nodes", [])
    meshes = js.get("meshes", [])
    accessors = js.get("accessors", [])
    materials = js.get("materials", [])
    skins = js.get("skins", [])

    # ---- hierarchy (must be a forest) ----
    parent = {}
    for i, n in enumerate(nodes):
        for c in n.get("children", []):
            if c in parent:
                rep.problem("node %d has two parents" % c)
            parent[c] = i
    scene_idx = js.get("scene", 0)
    scenes = js.get("scenes", [])
    if not scenes:
        rep.problem("no scenes")
        return rep
    roots = scenes[scene_idx].get("nodes", [])
    world = {}
    visited = set()

    def walk(i, pw):
        if i in visited:
            rep.problem("node %d visited twice (cycle/DAG)" % i)
            return
        visited.add(i)
        w = pw @ node_local(nodes[i])
        world[i] = w
        for c in nodes[i].get("children", []):
            walk(c, w)

    for r in roots:
        walk(r, np.eye(4))
    rep.fact("scene roots=%d nodes reachable=%d/%d" % (len(roots), len(visited), len(nodes)))

    # ---- images ----
    img_info = {}
    for i, im in enumerate(js.get("images", [])):
        try:
            if "bufferView" in im:
                buf, off, ln, _ = rd.view_bytes(im["bufferView"])
                raw = bytes(buf[off:off + ln])
            elif im.get("uri", "").startswith("data:"):
                import base64
                raw = base64.b64decode(im["uri"].split(",", 1)[1])
            elif "uri" in im:
                with open(os.path.join(os.path.dirname(path), im["uri"]), "rb") as f:
                    raw = f.read()
            else:
                raise GLBError("image has neither bufferView nor uri")
            sig_png = raw[:8] == b"\x89PNG\r\n\x1a\n"
            sig_jpg = raw[:3] == b"\xff\xd8\xff"
            if not (sig_png or sig_jpg):
                rep.problem("image %d is neither PNG nor JPEG (mime %s)" % (i, im.get("mimeType")))
            if Image is not None:
                pil = Image.open(io.BytesIO(raw))
                pil.load()
                img_info[i] = (pil.width, pil.height, pil.mode)
            else:
                img_info[i] = None
        except Exception as e:  # noqa
            rep.problem("image %d undecodable: %s" % (i, e))
    if img_info:
        sizes = sorted(set((v[0], v[1]) for v in img_info.values() if v))
        modes = sorted(set(v[2] for v in img_info.values() if v))
        rep.fact("images=%d sizes(max)=%s modes=%s" % (len(img_info), sizes[-3:], modes))

    # ---- materials ----
    tex_used_as = {}
    for mi, m in enumerate(materials):
        pbr = m.get("pbrMetallicRoughness", {})
        alpha = m.get("alphaMode", "OPAQUE")
        if alpha not in ("OPAQUE", "MASK", "BLEND"):
            rep.problem("material %d bad alphaMode %s" % (mi, alpha))
        for key, sub in (("baseColorTexture", pbr), ("metallicRoughnessTexture", pbr), ("normalTexture", m),
                         ("occlusionTexture", m), ("emissiveTexture", m)):
            t = sub.get(key)
            if not t:
                continue
            tex = js["textures"][t["index"]]
            src = tex.get("source")
            if src is None:
                rep.problem("material %d %s: texture without source (extension image?)" % (mi, key))
                continue
            if src >= len(js.get("images", [])):
                rep.problem("material %d %s: image %d out of range" % (mi, key, src))
            if t.get("texCoord", 0) > 1:
                rep.problem("material %d %s uses texCoord %d (>1 unsupported, falls back to 0)" % (mi, key, t["texCoord"]))
            if "KHR_texture_transform" in t.get("extensions", {}):
                rep.fact("KHR_texture_transform present (ignored) in material %d" % mi)
            tex_used_as.setdefault(src, set()).add(key)
    shared = [k for k, v in tex_used_as.items() if len(v) > 1]
    if shared:
        rep.fact("images used in several roles (decoded once, derived per role): %s" % shared)

    # ---- meshes ----
    total_tris = 0
    total_verts = 0
    mn = np.array([1e30] * 3)
    mx = np.array([-1e30] * 3)
    mesh_stats = {}
    n_interleaved = 0
    for mi, mesh in enumerate(meshes):
        mesh_tris = 0
        mesh_verts = 0
        prim_attr_sets = []
        for pi, prim in enumerate(mesh["primitives"]):
            attrs = prim["attributes"]
            prim_attr_sets.append(tuple(sorted(attrs)))
            mode = prim.get("mode", 4)
            if "POSITION" not in attrs:
                rep.problem("mesh %d prim %d has no POSITION" % (mi, pi))
                continue
            for k, ai in attrs.items():
                a = accessors[ai]
                bvi = a.get("bufferView")
                if bvi is not None and js["bufferViews"][bvi].get("byteStride", 0) not in (0, TYPE_COMPS[a["type"]] * COMP_SIZE[a["componentType"]]):
                    n_interleaved += 1
            pos = rd.accessor(attrs["POSITION"])
            vcount = pos.shape[0]
            if pos.shape[1] != 3:
                rep.problem("mesh %d POSITION not VEC3" % mi)
            if not np.isfinite(pos).all():
                rep.problem("mesh %d has non-finite positions" % mi)
            # index buffer
            if "indices" in prim:
                idx = rd.accessor(prim["indices"], as_float=False).reshape(-1).astype(np.uint32)
            else:
                idx = np.arange(vcount, dtype=np.uint32)
            tri = triangles_from(mode, idx)
            if tri is None:
                rep.fact("mesh %d prim %d mode %d skipped (points/lines)" % (mi, pi, mode))
                continue
            if len(tri) and int(tri.max()) >= vcount:
                rep.problem("mesh %d prim %d index %d >= vertex count %d" % (mi, pi, int(tri.max()), vcount))
            mesh_tris += len(tri) // 3
            mesh_verts += vcount
            # normals
            if "NORMAL" in attrs:
                nrm = rd.accessor(attrs["NORMAL"])
                if nrm.shape[0] != vcount:
                    rep.problem("mesh %d NORMAL count %d != %d" % (mi, nrm.shape[0], vcount))
                ln = np.linalg.norm(nrm, axis=1)
                bad_frac = float(np.mean(np.abs(ln - 1) > 0.05)) if len(ln) else 0
                if bad_frac > 0.01:
                    rep.fact("mesh %d prim %d: %.1f%% normals not unit length (Swift renormalises)" % (mi, pi, bad_frac * 100))
            else:
                rep.fact("mesh %d prim %d has no NORMAL -> Swift generates smooth normals" % (mi, pi))
            if "TEXCOORD_0" in attrs:
                uv = rd.accessor(attrs["TEXCOORD_0"])
                if uv.shape[0] != vcount:
                    rep.problem("mesh %d UV count mismatch" % mi)
            if "TANGENT" in attrs:
                tg = rd.accessor(attrs["TANGENT"])
                if tg.shape[1] != 4 or tg.shape[0] != vcount:
                    rep.problem("mesh %d TANGENT shape %s" % (mi, tg.shape))
                elif not np.all(np.abs(np.abs(tg[:, 3]) - 1) < 1e-3):
                    rep.fact("mesh %d TANGENT.w not +-1" % mi)
            if "COLOR_0" in attrs:
                col = rd.accessor(attrs["COLOR_0"])
                if col.shape[0] != vcount:
                    rep.problem("mesh %d COLOR_0 count mismatch" % mi)
            # world bounds through every node instancing this mesh
            for ni, n in enumerate(nodes):
                if n.get("mesh") == mi and ni in world:
                    if "skin" in n:
                        continue  # skinned: bounds depend on the pose; checked via the skin block below
                    wm = world[ni]
                    wp = pos @ wm[:3, :3].T + wm[:3, 3]
                    mn = np.minimum(mn, wp.min(axis=0))
                    mx = np.maximum(mx, wp.max(axis=0))
            if "targets" in prim:
                rep.fact("mesh %d has morph targets (ignored)" % mi)
            # material reference
            if "material" in prim and prim["material"] >= len(materials):
                rep.problem("mesh %d references material %d out of range" % (mi, prim["material"]))
            # skin attributes
            if "JOINTS_0" in attrs or "WEIGHTS_0" in attrs:
                if "JOINTS_0" not in attrs or "WEIGHTS_0" not in attrs:
                    rep.problem("mesh %d has only one of JOINTS_0/WEIGHTS_0" % mi)
                else:
                    ja = accessors[attrs["JOINTS_0"]]
                    if ja["componentType"] not in (5121, 5123):
                        rep.problem("mesh %d JOINTS_0 component type %d" % (mi, ja["componentType"]))
                    jt = rd.accessor(attrs["JOINTS_0"], as_float=False)
                    wt = rd.accessor(attrs["WEIGHTS_0"])
                    if jt.shape != wt.shape or jt.shape[0] != vcount:
                        rep.problem("mesh %d joints/weights shapes %s %s" % (mi, jt.shape, wt.shape))
                    if "JOINTS_1" in attrs:
                        rep.fact("mesh %d has JOINTS_1 (only first 4 influences used)" % mi)
                    # which nodes use this mesh with which skin
                    for ni, n in enumerate(nodes):
                        if n.get("mesh") == mi:
                            if "skin" not in n:
                                rep.problem("mesh %d has joints but node %d has no skin" % (mi, ni))
                            else:
                                nj = len(skins[n["skin"]]["joints"])
                                if int(jt.max()) >= nj:
                                    rep.problem("mesh %d joint index %d >= joint count %d" % (mi, int(jt.max()), nj))
                    sums = wt.sum(axis=1)
                    if not np.all(np.isfinite(sums)):
                        rep.problem("mesh %d non-finite weights" % mi)
                    zero_w = int(np.sum(sums < 1e-6))
                    if zero_w:
                        rep.problem("mesh %d has %d vertices with zero total weight" % (mi, zero_w))
                    off_norm = float(np.mean(np.abs(sums - 1) > 0.01))
                    if off_norm > 0:
                        rep.fact("mesh %d: %.2f%% of vertices have weight sum != 1 (Swift renormalises)" % (mi, off_norm * 100))
                    # weight/joint consistency: zero weight slots should not carry out-of-range joints
        if len(set(prim_attr_sets)) > 1:
            rep.fact("mesh %d: primitives have different attribute sets %s (Swift pads missing attributes)" % (mi, sorted(set(prim_attr_sets))))
        mesh_stats[mi] = (mesh_tris, mesh_verts)
        total_tris += mesh_tris
        total_verts += mesh_verts
    if n_interleaved:
        rep.fact("interleaved (byteStride != element size) attribute accessors: %d" % n_interleaved)

    # ---- skins ----
    for si, s in enumerate(skins):
        joints = s["joints"]
        for j in joints:
            if j >= len(nodes):
                rep.problem("skin %d joint node %d out of range" % (si, j))
            elif j not in visited:
                rep.problem("skin %d joint node %d is not in the scene" % (si, j))
        if len(set(joints)) != len(joints):
            rep.problem("skin %d has duplicate joints" % si)
        if "inverseBindMatrices" in s:
            ia = accessors[s["inverseBindMatrices"]]
            if ia["type"] != "MAT4" or ia["componentType"] != 5126:
                rep.problem("skin %d IBM accessor is %s/%d (expected MAT4 float)" % (si, ia["type"], ia["componentType"]))
            ibm = rd.accessor(s["inverseBindMatrices"])
            if ibm.shape[0] != len(joints):
                rep.problem("skin %d: IBM count %d != joints %d" % (si, ibm.shape[0], len(joints)))
            # bind pose consistency: inverse(IBM_i) should equal the joint's world transform in the bind pose (up to the skinned mesh's frame)
            mats = ibm.reshape(-1, 4, 4).transpose(0, 2, 1)  # column-major -> row-major math
            if not np.isfinite(mats).all():
                rep.problem("skin %d has non-finite IBM" % si)
            det = np.linalg.det(mats[:, :3, :3])
            if np.any(np.abs(det) < 1e-12):
                rep.problem("skin %d has singular IBM" % si)
            errs = []
            for k, j in enumerate(joints):
                if j in world:
                    errs.append(float(np.abs(np.linalg.inv(mats[k]) - world[j]).max()))
            if errs:
                rep.fact("skin %d: joints=%d skeleton=%s; max|inv(IBM)-jointWorld|=%.4g (0 means the skin is in world/bind space already)"
                         % (si, len(joints), s.get("skeleton"), max(errs)))
        else:
            rep.fact("skin %d has no inverseBindMatrices (identity)" % si)
        # skeleton / mesh node world frames (the Swift loader re-parents skinned mesh nodes when these differ)
        sk = s.get("skeleton")
        for ni, n in enumerate(nodes):
            if n.get("skin") == si and ni in world:
                if sk is not None and sk in world:
                    d = float(np.abs(world[ni] - world[sk]).max())
                    if d > 1e-4:
                        rep.fact("skin %d: mesh node %d world != skeleton node %d world (diff %.4g) -> Swift re-parents the mesh node next to the skeleton" % (si, ni, sk, d))
                if ni in world and np.abs(world[ni] - np.eye(4)).max() > 1e-4:
                    rep.fact("skinned mesh node %d has a non-identity world transform" % ni)

    # ---- bounds ----
    if np.all(mx >= mn):
        size = mx - mn
        rep.fact("static world bounds min=%s max=%s size=%s" % (np.round(mn, 3).tolist(), np.round(mx, 3).tolist(), np.round(size, 3).tolist()))
        if not np.isfinite(size).all() or size.max() > 1e5 or size.max() <= 0:
            rep.problem("implausible bounds %s" % size)
    rep.fact("meshes=%d tris=%d verts=%d nodes=%d materials=%d skins=%d" % (len(meshes), total_tris, total_verts, len(nodes), len(materials), len(skins)))
    for w in rd.warnings:
        rep.fact("WARNING " + w)
    return rep


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    quiet = "--quiet" in sys.argv
    files = args
    if not files:
        for d in (os.path.join(ROOT, "assets_src"), os.path.join(ROOT, "Supercars", "Resources", "Models")):
            if os.path.isdir(d):
                for f in sorted(os.listdir(d)):
                    if f.lower().endswith(".glb"):
                        files.append(os.path.join(d, f))
    if not files:
        print("no .glb files found")
        return 1
    bad = 0
    for f in files:
        try:
            rep = check_file(f, quiet)
        except Exception as e:  # noqa
            print("FAIL %s: %s" % (f, e))
            bad += 1
            continue
        status = "OK  " if not rep.problems else "FAIL"
        print("%s %s" % (status, rep.name))
        if not quiet:
            for fact in rep.facts:
                print("     . " + fact)
        for p in rep.problems:
            print("     ! " + p)
        if rep.problems:
            bad += 1
    print("%d file(s), %d with problems" % (len(files), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
