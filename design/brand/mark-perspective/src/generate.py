# -*- coding: utf-8 -*-
"""Rebuild mark-5 / mark-6 in image 3's perspective, keeping the source colours.

The perspective is a real 3D camera: image 3's outer ring fits an ellipse of
axis ratio ~0.87 and its star tips span 605..890 px (1.47x near/far).  For a
tilted plane seen by a pinhole camera,

    axis ratio    = cos(tilt)
    near/far gain = (D + sin tilt) / (D - sin tilt)

so tilt = 28 deg, D = 4 reproduces both.  That is the "perspective relation"
of image 3, applied to the source artwork.

Colour: each of the source's flat colours is projected and traced as its
own layer, emitted in source document order, so palette and z-order survive.

The three petal colours are excluded (DROP_COLOURS): the brief asked for the
three leaf shapes around the centre bud to be removed.
"""
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import vectorize as VZ

ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.abspath(os.path.join(HERE, "..", "svg"))
WORK = os.path.abspath(os.path.join(HERE, "..", "_work"))

CANVAS = 2048.0
SS = 1000
THICKEN = 9.0

# Colours removed before projection.
#   #F5C2FB / #F09AF7 / #EE7EF9  the <g class="petals"> group: the three leaf
#                                shapes around the centre bud
#   #F796FF                      the <g class="dot"> group: the centre pink dot
# Each of these colours occurs exactly once in both source marks, so dropping
# the colour drops exactly that shape and nothing else.
# (The centre diamond core is NOT dropped: it is painted #9DBFE6, the same ink
#  as the outer ring arcs, so it cannot be removed by colour.)
DROP_COLOURS = ("#F5C2FB", "#F09AF7", "#EE7EF9", "#F796FF")

# The interlaced tape body around the centre.  These four colours are exactly
# the <g class="arcs"> group (three tapes plus the white separators), so they
# identify that ring of shapes and nothing else.
CORE_COLOURS = ("#FFFAFB", "#FCD8FF", "#F9B0FF", "#F17EB3")

# Ink of the source's small centre diamond.  Its traced outline used to be
# emitted as its own shape; it is not any more (see DROP_CORE_DIAMOND).  The
# ink still names the source colour, and still paints the outer ring.
CORE_INK = "#9DBFE6"

# Drop the centre diamond from the colour pass.  build_triangle_overlay() paints
# a triangle that already fills the pocket, so the diamond underneath only ever
# showed as a darker sliver along two of the triangle's edges - it read as a
# stray extra shape, not as part of the mark.  The filter is by radius so it
# cannot touch the ring arcs, which share the ink but sit far outside.
DROP_CORE_DIAMOND = True
CORE_DIAMOND_R = 300.0      # canvas px from the emblem centre: diamond ~110, ring ~570+

# Ink of the centre triangle.  Was CORE_INK; lightened one step on the ice ramp
# so the figure reads as a pale backing plate behind the pink interlace instead
# of a dark mass in the middle of it.
TRIANGLE_INK = "#BDD4E9"

# The two pinks of the interlace trade places on output: the colour that used
# to paint the large body / lower-left band (#FCD8FF) now paints the upper wing
# and the lower-right shard, and vice versa.  Applied by swapping the fill of
# the two layers after they are emitted.
SWAP_PINKS = ("#FCD8FF", "#F9B0FF")

# The outer ring (arcs + dots) is traced from its own group and painted on top,
# so it is excluded from the normal colour layers.
# #9DBFE6 paints the outer ring arcs AND the centre diamond core, so it cannot
# be dropped wholesale - the ring is traced from its own group and appended on
# top instead, and the normal colour pass keeps the diamond core.
RING_ONLY = ()
RING_INK = "#9DBFE6"

# How much to enlarge that body, about the emblem centre (1.0 = unchanged).
# The enlargement happens at sampling time, so the tapes keep their interlock
# at any factor.  1.32 was chosen from a measured sweep: at that factor 95% of
# the hexagram's star-line pixels and 97% of the pentagram's are still visible
# (at 1.48 they drop to 51% / 77%).
CORE_SCALE = 1.32

