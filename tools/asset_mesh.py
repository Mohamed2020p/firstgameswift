# -*- coding: utf-8 -*-
"""numpy mesh helpers for the SUPERCARS asset pipeline: welding, smoothing-group normals, merging, cleanup."""
import numpy as np


def face_normals(pos, idx):
    p = pos[idx]
    n = np.cross(p[:, 1] - p[:, 0], p[:, 2] - p[:, 0])
    return n


def merge(meshes):
    """meshes: list of dicts with pos (N,3), idx (M,3) and optional uv/nrm/joints/weights -> one dict."""
    out = {"pos": [], "idx": []}
    keys = [k for k in ("uv", "nrm", "joints", "weights") if all(m.get(k) is not None for m in meshes)]
    for k in keys:
        out[k] = []
    off = 0
    for m in meshes:
        out["pos"].append(m["pos"])
        out["idx"].append(np.asarray(m["idx"]).reshape(-1, 3) + off)
        for k in keys:
            out[k].append(m[k])
        off += len(m["pos"])
    for k in list(out.keys()):
        out[k] = np.concatenate(out[k]) if out[k] else None
    return out


def remove_degenerate(pos, idx, area_eps=1e-14):
    idx = np.asarray(idx).reshape(-1, 3)
    n = face_normals(pos.astype(np.float64), idx)
    a = np.linalg.norm(n, axis=1)
    keep = (a > area_eps) & (idx[:, 0] != idx[:, 1]) & (idx[:, 1] != idx[:, 2]) & (idx[:, 0] != idx[:, 2])
    return idx[keep]


def compact(pos, idx, *attrs):
    """drop unused vertices; returns (pos, idx, *attrs)"""
    idx = np.asarray(idx).reshape(-1, 3)
    used = np.unique(idx)
    remap = np.full(len(pos), -1, dtype=np.int64)
    remap[used] = np.arange(len(used))
    return (pos[used], remap[idx]) + tuple(None if a is None else a[used] for a in attrs)


def smooth_normals(pos, idx, uv=None, angle=45.0, uv_split=True):
    """Compute per-vertex normals with a crease angle. Vertices are split where the crease angle is exceeded (and where the uv differs,
    if `uv` is given: the caller's vertices are kept as they are, only split further).
    Returns (pos, nrm, uv, idx) with new vertex arrays."""
    pos = np.asarray(pos, dtype=np.float64)
    idx = np.asarray(idx).reshape(-1, 3)
    nf = len(idx)
    fn = face_normals(pos, idx)
    area = np.linalg.norm(fn, axis=1)
    unit = fn / np.maximum(area, 1e-20)[:, None]
    # per-corner angle weight
    p = pos[idx]
    e0 = p[:, 1] - p[:, 0]
    e1 = p[:, 2] - p[:, 1]
    e2 = p[:, 0] - p[:, 2]

    def ang(a, b):
        la = np.linalg.norm(a, axis=1)
        lb = np.linalg.norm(b, axis=1)
        c = np.clip((a * b).sum(axis=1) / np.maximum(la * lb, 1e-20), -1, 1)
        return np.arccos(c)

    w = np.stack([ang(-e2, e0), ang(-e0, e1), ang(-e1, e2)], axis=1)      # angle at corners 0,1,2
    corner_v = idx.reshape(-1)
    corner_f = np.repeat(np.arange(nf), 3)
    corner_w = w.reshape(-1) * np.repeat(area > 0, 3)
    order = np.argsort(corner_v, kind="stable")
    sv = corner_v[order]
    counts = np.bincount(sv, minlength=len(pos))
    starts = np.concatenate([[0], np.cumsum(counts)[:-1]])
    # pairs inside each vertex group
    cs = counts[sv]                                  # group size for each sorted corner
    st = starts[sv]
    total = int(cs.sum())
    rep_c = np.repeat(np.arange(len(sv)), cs)        # corner (sorted position)
    cum = np.concatenate([[0], np.cumsum(cs)[:-1]])
    within = np.arange(total) - np.repeat(cum, cs)
    other = np.repeat(st, cs) + within               # other corner (sorted position) in the same group
    fa = corner_f[order][rep_c]
    fb = corner_f[order][other]
    dot = (unit[fa] * unit[fb]).sum(axis=1)
    cosang = np.cos(np.radians(angle))
    ok = dot >= cosang
    contrib = unit[fb] * corner_w[order][other][:, None]
    ns = np.zeros((len(sv), 3))
    np.add.at(ns, rep_c[ok], contrib[ok])
    nrm_sorted = ns / np.maximum(np.linalg.norm(ns, axis=1, keepdims=True), 1e-20)
    corner_n = np.zeros((nf * 3, 3))
    corner_n[order] = nrm_sorted
    # build new vertex list: unique (vertex, quantised normal, uv)
    q = np.round(corner_n * 1000).astype(np.int64)
    cols = [corner_v[:, None], q]
    if uv is not None and uv_split:
        cols.append(np.round(np.asarray(uv)[corner_v] * 20000).astype(np.int64))
    key = np.concatenate(cols, axis=1)
    _, first, inv = np.unique(key, axis=0, return_index=True, return_inverse=True)
    inv = inv.reshape(-1)
    src = corner_v[first]
    new_pos = pos[src]
    new_n = corner_n[first]
    new_uv = None if uv is None else np.asarray(uv)[src]
    new_idx = inv.reshape(nf, 3)
    return new_pos.astype(np.float32), new_n.astype(np.float32), (None if new_uv is None else new_uv.astype(np.float32)), new_idx


