# -*- coding: utf-8 -*-
"""Tiny matplotlib painter's-algorithm preview renderer for asset sanity checks (no GPU, no Blender).

    from asset_preview import render
    render(list_of_(pos, idx, rgb), "out.png", view="side")      # view: side | top | front | iso | back | iso2

pos: (N,3) float, idx: (M,3) int, rgb: 3-tuple 0..1. Game space (Y up, +Z front, +X left).
"""
import numpy as np


def _basis(view):
    # returns (right, up, toward-viewer) unit vectors in world space
    if view == "side":       # look from +X (car left side) toward -X ; car front (+Z) points to screen left? make front to the right
        r, u, w = np.array([0, 0, -1.0]), np.array([0, 1.0, 0]), np.array([1.0, 0, 0])
    elif view == "side_r":
        r, u, w = np.array([0, 0, 1.0]), np.array([0, 1.0, 0]), np.array([-1.0, 0, 0])
    elif view == "top":
        r, u, w = np.array([-1.0, 0, 0]), np.array([0, 0, 1.0]), np.array([0, 1.0, 0])
    elif view == "front":
        r, u, w = np.array([-1.0, 0, 0]), np.array([0, 1.0, 0]), np.array([0, 0, 1.0])
    elif view == "back":
        r, u, w = np.array([1.0, 0, 0]), np.array([0, 1.0, 0]), np.array([0, 0, -1.0])
    elif view == "iso":      # front-left three-quarter
        w = np.array([0.6, 0.45, 0.66]); w /= np.linalg.norm(w)
        r = np.cross([0, 1.0, 0], w); r /= np.linalg.norm(r)
        u = np.cross(w, r)
    else:                    # iso2: rear-left three-quarter
        w = np.array([0.6, 0.45, -0.66]); w /= np.linalg.norm(w)
        r = np.cross([0, 1.0, 0], w); r /= np.linalg.norm(r)
        u = np.cross(w, r)
    return r, u, w


def render(parts, out_path, view="side", size=(1100, 700), bg=(0.86, 0.88, 0.92), edges=False, title=None, clip=None):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.collections import PolyCollection
    r, u, w = _basis(view)
    light = np.array([0.3, 0.8, 0.5]); light /= np.linalg.norm(light)
    polys, cols, depth = [], [], []
    for pos, idx, rgb in parts:
        pos = np.asarray(pos, dtype=np.float64)
        idx = np.asarray(idx).reshape(-1, 3)
        if clip is not None:
            keep = (pos[idx].mean(axis=1) * np.array(clip[0])).sum(axis=1) < clip[1]
            idx = idx[keep]
        if len(idx) == 0:
            continue
        p3 = pos[idx]
        n = np.cross(p3[:, 1] - p3[:, 0], p3[:, 2] - p3[:, 0])
        ln = np.linalg.norm(n, axis=1, keepdims=True)
        n = n / np.maximum(ln, 1e-12)
        facing = n.dot(w)
        shade = 0.35 + 0.65 * np.clip(np.abs(n.dot(light)), 0, 1)
        sx = p3.dot(r)
        sy = p3.dot(u)
        polys.append(np.stack([sx, sy], axis=2))
        base = np.array(rgb, dtype=np.float64)
        c = np.clip(base[None, :] * shade[:, None], 0, 1)
        c = np.where((facing < 0)[:, None], c * 0.8, c)
        cols.append(c)
        depth.append(p3.mean(axis=1).dot(w))
    P = np.concatenate(polys)
    C = np.concatenate(cols)
    D = np.concatenate(depth)
    order = np.argsort(D)
    P, C = P[order], C[order]
    fig = plt.figure(figsize=(size[0] / 100.0, size[1] / 100.0), dpi=100)
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_facecolor(bg)
    fig.patch.set_facecolor(bg)
    pc = PolyCollection(P, facecolors=C, edgecolors=(C * 0.5 if edges else "face"), linewidths=0.2 if edges else 0.3)
    ax.add_collection(pc)
    ax.set_xlim(P[:, :, 0].min() - 0.1, P[:, :, 0].max() + 0.1)
    ax.set_ylim(P[:, :, 1].min() - 0.1, P[:, :, 1].max() + 0.1)
    ax.set_aspect("equal")
    ax.axis("off")
    if title:
        ax.text(0.01, 0.98, title, transform=ax.transAxes, va="top", fontsize=9)
    fig.savefig(out_path, dpi=100)
    plt.close(fig)
