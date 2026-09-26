# -*- coding: utf-8 -*-
"""Quick painter's-algorithm preview of one or more GLBs (flat colours from material base colour / average texture colour).

    python asset_glb_preview.py out.png view file1.glb [file2.glb ...]     (files are placed side by side along the screen x axis)
"""
import io
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from glb_lib import GLB                    # noqa: E402
from asset_preview import render           # noqa: E402


def glb_parts(path, dx=0.0):
    g = GLB(path)
    j = g.json
    avg = {}
    parts = []
    for p in g.primitives():
        mi = g.material_info(p["mat"])
        col = np.array(mi["base"][:3], dtype=np.float64)
        if mi["base_img"] is not None:
            if mi["base_img"] not in avg:
                im = g.pil_image(mi["base_img"]).convert("RGBA").resize((16, 16))
                a = np.asarray(im).astype(np.float64) / 255.0
                w = a[..., 3:4]
                avg[mi["base_img"]] = (a[..., :3] * w).sum((0, 1)) / max(w.sum(), 1e-6)
            col = col * avg[mi["base_img"]]
        pos = p["pos"].copy()
        pos[:, 0] += dx
        parts.append((pos, p["idx"].reshape(-1, 3), tuple(np.clip(col, 0, 1))))
    return parts


if __name__ == "__main__":
    out, view = sys.argv[1], sys.argv[2]
    allp = []
    dx = 0.0
    for f in sys.argv[3:]:
        ps = glb_parts(f, dx)
        allp += ps
        dx += 9.0
    render(allp, out, view=view, size=(1400, 700))