TILT = math.radians(28.0)
YAW = math.radians(-10.0)
ROLL = math.radians(-8.0)
DIST = 4.0
R_SRC = 232.0
FIT = 0.44
SRC_PX = 512.0


def _mul(A, B):
    return [[sum(A[i][k] * B[k][j] for k in range(3)) for j in range(3)] for i in range(3)]


def _rot():
    ca, sa = math.cos(TILT), math.sin(TILT)
    cb, sb = math.cos(YAW), math.sin(YAW)
    cc, sc = math.cos(ROLL), math.sin(ROLL)
    Rx = [[1, 0, 0], [0, ca, -sa], [0, sa, ca]]
    Ry = [[cb, 0, sb], [0, 1, 0], [-sb, 0, cb]]
    Rz = [[cc, -sc, 0], [sc, cc, 0], [0, 0, 1]]
    return _mul(Rz, _mul(Ry, Rx))


R = _rot()


def project(x, y):
    ex, ey = (x - 256.0) / R_SRC, (y - 256.0) / R_SRC
    q0 = R[0][0] * ex + R[0][1] * ey
    q1 = R[1][0] * ex + R[1][1] * ey
    q2 = R[2][0] * ex + R[2][1] * ey
    f = DIST / (DIST - q2)
    return q0 * f, q1 * f


def _frame():
    pts = [project(256 + R_SRC * math.cos(2 * math.pi * i / 96),
                   256 + R_SRC * math.sin(2 * math.pi * i / 96)) for i in range(96)]
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    cx = (min(xs) + max(xs)) / 2.0
    cy = (min(ys) + max(ys)) / 2.0
    r = max(max(abs(x - cx), abs(y - cy)) for x, y in pts)
    return CANVAS * FIT / r, cx, cy


K_GLOBAL, CX_GLOBAL, CY_GLOBAL = _frame()


def scale_core_paths(svg, k, cx=256.0, cy=256.0):
    """Enlarge the interlaced tape body about (cx, cy).

    The three tapes occlude each other through the <mask> elements in <defs>,
    so the mask paths have to be scaled by the same factor - otherwise the
    tapes would grow but their cut-outs would stay put.
    """
    import re as _re

    def scale_d(d):
        toks = _re.findall(r"[A-Za-z]|[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?", d)
        out = []
        cmd = None
        i = 0
        while i < len(toks):
            t = toks[i]
            if t.isalpha():
                cmd = t
                out.append(t)
                i += 1
                continue
            if cmd in ("M", "L"):
                x = float(toks[i]); y = float(toks[i + 1]); i += 2
                out.append("%.2f %.2f" % (cx + (x - cx) * k, cy + (y - cy) * k))
            elif cmd == "A":
                rx = float(toks[i]); ry = float(toks[i + 1]); rot = float(toks[i + 2])
                la = toks[i + 3]; sw = toks[i + 4]
                x = float(toks[i + 5]); y = float(toks[i + 6]); i += 7
                out.append("%.2f %.2f %.2f %s %s %.2f %.2f" % (
                    rx * k, ry * k, rot, la, sw,
                    cx + (x - cx) * k, cy + (y - cy) * k))
            else:
                i += 1
        return " ".join(out)

    def repl(m):
        return ' d="%s"' % scale_d(m.group(1))

    head, sep, tail = svg.partition("</defs>")
    if not sep:
        head, tail = "", svg
    def scale_sw(m):
        return ' stroke-width="%.2f"' % (float(m.group(1)) * k)

    # Mask paths live in <defs> and must grow with the art, stroke-width
    # included: the mask's stroked path *is* the gap between interlocking
    # tapes, so scaling it uniformly keeps the interlock coherent.
    head = _re.sub(r'\sd="([^"]*)"', repl, head)
    head = _re.sub(r' stroke-width="([\d.]+)"', scale_sw, head)

    m = _re.search(r'<g class="arcs">(.*?)</g>', tail, _re.S)
    if m:
        scaled = _re.sub(r'\sd="([^"]*)"', repl, m.group(0))
        # the white separators are strokes, so their width has to grow with the
        # tapes - otherwise the gaps they carve get relatively thinner and the
        # tapes stop reading as one interlocked body
        scaled = _re.sub(r' stroke-width="([\d.]+)"', scale_sw, scaled)
        tail = tail[:m.start()] + scaled + tail[m.end():]

    # masks clip to a fixed user-space rect; grow it so the scaled art is not cut
    def grow_rect(m):
        return ('<rect width="%d" height="%d"' % (512 * k, 512 * k)).replace(
            '<rect', '<rect x="%.2f"' % (0)) 
    return head + sep + tail


