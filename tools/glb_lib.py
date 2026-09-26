# -*- coding: utf-8 -*-
"""Minimal, dependency-light glTF/GLB reader (numpy only) used by the SUPERCARS asset pipeline.

Extended from C:/blender-claude/game/glb_lib.py: image/material/skin access, node parents,
per-primitive extraction with node->world transforms.
"""
import io
import json
import struct

import numpy as np

COMP = {5120: np.int8, 5121: np.uint8, 5122: np.int16, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16}


def quat_to_mat3(q):
    x, y, z, w = q
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


class GLB(object):
    def __init__(self, path):
        with open(path, "rb") as f:
            magic, ver, length = struct.unpack("<4sII", f.read(12))
            assert magic == b"glTF"
            self.json = None
            self.bin = b""
            while True:
                head = f.read(8)
                if len(head) < 8:
                    break
                clen, ctype = struct.unpack("<II", head)
                data = f.read(clen)
                if ctype == 0x4E4F534A:
                    self.json = json.loads(data)
                elif ctype == 0x004E4942:
                    self.bin = data
        j = self.json
        self.nodes, self.meshes = j["nodes"], j["meshes"]
        self.materials = j.get("materials", [])
        self.parent = {}
        for i, n in enumerate(self.nodes):
            for c in n.get("children", []):
                self.parent[c] = i

    # ------------------------------------------------------------------ accessors
    def accessor(self, idx):
        a = self.json["accessors"][idx]
        bv = self.json["bufferViews"][a["bufferView"]] if "bufferView" in a else None
        dt = np.dtype(COMP[a["componentType"]])
        n = NCOMP[a["type"]]
        count = a["count"]
        if bv is None:
            return np.zeros((count, n), dtype=dt)
        off = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
        stride = bv.get("byteStride", 0)
        if stride and stride != dt.itemsize * n:
            raw = np.frombuffer(self.bin, dtype=np.uint8, count=stride * count, offset=off).reshape(count, stride)
            arr = raw[:, :dt.itemsize * n].copy().view(dt).reshape(count, n)
        else:
            arr = np.frombuffer(self.bin, dtype=dt, count=count * n, offset=off).reshape(count, n)
        if a.get("normalized"):
            info = np.iinfo(dt)
            arr = np.maximum(arr.astype(np.float32) / info.max, -1.0)
        return arr

    def image_bytes(self, idx):
        im = self.json["images"][idx]
        bv = self.json["bufferViews"][im["bufferView"]]
        off = bv.get("byteOffset", 0)
        return self.bin[off:off + bv["byteLength"]], im.get("mimeType", "")

    def texture_image_index(self, tex_index):
        if tex_index is None:
            return None
        return self.json["textures"][tex_index].get("source")

    def pil_image(self, img_idx):
        from PIL import Image
        raw, _ = self.image_bytes(img_idx)
        im = Image.open(io.BytesIO(raw))
        im.load()
        return im

    # ------------------------------------------------------------------ nodes
    @staticmethod
    def local_matrix(node):
        if "matrix" in node:
            return np.array(node["matrix"], dtype=np.float64).reshape(4, 4).T     # glTF is column-major
        t = np.array(node.get("translation", [0, 0, 0]), dtype=np.float64)
        q = node.get("rotation", [0, 0, 0, 1])
        s = np.array(node.get("scale", [1, 1, 1]), dtype=np.float64)
        M = np.eye(4)
        M[:3, :3] = quat_to_mat3(q) * s
        M[:3, 3] = t
        return M

    def world_matrix(self, i):
        M = self.local_matrix(self.nodes[i])
        while i in self.parent:
            i = self.parent[i]
            M = self.local_matrix(self.nodes[i]).dot(M)
        return M

    def walk(self):
        """yield (node_index, node, world_matrix_4x4) for every node in the default scene."""
        j = self.json
        stack = [(r, np.eye(4)) for r in j["scenes"][j.get("scene", 0)]["nodes"]]
        while stack:
            i, parent = stack.pop()
            node = self.nodes[i]
            W = parent.dot(self.local_matrix(node))
            yield i, node, W
            for c in node.get("children", []):
                stack.append((c, W))

    def material_name(self, mi):
        return self.materials[mi].get("name", "mat%d" % mi) if mi is not None else "default"

    def primitives(self, apply_world=True):
        """yield dict(node, name, mesh, prim, mat, pos, nrm, uv, idx(flat), flip, W, attrs); pos/nrm in world space (float64)."""
        for i, node, W in self.walk():
            if "mesh" not in node:
                continue
            mesh = self.meshes[node["mesh"]]
            if not apply_world:
                W = np.eye(4)
            for pi, p in enumerate(mesh["primitives"]):
                if p.get("mode", 4) != 4:
                    continue
                at = p["attributes"]
                pos = self.accessor(at["POSITION"]).astype(np.float64)
                pos_w = pos.dot(W[:3, :3].T) + W[:3, 3]
                nrm = None
                if "NORMAL" in at:
                    n = self.accessor(at["NORMAL"]).astype(np.float64)
                    nrm = n.dot(np.linalg.inv(W[:3, :3]))            # inverse-transpose applied on row vectors
                    ln = np.linalg.norm(nrm, axis=1, keepdims=True)
                    nrm = nrm / np.maximum(ln, 1e-12)
                uv = self.accessor(at["TEXCOORD_0"]).astype(np.float32) if "TEXCOORD_0" in at else None
                if "indices" in p:
                    idx = self.accessor(p["indices"]).astype(np.int64).reshape(-1)
                else:
                    idx = np.arange(len(pos))
                yield {"node": i, "name": node.get("name"), "mesh": node["mesh"], "prim": pi, "mat": p.get("material"),
                       "pos": pos_w, "nrm": nrm, "uv": uv, "idx": idx, "flip": bool(np.linalg.det(W[:3, :3]) < 0),
                       "W": W, "attrs": at}

    def material_info(self, mi):
        """dict: name, base factor, metal, rough, emissive, image indices, alpha mode, doubleSided."""
        if mi is None:
            return {"name": "default", "base": [1, 1, 1, 1], "metal": 0.0, "rough": 0.8, "emis": [0, 0, 0], "base_img": None,
                    "emis_img": None, "alpha": "OPAQUE", "cutoff": 0.5, "double": False, "normal_img": None, "mr_img": None}
        m = self.materials[mi]
        pbr = m.get("pbrMetallicRoughness", {})
        mf = pbr.get("metallicFactor")
        rf = pbr.get("roughnessFactor")
        bt = pbr.get("baseColorTexture")
        mt = pbr.get("metallicRoughnessTexture")
        return {
            "name": m.get("name", "mat%d" % mi),
            "base": pbr.get("baseColorFactor", [1, 1, 1, 1]),
            "metal": 1.0 if mf is None else mf,
            "rough": 1.0 if rf is None else rf,
            "emis": m.get("emissiveFactor", [0, 0, 0]),
            "base_img": self.texture_image_index(bt["index"]) if bt else None,
            "mr_img": self.texture_image_index(mt["index"]) if mt else None,
            "emis_img": self.texture_image_index(m["emissiveTexture"]["index"]) if "emissiveTexture" in m else None,
            "normal_img": self.texture_image_index(m["normalTexture"]["index"]) if "normalTexture" in m else None,
            "alpha": m.get("alphaMode", "OPAQUE"), "cutoff": m.get("alphaCutoff", 0.5), "double": bool(m.get("doubleSided", False)),
            "raw": m,
        }
