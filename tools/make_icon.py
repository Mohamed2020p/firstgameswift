# -*- coding: utf-8 -*-
"""
Generates the SUPERCARS app icon: 1024x1024 RGB PNG (no alpha) in the c0derz identity
(neon green #39FF88 + magenta #FF2BD6 on near-black, `</>` motif, stylised supercar).

    python tools/make_icon.py            # writes Supercars/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png

Requires Pillow + numpy.  Everything is drawn at 2x and downsampled for clean edges.
"""
import math
import os

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "Supercars", "Resources", "Assets.xcassets", "AppIcon.appiconset", "AppIcon-1024.png")

S = 2                      # supersampling factor
SIZE = 1024 * S
GREEN = (57, 255, 136)
MAGENTA = (255, 43, 214)
CYAN = (43, 230, 255)
INK = (5, 6, 10)


def sp(x, y):
    """icon-space (1024) -> canvas pixel"""
    return (x * S, y * S)


# ---------------------------------------------------------------- car geometry (unit space, y down, ground = 290)
CAR_X0 = 78.0
CAR_SCALE = 0.90
CAR_GROUND = 822.0


def cp(ux, uy):
    return sp(CAR_X0 + ux * CAR_SCALE, CAR_GROUND + (uy - 290.0) * CAR_SCALE)


