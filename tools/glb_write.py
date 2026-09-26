# -*- coding: utf-8 -*-
"""Small, standard-compliant glTF 2.0 binary (.glb) writer for the SUPERCARS asset pipeline.

Scene graph model
    Node(name, translation, rotation(xyzw), scale, children, mesh, skin, extras)
    Mesh(name, [Prim]);  Prim(pos, nrm, uv, idx, material, joints, weights, uv1)
    Material(name, base_color, metallic, roughness, emissive, base_image, emissive_image, alpha_mode, alpha_cutoff, double_sided)
    Image(name, data(bytes PNG/JPEG), mime)
    Skin(name, joints=[Node], inverse_bind=(J,4,4) array of row-major matrices, skeleton=Node)

Output rules (so a hand written loader can read it): float32 VEC3 positions/normals, float32 VEC2 uvs, indices UNSIGNED_SHORT
(if the primitive has < 65536 vertices) else UNSIGNED_INT, joints UNSIGNED_BYTE/SHORT VEC4, weights float32 VEC4, tightly
packed (no byteStride), no extensions, no sparse accessors, embedded images in bufferViews, every bufferView 4-byte aligned.
"""
import io
import json
import struct

import numpy as np


class Image(object):
    def __init__(self, name, data, mime):
        self.name = name
        self.data = data
        self.mime = mime


class Material(object):
    def __init__(self, name, base_color=(1.0, 1.0, 1.0, 1.0), metallic=0.0, roughness=1.0, emissive=(0.0, 0.0, 0.0),
                 base_image=None, emissive_image=None, alpha_mode="OPAQUE", alpha_cutoff=0.5, double_sided=False,
                 normal_image=None, metal_rough_image=None):
        self.name = name
        self.base_color = tuple(float(x) for x in base_color)
        self.metallic = float(metallic)
        self.roughness = float(roughness)
        self.emissive = tuple(float(x) for x in emissive)
        self.base_image = base_image
        self.emissive_image = emissive_image
        self.normal_image = normal_image
        self.metal_rough_image = metal_rough_image
        self.alpha_mode = alpha_mode
        self.alpha_cutoff = alpha_cutoff
        self.double_sided = double_sided


class Prim(object):
    def __init__(self, pos, idx, nrm=None, uv=None, material=None, joints=None, weights=None):
        self.pos = np.asarray(pos, dtype=np.float32).reshape(-1, 3)
        self.idx = np.asarray(idx).reshape(-1).astype(np.int64)
        self.nrm = None if nrm is None else np.asarray(nrm, dtype=np.float32).reshape(-1, 3)
        self.uv = None if uv is None else np.asarray(uv, dtype=np.float32).reshape(-1, 2)
        self.material = material
        self.joints = None if joints is None else np.asarray(joints)
        self.weights = None if weights is None else np.asarray(weights, dtype=np.float32).reshape(-1, 4)


class Mesh(object):
    def __init__(self, name, prims):
        self.name = name
        self.prims = list(prims)


class Node(object):
    def __init__(self, name, translation=None, rotation=None, scale=None, mesh=None, skin=None, children=None, extras=None):
        self.name = name
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
        self.mesh = mesh
        self.skin = skin
        self.children = list(children) if children else []
        self.extras = extras

    def add(self, child):
        self.children.append(child)
        return child


class Skin(object):
    def __init__(self, name, joints, inverse_bind, skeleton=None):
        self.name = name
        self.joints = list(joints)
        self.inverse_bind = np.asarray(inverse_bind, dtype=np.float32).reshape(-1, 4, 4)
        self.skeleton = skeleton


def png_bytes(pil_image):
    b = io.BytesIO()
    pil_image.save(b, format="PNG", optimize=True)
    return b.getvalue()


def jpeg_bytes(pil_image, quality=85):
    b = io.BytesIO()
    pil_image.convert("RGB").save(b, format="JPEG", quality=quality, optimize=True, progressive=False)
    return b.getvalue()


def _pad4(b, fill=b"\x00"):
    r = (-len(b)) % 4
    return b + fill * r