def reorder_layers(layers, name):
    """Move the outer ring above the interlaced tape body.

    Two colours are shared between elements:
      #BDD4E9  star lines  AND  the ring dots
      #9DBFE6  ring arcs   AND  the centre diamond core
    so each is split by distance from the emblem centre before re-ordering.
    """
    import math as _m

    # canvas-space split radius: the star lines live at r ~390..460, the ring
    # dots and arcs at r ~540..715, and the centre diamond core at r ~140
    OUT_R = 500.0

    def centroid_r(poly):
        """Distance of the polygon's centroid from the emblem centre.

        Must use the centroid POSITION, not the mean of the vertex radii: the
        star lines are long chords whose vertices average out to a large radius
        even though the line itself passes through the middle.
        """
        if not poly:
            return 0.0
        cx = sum(p[0] for p in poly) / len(poly)
        cy = sum(p[1] for p in poly) / len(poly)
        return _m.hypot(cx - 256.0, cy - 256.0)

    bottom, keep, ring = [], [], []
    for colour, polys in layers:
        if colour in ("#BDD4E9", "#9DBFE6"):
            near, far = [], []
            for p in polys:
                (far if centroid_r(p) > OUT_R else near).append(p)
            if near:
                # the near group can mix the star lines with the centre diamond
                # core, so it goes to the bottom (painted first)
                bottom.append((colour, near))
            if far:
                ring.append((colour, far))
        else:
            keep.append((colour, polys))
    return bottom + keep + ring


def palette_order(path):
    txt = open(path, encoding="utf-8").read()
    seen = []
    for m in re.finditer(r"#[0-9A-Fa-f]{6}", txt):
        c = m.group(0).upper()
        if c not in seen:
            seen.append(c)
    return seen


def isolate_group(svg_path, group, dst, colours=None):
    """Copy of the svg where only <g class="group"> keeps its paint.

    Colours shared with other groups (the star lines use the same ink as the
    ring dots) are disambiguated by group membership, which is exact.
    """
    _re = re
    txt = open(svg_path, encoding="utf-8").read()
    # blank everything outside the requested group
    parts = []
    pos = 0
    for m in _re.finditer(r'<g class="([\w-]+)">', txt):
        cls = m.group(1)
        start = m.end()
        depth = 1
        i = start
        end = len(txt)
        while i < len(txt) and depth > 0:
            nxt_o = txt.find("<g", i)
            nxt_c = txt.find("</g>", i)
            if nxt_c == -1:
                break
            if nxt_o != -1 and nxt_o < nxt_c:
                depth += 1
                i = nxt_o + 2
            else:
                depth -= 1
                if depth == 0:
                    end = nxt_c
                i = nxt_c + 4
        parts.append((cls, m.start(), end))
    keep = [(s, e) for c, s, e in parts if c == group]
    if not keep:
        open(dst, "w", encoding="utf-8").write(txt)
        return dst
    ks, ke = keep[0]
    head, sep, tail = txt.partition("</defs>")
    body = txt[ke + 4:len(tail) - 0] if False else None
    # rebuild: defs + only the requested group, everything else dropped
    inner = txt[ks:ke + 4]
    if colours:
        def keep_col(m):
            attr, val = m.group(1), m.group(2)
            return m.group(0) if val.upper() in colours else '%s="none"' % attr
        inner = _re.sub(r'(fill|stroke)="(#[0-9A-Fa-f]{6})"', keep_col, inner)
    with open(dst, "w", encoding="utf-8") as f:
        f.write(head + sep + inner + "</svg>")
    return dst