def catmull(points, samples=14):
    """Catmull-Rom spline through points (open)."""
    out = []
    pts = [points[0]] + list(points) + [points[-1]]
    for i in range(1, len(pts) - 2):
        p0, p1, p2, p3 = pts[i - 1], pts[i], pts[i + 1], pts[i + 2]
        for s in range(samples):
            t = s / float(samples)
            t2, t3 = t * t, t * t * t
            x = 0.5 * ((2 * p1[0]) + (-p0[0] + p2[0]) * t + (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * t2 + (-p0[0] + 3 * p1[0] - 3 * p2[0] + p3[0]) * t3)
            y = 0.5 * ((2 * p1[1]) + (-p0[1] + p2[1]) * t + (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2 + (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3)
            out.append((x, y))
    out.append(points[-1])
    return out


UPPER = [(26, 214), (34, 190), (70, 168), (150, 152), (250, 135), (330, 108), (410, 80), (500, 72), (580, 92),
         (640, 128), (730, 150), (860, 166), (950, 186), (990, 214), (993, 236)]
BODY_POLY_UNIT = catmull(UPPER) + [(985, 246), (40, 248), (24, 236)]
WHEELS = [(255.0, 232.0, 55.0), (765.0, 232.0, 55.0)]     # cx, cy, r  (unit space)
ARCH_R = 67.0
GLASS_UNIT = catmull([(335, 133), (415, 95), (498, 87), (562, 102), (616, 134)], 10) + [(470, 133)]


def to_canvas(poly):
    return [cp(x, y) for (x, y) in poly]


# ---------------------------------------------------------------- helpers
def vertical_gradient(top, bottom, y0, y1):
    """full-canvas RGB image with a vertical colour ramp between y0..y1 (canvas px)"""
    ys = np.arange(SIZE, dtype=np.float32)
    t = np.clip((ys - y0) / max(1.0, (y1 - y0)), 0.0, 1.0)
    arr = np.zeros((SIZE, SIZE, 3), dtype=np.uint8)
    for c in range(3):
        col = top[c] + (bottom[c] - top[c]) * t
        arr[:, :, c] = col.astype(np.uint8)[:, None]
    return Image.fromarray(arr)


def glow_add(base, layer, radius, strength=1.0, crisp=True):
    """adds `layer` (black background RGB) to base with a gaussian glow"""
    glow = layer.filter(ImageFilter.GaussianBlur(radius * S))
    if strength != 1.0:
        glow = glow.point(lambda v: min(255, int(v * strength)))
    out = ImageChops.add(base, glow)
    if crisp:
        out = ImageChops.add(out, layer)
    return out


def new_layer():
    return Image.new("RGB", (SIZE, SIZE), (0, 0, 0))


def thick_line(draw, pts, width, fill):
    """polyline with round joints/caps"""
    w = width * S
    draw.line(pts, fill=fill, width=int(w), joint="curve")
    r = w / 2.0
    for (x, y) in (pts[0], pts[-1]):
        draw.ellipse([x - r, y - r, x + r, y + r], fill=fill)


def background():
    n = 1024
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float32)
    xn = xx / n
    yn = yy / n
    base = np.zeros((n, n, 3), dtype=np.float32)
    base[:] = np.array(INK, dtype=np.float32)
    # subtle vertical lift toward the bottom
    base += (yn[:, :, None] * np.array([6, 4, 14], dtype=np.float32))

    def blob(cx, cy, rad, colour, gain):
        d = np.sqrt((xn - cx) ** 2 + (yn - cy) ** 2) / rad
        f = np.exp(-(d ** 2) * 2.2) * gain
        return f[:, :, None] * np.array(colour, dtype=np.float32)

    base += blob(0.08, 0.95, 0.60, GREEN, 0.60)       # green glow bottom-left
    base += blob(0.95, 0.08, 0.60, MAGENTA, 0.65)     # magenta glow top-right
    base += blob(0.50, 0.30, 0.42, (70, 40, 160), 0.22)  # violet core behind the </>
    # vignette
    d = np.sqrt((xn - 0.5) ** 2 + (yn - 0.5) ** 2)
    base *= (1.0 - 0.45 * np.clip(d - 0.35, 0, 1))[:, :, None]
    img = Image.fromarray(np.clip(base, 0, 255).astype(np.uint8))
    return img.resize((SIZE, SIZE), Image.BICUBIC)


def draw_floor(base):
    """perspective neon grid under the car"""
    layer = new_layer()
    d = ImageDraw.Draw(layer)
    horizon = 822.0
    vx = 512.0
    # radial lines
    for i in range(-14, 15):
        x_bottom = vx + i * 120.0
        col = MAGENTA if i % 2 == 0 else GREEN
        col = tuple(int(c * 0.42) for c in col)
        d.line([sp(vx + i * 14.0, horizon), sp(x_bottom, 1040)], fill=col, width=2 * S)
    # horizontal lines (denser toward the horizon)
    for k in range(1, 9):
        t = (k / 8.0) ** 1.8
        y = horizon + t * 230.0
        col = tuple(int(c * (0.20 + 0.4 * t)) for c in MAGENTA)
        d.line([sp(0, y), sp(1024, y)], fill=col, width=2 * S)
    # fade in below the horizon so the car sits on it
    ys = np.arange(SIZE, dtype=np.float32)
    t = np.clip((ys - horizon * S) / (70.0 * S), 0.0, 1.0)
    m = Image.fromarray((np.repeat(t[:, None], SIZE, axis=1) * 255).astype(np.uint8))
    layer = ImageChops.multiply(layer, Image.merge("RGB", (m, m, m)))
    return glow_add(base, layer, 3, 0.8, True)


def draw_car(base):
    # ---- ground glow (underglow) ------------------------------------------------
    under = new_layer()
    d = ImageDraw.Draw(under)
    ex0 = cp(60, 300)
    ex1 = cp(960, 340)
    d.ellipse([ex0[0], ex0[1] - 10 * S, ex1[0], ex1[1]], fill=(60, 10, 60))
    under = under.filter(ImageFilter.GaussianBlur(26 * S))
    base = ImageChops.add(base, under)
    under2 = new_layer()
    d = ImageDraw.Draw(under2)
    e0 = cp(140, 290)
    e1 = cp(880, 318)
    d.ellipse([e0[0], e0[1], e1[0], e1[1]], fill=(0, 90, 50))
    under2 = under2.filter(ImageFilter.GaussianBlur(14 * S))
    base = ImageChops.add(base, under2)

    # ---- speed lines ---------------------------------------------------------------
    lines = new_layer()
    d = ImageDraw.Draw(lines)
    for (y, x0, x1, col) in [(196, -160, 10, MAGENTA), (222, -240, 4, GREEN), (170, -120, 24, GREEN), (246, -190, 0, MAGENTA)]:
        a = cp(x0, y)
        b = cp(x1, y)
        d.line([a, b], fill=tuple(int(c * 0.75) for c in col), width=4 * S)
    xs = np.arange(SIZE, dtype=np.float32)
    tx = np.clip((xs - 20.0 * S) / (110.0 * S), 0.0, 1.0)
    fade_l = Image.fromarray((np.repeat(tx[None, :], SIZE, axis=0) * 255).astype(np.uint8))
    lines = ImageChops.multiply(lines, Image.merge("RGB", (fade_l, fade_l, fade_l)))
    base = glow_add(base, lines, 4, 0.9, True)

    # ---- rear wing ------------------------------------------------------------------
    wing = new_layer()
    d = ImageDraw.Draw(wing)
    d.polygon(to_canvas([(56, 176), (44, 130), (126, 120), (128, 134), (74, 142), (78, 170)]), fill=MAGENTA)
    base = glow_add(base, wing, 5, 0.7, True)

    # ---- body -----------------------------------------------------------------------
    body_mask = Image.new("L", (SIZE, SIZE), 0)
    d = ImageDraw.Draw(body_mask)
    d.polygon(to_canvas(BODY_POLY_UNIT), fill=255)
    for (cx, cy, r) in WHEELS:
        c = cp(cx, cy)
        ar = ARCH_R * CAR_SCALE * S
        d.ellipse([c[0] - ar, c[1] - ar, c[0] + ar, c[1] + ar], fill=0)
    top_y = cp(0, 70)[1]
    bot_y = cp(0, 250)[1]
    body_fill = vertical_gradient((44, 52, 74), (7, 9, 15), top_y, bot_y)
    base.paste(body_fill, (0, 0), body_mask)

    # outline: dilated mask minus mask
    outer = body_mask.filter(ImageFilter.MaxFilter(9))
    band = ImageChops.subtract(outer, body_mask)
    band_rgb = Image.merge("RGB", (band.point(lambda v: int(v * GREEN[0] / 255)),
                                   band.point(lambda v: int(v * GREEN[1] / 255)),
                                   band.point(lambda v: int(v * GREEN[2] / 255))))
    base = glow_add(base, band_rgb, 7, 1.1, True)

    # shoulder / character line (magenta) and rocker line (green)
    chars = new_layer()
    d = ImageDraw.Draw(chars)
    shoulder = catmull([(60, 186), (220, 168), (420, 150), (640, 152), (820, 178), (940, 200)], 12)
    d.line(to_canvas(shoulder), fill=MAGENTA, width=3 * S, joint="curve")
    rocker = [(330, 238), (690, 238)]
    d.line(to_canvas(rocker), fill=GREEN, width=3 * S)
    base = glow_add(base, chars, 4, 0.9, True)

    # ---- glass ------------------------------------------------------------------------
    gmask = Image.new("L", (SIZE, SIZE), 0)
    d = ImageDraw.Draw(gmask)
    d.polygon(to_canvas(GLASS_UNIT), fill=255)
    g_top = cp(0, 85)[1]
    g_bot = cp(0, 135)[1]
    glass = vertical_gradient((120, 40, 140), (12, 10, 28), g_top, g_bot)
    base.paste(glass, (0, 0), gmask)
    # glare streak
    glare = new_layer()
    d = ImageDraw.Draw(glare)
    d.polygon(to_canvas([(430, 132), (470, 96), (492, 92), (452, 132)]), fill=(90, 70, 120))
    glare = ImageChops.multiply(glare, Image.merge("RGB", (gmask, gmask, gmask)))
    base = ImageChops.add(base, glare)

    # ---- wheels -------------------------------------------------------------------------
    for (cx, cy, r) in WHEELS:
        c = cp(cx, cy)
        rr = r * CAR_SCALE * S
        dd = ImageDraw.Draw(base)
        dd.ellipse([c[0] - rr, c[1] - rr, c[0] + rr, c[1] + rr], fill=(6, 7, 10))
        ring = new_layer()
        d = ImageDraw.Draw(ring)
        d.ellipse([c[0] - rr, c[1] - rr, c[0] + rr, c[1] + rr], outline=GREEN, width=int(3.2 * S))
        rim = rr * 0.66
        d.ellipse([c[0] - rim, c[1] - rim, c[0] + rim, c[1] + rim], outline=(170, 190, 200), width=int(2.4 * S))
        for k in range(5):
            ang = math.radians(k * 72.0 + 18.0)
            d.line([(c[0], c[1]), (c[0] + math.cos(ang) * rim, c[1] + math.sin(ang) * rim)], fill=(200, 215, 225), width=int(3 * S))
        hub = rr * 0.14
        d.ellipse([c[0] - hub, c[1] - hub, c[0] + hub, c[1] + hub], fill=MAGENTA)
        base = glow_add(base, ring, 3, 0.8, True)

    # ---- lights -----------------------------------------------------------------------------
    lights = new_layer()
    d = ImageDraw.Draw(lights)
    d.polygon(to_canvas([(918, 186), (978, 204), (952, 214), (912, 200)]), fill=(200, 255, 235))
    d.polygon(to_canvas([(26, 200), (46, 184), (50, 194), (30, 210)]), fill=(255, 40, 90))
    base = glow_add(base, lights, 9, 1.3, True)
    beam = new_layer()
    d = ImageDraw.Draw(beam)
    d.polygon(to_canvas([(975, 200), (1010, 190), (1010, 232), (975, 212)]), fill=(40, 120, 90))
    beam = beam.filter(ImageFilter.GaussianBlur(6 * S))
    base = ImageChops.add(base, beam)
    return base


def draw_code_motif(base):
    """big `</>` : green chevrons, magenta slash"""
    layer_g = new_layer()
    layer_m = new_layer()
    dg = ImageDraw.Draw(layer_g)
    dm = ImageDraw.Draw(layer_m)
    cy = 330.0
    h = 118.0            # half height of the chevrons
    w = 96.0
    lw = 44
    x_l = 205.0
    thick_line(dg, [sp(x_l + w, cy - h), sp(x_l, cy), sp(x_l + w, cy + h)], lw, GREEN)
    x_r = 1024.0 - 205.0
    thick_line(dg, [sp(x_r - w, cy - h), sp(x_r, cy), sp(x_r - w, cy + h)], lw, GREEN)
    thick_line(dm, [sp(560.0, cy - 150.0), sp(464.0, cy + 150.0)], lw, MAGENTA)
    out = glow_add(base, layer_g, 16, 0.7, True)
    out = glow_add(out, layer_m, 16, 0.7, True)
    return out


def draw_wordmark(base):
    font = None
    for cand in ("C:/Windows/Fonts/consolab.ttf", "C:/Windows/Fonts/courbd.ttf", "C:/Windows/Fonts/arialbd.ttf",
                 "/System/Library/Fonts/Menlo.ttc", "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"):
        if os.path.exists(cand):
            try:
                font = ImageFont.truetype(cand, int(64 * S))
                break
            except Exception:
                font = None
    if font is None:
        return base
    layer = new_layer()
    d = ImageDraw.Draw(layer)
    text = "c0derz"
    spacing = 14 * S
    widths = []
    for ch in text:
        widths.append(d.textlength(ch, font=font))
    total = sum(widths) + spacing * (len(text) - 1)
    x = (SIZE - total) / 2.0
    y = 900 * S
    for i, ch in enumerate(text):
        col = MAGENTA if ch == "0" else GREEN
        d.text((x, y), ch, font=font, fill=col)
        x += widths[i] + spacing
    return glow_add(base, layer, 6, 0.9, True)


def main():
    base = background()
    base = draw_floor(base)
    base = draw_car(base)
    base = draw_code_motif(base)
    base = draw_wordmark(base)
    icon = base.resize((1024, 1024), Image.LANCZOS).convert("RGB")
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    icon.save(OUT, "PNG", optimize=True)
    check = Image.open(OUT)
    assert check.size == (1024, 1024) and check.mode == "RGB", (check.size, check.mode)
    print("wrote", OUT, check.size, check.mode)


if __name__ == "__main__":
    main()
