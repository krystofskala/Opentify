"""Ikona Opentify v2: klasické tmavé pozadí (jako tmavé ikony iOS), deska
je z barevného zrnitého gradientu appky se skleněnou hranou a drážkami."""
import importlib.util
import sys

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

spec = importlib.util.spec_from_file_location("mi", sys.argv[2])
mi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mi)
S = mi.S
rng = np.random.default_rng(11)
yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)


def disc_field():
    """Pestré, méně fialové: barvy appky ve víru v pořadí magenta -> oranžová
    -> zelená -> azurová -> fialová (jen kousek)."""
    import colorsys
    raw = [(0xE0, 0x35, 0x9A), (0xFF, 0x8A, 0x3D), (0x2B, 0xD6, 0x7B), (0x12, 0xB5, 0xCB), (0x7B, 0x2C, 0xFF)]
    hls = [colorsys.rgb_to_hls(*(v / 255 for v in c)) for c in raw]
    mean_l = sum(h[1] for h in hls) / len(hls)
    soft = [np.array(colorsys.hls_to_rgb(h, mean_l + (l - mean_l) * 0.8, s * 0.85), np.float32) * 255 for h, l, s in hls]
    u, v = xx / S, yy / S
    cx, cy = 0.5, 0.5
    dx, dy = u - cx, v - cy
    r = np.sqrt(dx * dx + dy * dy)
    theta = np.arctan2(dy, dx)
    # Úhlový gradient (jako barevná deska) zkroucený vírem + vlnou.
    t = (theta / (2 * np.pi) + 0.5 + 0.35 * r + 0.06 * np.sin(2 * np.pi * r * 3)) % 1.0
    n = len(soft)
    pos = t * n
    i0 = np.floor(pos).astype(np.int32) % n
    i1 = (i0 + 1) % n
    f = (pos - np.floor(pos))[..., None]
    f = f * f * (3 - 2 * f)
    pal = np.stack(soft)
    out = pal[i0] * (1 - f) + pal[i1] * f
    img = Image.fromarray(np.clip(out, 0, 255).astype(np.uint8))
    return img.filter(ImageFilter.GaussianBlur(S * 0.02))


def home_disc_field():
    """Stejné měkké skvrny jako pozadí Domů (paleta _startDark + _soften),
    rozložené vyváženě kolem desky -- ne převaha fialové."""
    import colorsys
    raw = [(0x2A, 0x10, 0x60), (0x7B, 0x2C, 0xFF), (0xE0, 0x35, 0x9A), (0x12, 0xB5, 0xCB), (0xFF, 0x8A, 0x3D), (0x2B, 0xD6, 0x7B)]
    hls = [colorsys.rgb_to_hls(*(v / 255 for v in c)) for c in raw]
    mean_l = sum(h[1] for h in hls) / len(hls)
    soft = [tuple(int(v * 255) for v in colorsys.hls_to_rgb(h, mean_l + (l - mean_l) * 0.78, s * 0.8)) for h, l, s in hls]
    indigo, violet, magenta, cyan, orange, green = soft
    img = Image.new("RGB", (S, S), indigo)
    blobs = [
        ((0.30, 0.22), 0.55, violet, 230),
        ((0.78, 0.25), 0.55, cyan, 235),
        ((0.20, 0.60), 0.45, green, 220),
        ((0.80, 0.75), 0.50, magenta, 225),
        ((0.38, 0.85), 0.45, orange, 215),
        ((0.55, 0.50), 0.30, violet, 150),
    ]
    for (cx, cy), r, col, alpha in blobs:
        mask = Image.new("L", (S, S), 0)
        rr = r * S / 2
        ImageDraw.Draw(mask).ellipse((cx * S - rr, cy * S - rr, cx * S + rr, cy * S + rr), fill=alpha)
        mask = mask.filter(ImageFilter.GaussianBlur(S * 0.09))
        img = Image.composite(Image.new("RGB", (S, S), col), img, mask)
    return img.filter(ImageFilter.GaussianBlur(S * 0.03))


def dark_tile():
    top, bottom = np.array([44, 44, 48], np.float32), np.array([20, 20, 23], np.float32)
    t = (yy / S)[..., None]
    return top * (1 - t) + bottom * t


