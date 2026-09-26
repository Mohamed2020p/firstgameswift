# -*- coding: utf-8 -*-
"""Shared helpers of the asset pipeline: paths, texture conversion (with caching), quaternion maths."""
import io
import os

import numpy as np
from PIL import Image as PILImage

import glb_write as W

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, "assets_src")
MODELS = os.path.join(ROOT, "Supercars", "Resources", "Models")
TEXTURES = os.path.join(ROOT, "Supercars", "Resources", "Textures")
DATA = os.path.join(ROOT, "Supercars", "Resources", "Data")
SCRATCH = os.environ.get("ASSET_SCRATCH",
                         r"C:\Users\c0derz\AppData\Local\Temp\claude\C--Users-c0derz-Documents-blender-mcp\29c190b4-2c20-46c6-a9a6-3588413499b4\scratchpad\aw")


def ensure_dirs():
    for d in (MODELS, TEXTURES, DATA, SCRATCH):
        os.makedirs(d, exist_ok=True)


def has_real_alpha(im, thresh=250):
    if im.mode == "P":
        im = im.convert("RGBA")
    if im.mode not in ("RGBA", "LA"):
        return False
    a = np.asarray(im.getchannel("A"))
    return bool(a.min() < thresh)


class ImageCache(object):
    """Converts source PIL images to writer Images (downscaled, JPEG when opaque, PNG when alpha) and dedupes them."""

    def __init__(self):
        self.cache = {}

    def get(self, key, pil, max_size, quality=85, force_png=False, name=None, force_rgb=False, gray_to_rgb=True):
        k = (key, max_size, force_png, quality, force_rgb)
        if k in self.cache:
            return self.cache[k]
        im = pil
        if im.mode == "P":
            im = im.convert("RGBA")
        if im.mode in ("L", "LA", "I;16", "1"):
            im = im.convert("RGBA" if im.mode == "LA" else "RGB")
        if im.mode not in ("RGB", "RGBA"):
            im = im.convert("RGBA")
        if max(im.size) > max_size:
            f = max_size / float(max(im.size))
            im = im.resize((max(4, int(round(im.size[0] * f))), max(4, int(round(im.size[1] * f)))), PILImage.LANCZOS)
        alpha = (not force_rgb) and (has_real_alpha(im) or force_png)
        if alpha:
            data = W.png_bytes(im.convert("RGBA"))
            mime = "image/png"
        else:
            data = W.jpeg_bytes(im.convert("RGB"), quality)
            mime = "image/jpeg"
        out = W.Image(name or ("img_%s" % str(key)), data, mime)
        out.size = im.size
        self.cache[k] = out
        return out


# ------------------------------------------------------------------ rotations (xyzw quaternions)
def quat_from_matrix(R):
    R = np.asarray(R, dtype=np.float64)
    t = np.trace(R)
    if t > 0:
        s = np.sqrt(t + 1.0) * 2
        w = 0.25 * s
        x = (R[2, 1] - R[1, 2]) / s
        y = (R[0, 2] - R[2, 0]) / s
        z = (R[1, 0] - R[0, 1]) / s
    elif R[0, 0] > R[1, 1] and R[0, 0] > R[2, 2]:
        s = np.sqrt(1.0 + R[0, 0] - R[1, 1] - R[2, 2]) * 2
        w = (R[2, 1] - R[1, 2]) / s
        x = 0.25 * s
        y = (R[0, 1] + R[1, 0]) / s
        z = (R[0, 2] + R[2, 0]) / s
    elif R[1, 1] > R[2, 2]:
        s = np.sqrt(1.0 + R[1, 1] - R[0, 0] - R[2, 2]) * 2
        w = (R[0, 2] - R[2, 0]) / s
        x = (R[0, 1] + R[1, 0]) / s
        y = 0.25 * s
        z = (R[1, 2] + R[2, 1]) / s
    else:
        s = np.sqrt(1.0 + R[2, 2] - R[0, 0] - R[1, 1]) * 2
        w = (R[1, 0] - R[0, 1]) / s
        x = (R[0, 2] + R[2, 0]) / s
        y = (R[1, 2] + R[2, 1]) / s
        z = 0.25 * s
    q = np.array([x, y, z, w])
    return q / np.linalg.norm(q)


def rgb(x):
    return tuple(float(v) for v in x)


def size_kb(path):
    return os.path.getsize(path) / 1024.0
