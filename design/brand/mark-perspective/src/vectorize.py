# -*- coding: utf-8 -*-
"""Raster mask -> clean SVG polygons.

Marching squares at iso 0.5, with edge midpoints snapped to a shared lattice so
segments chain into closed loops, then Douglas-Peucker simplification.
"""
import math


def _key(x, y):
    """Snap a marching-squares midpoint to an exact half-integer lattice."""
    return (int(round(x * 2)), int(round(y * 2)))


def contours(mask, w, h):
    """All closed iso-0.5 contours of a boolean mask, as [(x, y), ...]."""
    def at(x, y):
        if 0 <= x < w and 0 <= y < h and mask[y][x]:
            return 1
        return 0

    # ---- collect marching-squares segments keyed by lattice points
    segs = []
    for y in range(-1, h):
        for x in range(-1, w):
            tl = at(x, y)
            tr = at(x + 1, y)
            br = at(x + 1, y + 1)
            bl = at(x, y + 1)
            if tl == tr == br == bl:
                continue
            top = (x + 0.5, y + 0.5)
            bottom = (x + 0.5, y + 1.5)
            left = (x - 0.5, y + 1.0)
            right = (x + 0.5, y + 1.0)
            # --- BUG source: the above lattice is offset; use cell-local midpoints
            # cell corners are at integer coords (x,y)..(x+1,y+1)
            top = (x + 0.5, float(y))
            bottom = (x + 0.5, float(y + 1))
            left = (float(x), y + 0.5)
            right = (float(x + 1), y + 0.5)
            edges = []
            if tl != tr:
                edges.append(top)
            if tr != br:
                edges.append(right)
            if br != bl:
                edges.append(bottom)
            if bl != tl:
                edges.append(left)
            if len(edges) == 2:
                segs.append((edges[0], edges[1]))
            elif len(edges) == 4:
                segs.append((top, right))
                segs.append((bottom, left))

    if not segs:
        return []

    # ---- weld segments at shared lattice points
    adj = {}
    for a, b in segs:
        ka, kb = _key(*a), _key(*b)
        adj.setdefault(ka, []).append((kb, b))
        adj.setdefault(kb, []).append((ka, a))

    used = set()
    loops = []
    seen_sigs = set()
    for a, b in segs:
        ka, kb = _key(*a), _key(*b)
        if (ka, kb) in used:
            continue
        used.add((ka, kb))
        loop = [a, b]
        prev, cur = ka, kb
        while True:
            nxt = None
            for (nk, np_) in adj.get(cur, []):
                if nk == prev:
                    continue
                if (cur, nk) in used:
                    continue
                nxt = (nk, np_)
                break
            if nxt is None:
                break
            nk, np_ = nxt
            used.add((cur, nk))
            loop.append(np_)
            prev, cur = cur, nk
            if nk == _key(*loop[0]):
                break
        if len(loop) >= 4:
            # each boundary is walked twice (once from each direction); with the
            # even-odd fill rule a duplicated loop would cancel itself out, so
            # de-duplicate by a canonical signature
            ks = [_key(*p) for p in loop]
            sig = frozenset(ks)
            if sig in seen_sigs:
                continue
            seen_sigs.add(sig)
            loops.append(loop)
    return loops


def simplify(pts, tol=1.2):
    """Douglas-Peucker, iterative."""
    if len(pts) < 3:
        return pts
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        i0, i1 = stack.pop()
        ax, ay = pts[i0]
        bx, by = pts[i1]
        dx, dy = bx - ax, by - ay
        ln = math.hypot(dx, dy)
        best, idx = -1.0, -1
        for i in range(i0 + 1, i1):
            px, py = pts[i]
            if ln < 1e-9:
                d = math.hypot(px - ax, py - ay)
            else:
                d = abs(dy * (px - ax) - dx * (py - ay)) / ln
            if d > best:
                best, idx = d, i
        if best > tol and idx > 0:
            keep[idx] = True
            stack.append((i0, idx))
            stack.append((idx, i1))
    return [p for p, k in zip(pts, keep) if k]