def isolate(svg_path, colour, dst):
    txt = open(svg_path, encoding="utf-8").read()
    head, sep, tail = txt.partition("</defs>")
    if not sep:
        head, tail = "", txt

    def keep(m):
        attr, val = m.group(1), m.group(2)
        return m.group(0) if val.upper() == colour else '%s="none"' % attr

    tail = re.sub(r'(fill|stroke)="(#[0-9A-Fa-f]{6})"', keep, tail)
    with open(dst, "w", encoding="utf-8") as f:
        f.write(head + sep + tail)
    return dst

def render_layer_svg(tmp, png_path):
    """Rasterise a prepared single-layer svg, scaled to fill the frame."""
    import subprocess
    svg = open(tmp, encoding="utf-8").read()
    svg = re.sub(r'width="[^"]*"\s+height="[^"]*"', 'width="1400" height="1400"', svg, count=1)
    html = ('<!doctype html><meta charset="utf-8">'
            '<style>html,body{margin:0;padding:0;width:1400px;height:1400px;'
            'background:#000;overflow:hidden}svg{width:1400px;height:1400px;display:block}</style>'
            + svg)
    hp = os.path.join(WORK, "_layer.html")
    open(hp, "w", encoding="utf-8").write(html)
    subprocess.run([r"C:\Program Files\Google\Chrome\Application\chrome.exe",
                    "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    "--default-background-color=000000ff",
                    "--screenshot=" + png_path, "--window-size=1400,1400",
                    "file:///" + hp.replace("\\", "/")],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return png_path


def render_layer(svg_path, colour, png_path):
    import subprocess
    tmp = os.path.join(WORK, "_layer.svg")
    isolate(svg_path, colour, tmp)
    svg = open(tmp, encoding="utf-8").read()
    svg = re.sub(r'width="[^"]*"\s+height="[^"]*"', 'width="1400" height="1400"', svg, count=1)
    # NOTE: the core body is enlarged in the sampling stage (see warp_layer),
    # not by editing this SVG - scaling the paths here would break the mask
    # interlock between the three tapes.
    for dead in DROP_COLOURS:
        svg = re.sub(r'fill="%s"' % re.escape(dead), 'fill="none"', svg, flags=re.I)
    html = ('<!doctype html><meta charset="utf-8">'
            '<style>html,body{margin:0;padding:0;width:1400px;height:1400px;'
            'background:#000;overflow:hidden}svg{width:1400px;height:1400px;display:block}</style>'
            + svg)
    hp = os.path.join(WORK, "_layer.html")
    open(hp, "w", encoding="utf-8").write(html)
    subprocess.run([r"C:\Program Files\Google\Chrome\Application\chrome.exe",
                    "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    "--default-background-color=000000ff",
                    "--screenshot=" + png_path, "--window-size=1400,1400",
                    "file:///" + hp.replace("\\", "/")],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return png_path


def warp_layer(png_path, magnify=1.0):
    import numpy as np
    from PIL import Image, ImageFilter

    im = Image.open(png_path).convert("RGB")
    a = np.asarray(im).astype(np.int16)
    src = a.max(axis=2) > 40
    h, w = src.shape
    s = w / SRC_PX

    gy, gx = np.mgrid[0:SS, 0:SS]
    U = gx * (CANVAS / float(SS))
    V = gy * (CANVAS / float(SS))
    pu = (U - CANVAS / 2.0) / K_GLOBAL + CX_GLOBAL
    pv = (V - CANVAS / 2.0) / K_GLOBAL + CY_GLOBAL
    a11 = R[0][0] + (pu / DIST) * R[2][0]
    a12 = R[0][1] + (pu / DIST) * R[2][1]
    a21 = R[1][0] + (pv / DIST) * R[2][0]
    a22 = R[1][1] + (pv / DIST) * R[2][1]
    det = a11 * a22 - a12 * a21
    det = np.where(np.abs(det) < 1e-12, 1e-12, det)
    ex = (a22 * pu - a12 * pv) / det
    ey = (-a21 * pu + a11 * pv) / det
    # magnification about the emblem centre, done in source space so the
    # artwork is resampled rather than re-cut
    if magnify != 1.0:
        ex = ex / magnify
        ey = ey / magnify
    PX = (ex * R_SRC + 256.0) * s
    PY = (ey * R_SRC + 256.0) * s
    inside = (PX >= 0) & (PX < w - 1) & (PY >= 0) & (PY < h - 1)
    mask = np.zeros((SS, SS), bool)
    xi = np.clip(PX, 0, w - 1).astype(int)
    yi = np.clip(PY, 0, h - 1).astype(int)
    mask[inside] = src[yi[inside], xi[inside]]

    if THICKEN > 0:
        rad = THICKEN * SS / CANVAS
        if rad > 0.4:
            img = Image.fromarray((mask * 255).astype(np.uint8))
            img = img.filter(ImageFilter.GaussianBlur(radius=rad))
            mask = np.asarray(img) > 96

    loops = VZ.contours(mask.tolist(), SS, SS)
    scale = CANVAS / float(SS)
    polys = []
    for loop in loops:
        pts = [(x * scale, y * scale) for x, y in loop]
        pts = VZ.simplify(pts, tol=1.8)
        if len(pts) >= 3:
            polys.append(pts)
    return polys


def build_star_overlay(mark_svg):
    """Trace the star-line group on its own, to be painted beneath everything.

    The star lines use the same ink as the ring dots, so they cannot be
    separated by colour - they are separated by group instead.
    """
    tmp = os.path.join(WORK, "_star.svg")
    isolate_group(mark_svg, "star", tmp, colours={"#BDD4E9"})
    png = os.path.join(WORK, "_star.png")
    render_layer_svg(tmp, png)
    return warp_layer(png)


def core_diamond(mark_svg, grow=1.55):
    """Centre + half-extents of the source diamond, in canvas space.

    This is pure geometry: it locates the middle pocket of the interlaced body
    after projection.  Nothing is painted with it any more - a diamond drawn
    there would sit under the triangle and only show as a stray sliver.
    """
    K, CX, CY = K_GLOBAL, CX_GLOBAL, CY_GLOBAL

    def proj(x, y):
        u, v = project(x, y)
        return ((u - CX) * K + CANVAS / 2.0, (v - CY) * K + CANVAS / 2.0)

    # the four source diamond corners, projected
    corners = [proj(256.0, 278.0), proj(226.0, 256.0),
               proj(256.0, 234.0), proj(286.0, 256.0)]
    cx = sum(p[0] for p in corners) / 4.0
    cy = sum(p[1] for p in corners) / 4.0
    rx = (max(p[0] for p in corners) - min(p[0] for p in corners)) / 2.0 * grow
    ry = (max(p[1] for p in corners) - min(p[1] for p in corners)) / 2.0 * grow
    return cx, cy, rx, ry


def build_triangle_overlay(mark_svg, grow=2.2):
    """The centre triangle that fills the middle pocket.

    The source core is a small diamond.  Once the interlaced tapes are
    enlarged (CORE_SCALE) the pocket around it widens, so the diamond no
    longer reaches the walls and reads as a triangle with two corners cut
    off.  The core is therefore emitted as one explicit triangle, centred
    where the diamond sat and big enough to meet the tape edges, painted under
    the tapes so they clip it to the pocket.
    """
    cx, cy, rx, ry = core_diamond(mark_svg, grow)
    # upward-pointing triangle inscribed in that ellipse
    return [[(cx, cy - ry),
             (cx - rx * 0.93, cy + ry * 0.80),
             (cx + rx * 0.93, cy + ry * 0.80)]]


def build_ring_overlay(mark_svg):
    """Trace the outer ring group on its own, to be painted above everything.

    The ring arcs and dots use the same inks as the star lines, so it cannot be
    separated by colour - it is separated by group instead.
    """
    tmp = os.path.join(WORK, "_ring.svg")
    isolate_group(mark_svg, "ring-blocks", tmp, colours={"#BDD4E9", "#9DBFE6"})
    png = os.path.join(WORK, "_ring.png")
    render_layer_svg(tmp, png)
    return warp_layer(png)


def _is_core_diamond(poly):
    """True for the small centre diamond, judged by distance from the centre.

    The star lines and the outer ring arcs share CORE_INK but live at r ~570+
    on the canvas; the diamond sits at r ~110.  A radius test therefore
    separates it without pinning the generator to one traced outline.
    """
    if not poly:
        return False
    cx = sum(p[0] for p in poly) / len(poly)
    cy = sum(p[1] for p in poly) / len(poly)
    r = math.hypot(cx - CANVAS / 2.0, cy - CANVAS / 2.0)
    return r < CORE_DIAMOND_R


def swap_pinks(layers):
    """Exchange the fills of SWAP_PINKS, keeping the geometry untouched.

    The two pinks are single flat layers, so swapping which one paints which
    shape is just a rename - no re-tracing, no z-order change.
    """
    a, b = SWAP_PINKS
    out = []
    for colour, polys in layers:
        if colour == a:
            out.append((b, polys))
        elif colour == b:
            out.append((a, polys))
        else:
            out.append((colour, polys))
    return out


def build(mark_svg, out_svg, name, body_only=False):
    os.makedirs(WORK, exist_ok=True)
    cols = [c for c in palette_order(mark_svg)
            if c not in DROP_COLOURS and c not in RING_ONLY]
    print(name, "colours:", len(cols))
    layers = []
    for i, c in enumerate(cols):
        png = os.path.join(WORK, "%s-%02d.png" % (name, i))
        render_layer(mark_svg, c, png)
        polys = warp_layer(png, CORE_SCALE if c in CORE_COLOURS else 1.0)
        if DROP_CORE_DIAMOND and c == CORE_INK:
            polys = [p for p in polys if not _is_core_diamond(p)]
        print("   ", c, "contours:", len(polys))
        if polys:
            layers.append((c, polys))
    layers = swap_pinks(layers)

    parts = [
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 2048 2048" '
        'width="2048" height="2048" role="img" aria-labelledby="ttl">',
        '<title id="ttl">Ayla %s - image-3 perspective</title>' % name,]
    # The centre triangle is drawn large and placed UNDER the tape body: the
    # tapes then clip it, so whatever shows through fills the central pocket
    # exactly.  Only the triangle is emitted - the source diamond it replaces
    # is not painted any more.
    tri = build_triangle_overlay(mark_svg, grow=2.2)
    if tri:
        d = " ".join("M" + " L".join("%.1f %.1f" % q for q in p) + " Z" for p in tri)
        parts.append('<path fill="%s" fill-rule="evenodd" d="%s"/>' % (TRIANGLE_INK, d))

    STAR_INKS = ("#BDD4E9",)
    RING_R = 540.0          # canvas px: anything beyond this is ring, not body

    def _is_ring(poly):
        if not poly:
            return True
        cx = sum(p[0] for p in poly) / len(poly)
        cy = sum(p[1] for p in poly) / len(poly)
        return ((cx - CANVAS / 2.0) ** 2 + (cy - CANVAS / 2.0) ** 2) ** 0.5 > RING_R

    for c, polys in layers:
        if body_only and c in STAR_INKS:
            continue
        if body_only:
            polys = [p for p in polys if not _is_ring(p)]
            if not polys:
                continue
        d = " ".join("M" + " L".join("%.1f %.1f" % q for q in p) + " Z" for p in polys)
        parts.append('<path fill="%s" fill-rule="evenodd" d="%s"/>' % (c, d))

    # the outer ring is painted last so it sits above the tape body
    ring_polys = [] if body_only else build_ring_overlay(mark_svg)
    if ring_polys:
        d = " ".join("M" + " L".join("%.1f %.1f" % q for q in p) + " Z" for p in ring_polys)
        parts.append('<path fill="%s" fill-rule="evenodd" d="%s"/>' % (RING_INK, d))
    parts.append("</svg>")
    svg = chr(10).join(parts)
    os.makedirs(os.path.dirname(out_svg), exist_ok=True)
    # newline="" keeps the emitted LF on every platform: without it Python
    # rewrites every break to CRLF on Windows and the whole file shows up as a
    # one-line diff in a repository that stores these SVGs with LF.
    with open(out_svg, "w", encoding="utf-8", newline="") as f:
        f.write(svg)
    return svg


# Three deliverables, and only three:
#
#   logo-max.svg        largest square that still holds all the ink, so the
#                       artwork fills the file - nothing may be trimmed tighter
#                       without cutting the mark
#   logo.svg            1550 square, transparent - THE DEFAULT
#   logo-on-pink.svg    1550 square, opaque #FFB4E1 - only where transparency
#                       is a problem (iOS icons reject alpha, dark backdrops)
#
# No file carries a corner radius: the square is deliberate, the OS or the
# surrounding CSS applies whatever mask is wanted.
#
# 1550 was picked by eye at true 56px launcher scale (1450 read as
# edge-to-edge, 1880 as too small next to neighbouring icons).
LOGO_SIDE = 1550.0
LOGO_BG = "#FFB4E1"

def build_logo(out_svg, bg=None, side=None):
    """Crop the body mark to its ink and write it as the Ayla logo.

    The pipeline canvas is a 2048 square, but the artwork only covers 68% x
    58% of it, so using the file as-is leaves a wide empty border and the mark
    reads small wherever it is placed. Cropping to a square around the ink
    removes that padding.

    side=None means MAXIMUM CROP: the smallest square that still contains every
    ink vertex, i.e. max(ink width, ink height) = 1390.6. That is the largest
    the mark can be drawn without the file's own bounds cutting it, and it is
    what the max-crop deliverable uses. Anything tighter would clip.

    side=LOGO_SIDE (1550) is the shared size for the transparent and the pink
    logo. Why 1550 rather than the tight 1391: the mark's aspect is 1.16:1, so
    left/right air is necessarily smaller than top/bottom air - that is
    geometry, not tuning. The only hard rule when a mask is applied is that no
    ink may fall outside it: the farthest ink vertex is 707.9 from the centre
    and a circular mask has radius side/2, so any side >= 1416 survives a full
    circle uncut. 1550 clears that with room to spare (ink radius 91.3% of the
    half-side) while keeping the mark big - longest ink edge fills 89.7% of the
    tile, 5.1% air left and right. 1450 was rejected as edge-to-edge, 1880 as
    visibly too small next to real icons; both judged at true 56px scale.

    Do NOT read the PWA "maskable" 80% rule as a general requirement. That 80%
    figure exists because a maskable PWA icon may be masked into ANY shape by
    the OS, so it asks for a deep margin; an ordinary launcher icon only needs
    to not be clipped. If a maskable PWA icon is ever needed, add a separate
    even-padded variant rather than shrinking the shared one.

    No rounded corners are drawn: the square is intentional, the OS applies
    whatever corner mask it wants.

    bg paints an opaque background rect; None keeps the file transparent.
    """
    svg = open(os.path.join(OUT, "mark-5-body.svg"), encoding="utf-8").read()
    # whole <path .../> elements, closing slash included - matching only up to
    # d="..." would emit unclosed elements and the file would not parse
    polys = re.findall(r'<path [^>]*?/>', svg)
    if not polys:
        raise SystemExit("no <path> elements found in %s" % body)
    pts = [(float(a), float(b)) for a, b in
           re.findall(r'([-\d.]+) ([-\d.]+)', " ".join(re.findall(r' d="([^"]*)"', svg)))]
    xs = [q[0] for q in pts]
    ys = [q[1] for q in pts]
    cx = (min(xs) + max(xs)) / 2.0
    cy = (min(ys) + max(ys)) / 2.0
    if side is None:
        # maximum crop: the smallest square that still holds every ink vertex,
        # so the mark fills the file as far as it can without being cut
        side = max(max(xs) - min(xs), max(ys) - min(ys))
    x = cx - side / 2.0
    y = cy - side / 2.0

    parts = [
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="%.2f %.2f %.2f %.2f" '
        'role="img" aria-labelledby="ttl">' % (x, y, side, side),
        '<title id="ttl">Ayla</title>',
        '<desc>Ayla 标识（mark-5 body）：中心三角 + 三段互锁环形。</desc>',
    ]
    if bg:
        parts.append('<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" fill="%s"/>'
                     % (x, y, side, side, bg))
    parts.extend(polys)
    parts.append("</svg>")
    out = chr(10).join(parts)
    os.makedirs(os.path.dirname(out_svg), exist_ok=True)
    with open(out_svg, "w", encoding="utf-8", newline="") as fh:
        fh.write(out)
    return out


OUT = os.path.abspath(os.path.join(HERE, "..", "svg"))
def main():
    for mark in ("mark-6", "mark-5"):
        build(os.path.join(ROOT, mark + ".svg"),
              os.path.join(OUT, mark + "-perspective.svg"), mark)
    print("done")


if __name__ == "__main__":
    main()

def main_body():
    """Emit the centre-only variants (no star lines, no outer ring)."""
    for mark in ("mark-6", "mark-5"):
        build(os.path.join(ROOT, mark + ".svg"),
              os.path.join(OUT, mark + "-body.svg"), mark, body_only=True)
    print("done body")




def main_logo():
    """Emit the cropped Ayla logo files from the body mark.

    mark-5-body.svg stays the full 2048 canvas (it documents the projection
    frame); the logo files are derived from it and are what anything visual
    should reference.
    """
    body = os.path.join(OUT, "mark-5-body.svg")
    if not os.path.exists(body):
        raise SystemExit("run main_body() first: %s is missing" % body)
    # HERE = Ayla/design/brand/mark-perspective/src -> four levels up is Ayla/
    repo = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
    # Exactly three SVGs, each with one job. Transparent is the default; the
    # pink one exists only for places that cannot take transparency (iOS app
    # icons reject alpha, and the pale-blue/white layers need a backing colour
    # on dark surfaces). No corner radius anywhere - the square is deliberate.
    targets = [
        # largest square that still contains all the ink (side=None -> max)
        (os.path.join(repo, "design", "brand", "logo-max.svg"), None, None),
        (os.path.join(repo, "web", "public", "brand", "logo-max.svg"), None, None),
        # the default logo
        (os.path.join(repo, "design", "brand", "logo.svg"), None, LOGO_SIDE),
        (os.path.join(repo, "web", "public", "brand", "logo.svg"), None, LOGO_SIDE),
        # opaque variant, only on request
        (os.path.join(repo, "design", "brand", "logo-on-pink.svg"), LOGO_BG, LOGO_SIDE),
        (os.path.join(repo, "web", "public", "brand", "logo-on-pink.svg"), LOGO_BG, LOGO_SIDE),
    ]
    outs = []
    for path, bg, side in targets:
        build_logo(path, bg=bg, side=side)
        outs.append((path, open(path, "rb").read()))
        print("   ", os.path.relpath(path, repo), len(outs[-1][1]), "bytes")
    a = {p: b for p, b in outs}
    # each repo file must match its web/public twin (outs are in target order)
    pairs = [(0, 1), (2, 3), (4, 5)]
    same = all(a[targets[i][0]] == a[targets[j][0]] for i, j in pairs)
    print("done logo, repo/web copies identical:", same)


if __name__ == "__main__":
    main()
    main_body()
    main_logo()