class _Writer(object):
    def __init__(self):
        self.bin = bytearray()
        self.views = []
        self.accessors = []

    def add_view(self, data, target=None):
        while len(self.bin) % 4:
            self.bin.append(0)
        off = len(self.bin)
        self.bin.extend(data)
        v = {"buffer": 0, "byteOffset": off, "byteLength": len(data)}
        if target:
            v["target"] = target
        self.views.append(v)
        return len(self.views) - 1

    def add_accessor(self, arr, ctype, atype, target, minmax=False, normalized=False):
        data = np.ascontiguousarray(arr).tobytes()
        vi = self.add_view(data, target)
        n = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}[atype]
        a = {"bufferView": vi, "componentType": ctype, "count": int(arr.shape[0] if arr.ndim > 1 else arr.shape[0]), "type": atype}
        if arr.ndim == 1 and n == 1:
            a["count"] = int(arr.shape[0])
        if normalized:
            a["normalized"] = True
        if minmax:
            a2 = arr.reshape(-1, n)
            a["min"] = [float(x) for x in a2.min(axis=0)]
            a["max"] = [float(x) for x in a2.max(axis=0)]
        self.accessors.append(a)
        return len(self.accessors) - 1


def write_glb(path, roots, scene_name="scene", asset_extras=None, extra_json=None):
    """roots: list of Node. Returns dict(stats)."""
    w = _Writer()
    nodes = []          # Node objects in order
    node_index = {}
    mesh_list, mesh_index = [], {}
    mat_list, mat_index = [], {}
    img_list, img_index = [], {}
    skin_list, skin_index = [], {}

    def visit(n):
        node_index[id(n)] = len(nodes)
        nodes.append(n)
        if n.mesh is not None and id(n.mesh) not in mesh_index:
            mesh_index[id(n.mesh)] = len(mesh_list)
            mesh_list.append(n.mesh)
        if n.skin is not None and id(n.skin) not in skin_index:
            skin_index[id(n.skin)] = len(skin_list)
            skin_list.append(n.skin)
        for c in n.children:
            visit(c)

    for r in roots:
        visit(r)

    # ---- materials / images
    def image_idx(im):
        if im is None:
            return None
        if id(im) not in img_index:
            img_index[id(im)] = len(img_list)
            img_list.append(im)
        return img_index[id(im)]

    for m in mesh_list:
        for p in m.prims:
            mt = p.material
            if mt is not None and id(mt) not in mat_index:
                mat_index[id(mt)] = len(mat_list)
                mat_list.append(mt)

    # ---- images -> bufferViews (textures 1:1 with images, one shared sampler)
    images_json, textures_json = [], []
    tex_of_image = {}
    for mt in mat_list:
        for im in (mt.base_image, mt.emissive_image, mt.normal_image, mt.metal_rough_image):
            image_idx(im)
    for k, im in enumerate(img_list):
        vi = w.add_view(im.data)
        images_json.append({"name": im.name, "bufferView": vi, "mimeType": im.mime})
        textures_json.append({"sampler": 0, "source": k, "name": im.name})
        tex_of_image[id(im)] = k

    mats_json = []
    for mt in mat_list:
        pbr = {"baseColorFactor": [round(x, 5) for x in mt.base_color], "metallicFactor": round(mt.metallic, 4),
               "roughnessFactor": round(mt.roughness, 4)}
        if mt.base_image is not None:
            pbr["baseColorTexture"] = {"index": tex_of_image[id(mt.base_image)]}
        if mt.metal_rough_image is not None:
            pbr["metallicRoughnessTexture"] = {"index": tex_of_image[id(mt.metal_rough_image)]}
        mj = {"name": mt.name, "pbrMetallicRoughness": pbr}
        if any(x > 0 for x in mt.emissive) or mt.emissive_image is not None:
            mj["emissiveFactor"] = [round(x, 4) for x in mt.emissive]
        if mt.emissive_image is not None:
            mj["emissiveTexture"] = {"index": tex_of_image[id(mt.emissive_image)]}
        if mt.normal_image is not None:
            mj["normalTexture"] = {"index": tex_of_image[id(mt.normal_image)]}
        if mt.alpha_mode != "OPAQUE":
            mj["alphaMode"] = mt.alpha_mode
            if mt.alpha_mode == "MASK":
                mj["alphaCutoff"] = mt.alpha_cutoff
        if mt.double_sided:
            mj["doubleSided"] = True
        mats_json.append(mj)

    # ---- meshes
    meshes_json = []
    tri_total = 0
    vert_total = 0
    for m in mesh_list:
        prims_json = []
        for p in m.prims:
            nv = p.pos.shape[0]
            tri_total += len(p.idx) // 3
            vert_total += nv
            attrs = {"POSITION": w.add_accessor(p.pos, 5126, "VEC3", 34962, minmax=True)}
            if p.nrm is not None:
                attrs["NORMAL"] = w.add_accessor(p.nrm, 5126, "VEC3", 34962)
            if p.uv is not None:
                attrs["TEXCOORD_0"] = w.add_accessor(p.uv, 5126, "VEC2", 34962)
            if p.joints is not None:
                jt = p.joints
                if jt.max() < 256:
                    attrs["JOINTS_0"] = w.add_accessor(jt.astype(np.uint8).reshape(-1, 4), 5121, "VEC4", 34962)
                else:
                    attrs["JOINTS_0"] = w.add_accessor(jt.astype(np.uint16).reshape(-1, 4), 5123, "VEC4", 34962)
                attrs["WEIGHTS_0"] = w.add_accessor(p.weights, 5126, "VEC4", 34962)
            if nv < 65536:
                ia = w.add_accessor(p.idx.astype(np.uint16), 5123, "SCALAR", 34963)
            else:
                ia = w.add_accessor(p.idx.astype(np.uint32), 5125, "SCALAR", 34963)
            pj = {"attributes": attrs, "indices": ia, "mode": 4}
            if p.material is not None:
                pj["material"] = mat_index[id(p.material)]
            prims_json.append(pj)
        meshes_json.append({"name": m.name, "primitives": prims_json})

    # ---- skins
    skins_json = []
    for s in skin_list:
        # glTF matrices are column-major: our row-major (J,4,4) -> transpose each
        ibm = np.ascontiguousarray(np.transpose(s.inverse_bind, (0, 2, 1))).astype(np.float32)
        acc = w.add_accessor(ibm.reshape(-1, 16), 5126, "MAT4", None)
        sj = {"name": s.name, "joints": [node_index[id(j)] for j in s.joints], "inverseBindMatrices": acc}
        if s.skeleton is not None:
            sj["skeleton"] = node_index[id(s.skeleton)]
        skins_json.append(sj)

    # ---- nodes
    nodes_json = []
    for n in nodes:
        nj = {"name": n.name}
        if n.translation is not None and any(abs(x) > 1e-9 for x in n.translation):
            nj["translation"] = [float(x) for x in n.translation]
        if n.rotation is not None and any(abs(a - b) > 1e-9 for a, b in zip(n.rotation, (0, 0, 0, 1))):
            nj["rotation"] = [float(x) for x in n.rotation]
        if n.scale is not None and any(abs(x - 1.0) > 1e-9 for x in n.scale):
            nj["scale"] = [float(x) for x in n.scale]
        if n.mesh is not None:
            nj["mesh"] = mesh_index[id(n.mesh)]
        if n.skin is not None:
            nj["skin"] = skin_index[id(n.skin)]
        if n.children:
            nj["children"] = [node_index[id(c)] for c in n.children]
        if n.extras:
            nj["extras"] = n.extras
        nodes_json.append(nj)

    j = {
        "asset": {"version": "2.0", "generator": "SUPERCARS tools/glb_write.py"},
        "scene": 0,
        "scenes": [{"name": scene_name, "nodes": [node_index[id(r)] for r in roots]}],
        "nodes": nodes_json,
        "buffers": [{"byteLength": len(w.bin)}],
        "bufferViews": w.views,
        "accessors": w.accessors,
    }
    if asset_extras:
        j["asset"]["extras"] = asset_extras
    if meshes_json:
        j["meshes"] = meshes_json
    if mats_json:
        j["materials"] = mats_json
    if images_json:
        j["images"] = images_json
        j["textures"] = textures_json
        j["samplers"] = [{"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}]
    if skins_json:
        j["skins"] = skins_json
    if extra_json:
        j.update(extra_json)
    jb = _pad4(json.dumps(j, separators=(",", ":")).encode("utf-8"), b" ")
    bb = _pad4(bytes(w.bin), b"\x00")
    total = 12 + 8 + len(jb) + 8 + len(bb)
    with open(path, "wb") as f:
        f.write(struct.pack("<4sII", b"glTF", 2, total))
        f.write(struct.pack("<II", len(jb), 0x4E4F534A))
        f.write(jb)
        f.write(struct.pack("<II", len(bb), 0x004E4942))
        f.write(bb)
    return {"bytes": total, "triangles": tri_total, "vertices": vert_total, "materials": len(mats_json), "images": len(images_json),
            "nodes": len(nodes_json), "meshes": len(meshes_json)}