def main(out_dir):
    bg = dark_tile()
    d = 0.78 * S
    c = S / 2
    R = d / 2
    box = (c - R, c - R, c + R, c + R)
    disc = Image.new("L", (S, S), 0)
    ImageDraw.Draw(disc).ellipse(box, fill=255)
    disc = disc.filter(ImageFilter.GaussianBlur(1.2))
    dm = np.asarray(disc).astype(np.float32)[..., None] / 255

    # Stín desky na tmavém podkladu.
    sh = Image.new("L", (S, S), 0)
    ImageDraw.Draw(sh).ellipse((box[0], box[1] + S * 0.03, box[2], box[3] + S * 0.03), fill=180)
    sh = np.asarray(sh.filter(ImageFilter.GaussianBlur(S * 0.04))).astype(np.float32)[..., None] / 255
    bg = bg * (1 - sh * 0.55)

    # Deska = barevný gradient appky (vír) + zrno.
    colour = np.asarray(home_disc_field()).astype(np.float32)
    colour = colour + rng.normal(0, 22, (S, S, 1))
    # Mírné stínování do kraje desky -- objem.
    r = np.sqrt((xx - c) ** 2 + (yy - c) ** 2) / R
    shade = np.clip(1.08 - 0.28 * r ** 3, 0.7, 1.1)[..., None]
    colour = colour * shade
    out = bg * (1 - dm) + colour * dm

    def paint(mask_arr, rgb, alpha):
        nonlocal out
        a = (mask_arr.astype(np.float32) / 255 * alpha)[..., None]
        out = out * (1 - a) + np.array(rgb, np.float32) * a

    grad = 1.0 - ((xx + yy) / (2 * S))
    grad = 0.2 + 0.8 * np.clip((grad - 0.25) / 0.5, 0, 1)

    # Drážky: jemné tmavé kroužky (žádné sklo).
    for frac in (0.9, 0.8, 0.7):
        ring = Image.new("L", (S, S), 0)
        rr = R * frac
        ImageDraw.Draw(ring).ellipse((c - rr, c - rr, c + rr, c + rr), outline=255, width=max(3, int(S * 0.014)))
        paint(np.asarray(ring.filter(ImageFilter.GaussianBlur(1.5))), (0, 0, 0), 0.26)

    # Černá díra uprostřed (jako středový otvor desky) s jemným vnitřním stínem.
    hr = R * 0.36
    hole = Image.new("L", (S, S), 0)
    ImageDraw.Draw(hole).ellipse((c - hr, c - hr, c + hr, c + hr), fill=255)
    hole_a = np.asarray(hole.filter(ImageFilter.GaussianBlur(1.2)))
    paint(hole_a, (10, 10, 13), 1.0)
    inner = ImageChops.subtract(hole, ImageChops.offset(hole, 0, int(S * 0.012))).filter(ImageFilter.GaussianBlur(S * 0.008))
    paint(np.asarray(inner), (255, 255, 255), 0.10)

    # Velký bílý trojúhelník -- přesahuje přes okraj díry do barvy.
    tri = Image.new("L", (S * 2, S * 2), 0)
    tr = R * 0.98  # plátno 2S -> po zmenšení ~0.5 R, přesahuje díru (0.3 R)
    pts = [(S - tr * 0.55, S - tr * 0.78), (S - tr * 0.55, S + tr * 0.78), (S + tr * 0.85, S)]
    ImageDraw.Draw(tri).polygon(pts, fill=255)
    tri = tri.filter(ImageFilter.GaussianBlur(S * 0.03)).point(lambda v: 255 if v > 110 else 0).resize((S, S), Image.LANCZOS)
    paint(np.asarray(ImageChops.offset(tri.filter(ImageFilter.GaussianBlur(S * 0.012)), 0, int(S * 0.008))), (0, 0, 0), 0.3)
    paint(np.asarray(tri), (250, 250, 247), 0.96)

    icon = Image.fromarray(np.clip(out, 0, 255).astype(np.uint8))
    icon.save(f"{out_dir}/_master.png")
    for name, size in [
        ("icons/Icon-192.png", 192),
        ("icons/Icon-512.png", 512),
        ("icons/Icon-maskable-192.png", 192),
        ("icons/Icon-maskable-512.png", 512),
        ("icons/apple-touch-icon.png", 180),
        ("favicon.png", 64),
    ]:
        small = icon.resize((size, size), Image.LANCZOS)
        # Zrno po zmenšení jen na desce (ať je vidět i na 180 px).
        m = np.asarray(disc.resize((size, size), Image.LANCZOS)).astype(np.float32)[..., None] / 255
        arr = np.asarray(small).astype(np.float32) + rng.normal(0, 14, (size, size, 1)) * m
        Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8)).save(f"{out_dir}/{name}", optimize=True)


if __name__ == "__main__":
    main(sys.argv[1])