def weld_by_position(pos, tol=1e-5):
    key = np.round(np.asarray(pos, dtype=np.float64) / tol).astype(np.int64)
    _, first, inv = np.unique(key, axis=0, return_index=True, return_inverse=True)
    return first, inv.reshape(-1)


def transform(pos, M):
    """apply 4x4 (row-vector convention: M @ v) to positions"""
    M = np.asarray(M, dtype=np.float64)
    return pos.dot(M[:3, :3].T) + M[:3, 3]


def transform_normals(nrm, M):
    M = np.asarray(M, dtype=np.float64)
    n = nrm.dot(np.linalg.inv(M[:3, :3]))
    return n / np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-20)


def components(pos, idx, tol=5e-4):
    """face connected components (positions welded). Returns labels per face."""
    import scipy.sparse as sp
    from scipy.sparse.csgraph import connected_components
    idx = np.asarray(idx).reshape(-1, 3)
    _, inv = weld_by_position(pos, tol)
    f = inv[idx]
    n = int(inv.max()) + 1
    rows = np.concatenate([f[:, 0], f[:, 1], f[:, 2]])
    cols = np.concatenate([f[:, 1], f[:, 2], f[:, 0]])
    A = sp.coo_matrix((np.ones(len(rows)), (rows, cols)), shape=(n, n))
    nc, lab = connected_components(A, directed=False)
    return lab[f[:, 0]], nc


def sub_mesh(pos, idx, face_mask, *attrs):
    """extract faces (compacted). returns (pos, idx, *attrs)"""
    idx = np.asarray(idx).reshape(-1, 3)[face_mask]
    return compact(pos, idx, *attrs)


def cluster_decimate(pos, idx, uv=None, target=500, lo=0.005, hi=2.0, iters=24):
    """vertex-clustering decimation (grid quantisation, binary search on the cell size until <= target triangles remain).
    Cluster position = mean of members; uv = uv of the member closest to the mean. Returns (pos, idx, uv)."""
    pos = np.asarray(pos, dtype=np.float64)
    idx = np.asarray(idx).reshape(-1, 3)

    def run(cell):
        key = np.floor((pos - pos.min(0)) / cell).astype(np.int64)
        _, cid = np.unique(key, axis=0, return_inverse=True)
        cid = cid.reshape(-1)
        n = cid.max() + 1
        cnt = np.bincount(cid, minlength=n).astype(np.float64)
        cp = np.stack([np.bincount(cid, weights=pos[:, k], minlength=n) for k in range(3)], axis=1) / cnt[:, None]
        f = cid[idx]
        keep = (f[:, 0] != f[:, 1]) & (f[:, 1] != f[:, 2]) & (f[:, 0] != f[:, 2])
        f = f[keep]
        s = np.sort(f, axis=1)
        _, first = np.unique(s, axis=0, return_index=True)
        return cid, cp, f[np.sort(first)]

    best = None
    a, b = lo, hi
    for _ in range(iters):
        mid = (a + b) / 2.0
        cid, cp, f = run(mid)
        if len(f) > target:
            a = mid
        else:
            b = mid
            best = (cid, cp, f)
    if best is None:
        best = run(hi)
    cid, cp, f = best
    new_uv = None
    if uv is not None:
        d = np.linalg.norm(pos - cp[cid], axis=1)
        order = np.lexsort((d, cid))
        firsts = np.searchsorted(cid[order], np.arange(len(cp)))
        new_uv = np.asarray(uv)[order[firsts]]
    p2, i2, uv2 = compact(cp, f, new_uv)
    return p2, i2, uv2
