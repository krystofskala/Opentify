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
    colour = np.asarray(mi.swirl(mi.home_field())).astype(np.float32)
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

    # Drážky.
    for frac, alpha in [(0.88, 0.35), (0.76, 0.28), (0.64, 0.22), (0.52, 0.16)]:
        ring = Image.new("L", (S, S), 0)
        rr = R * frac
        ImageDraw.Draw(ring).ellipse((c - rr, c - rr, c + rr, c + rr), outline=255, width=max(2, int(S * 0.004)))
        paint(np.asarray(ring.filter(ImageFilter.GaussianBlur(0.8))) * grad, (255, 255, 255), alpha)

    # Skleněná hrana desky.
    rim = Image.new("L", (S, S), 0)
    ImageDraw.Draw(rim).ellipse(box, outline=255, width=int(S * 0.008))
    paint(np.asarray(rim.filter(ImageFilter.GaussianBlur(1.0))) * grad, (255, 255, 255), 0.9)
    # Lesk přes horní polovinu (sklo).
    gl = Image.new("L", (S, S), 0)
    ImageDraw.Draw(gl).ellipse((c - R * 0.92, c - R * 0.96, c + R * 0.92, c + R * 0.2), fill=255)
    fade = np.clip(1 - (yy - (c - R)) / (R * 1.1), 0, 1)
    paint(np.asarray(gl.filter(ImageFilter.GaussianBlur(S * 0.02))) * fade, (255, 255, 255), 0.22)

    # Namrzlý skleněný střed + trojúhelník.
    lr = R * 0.36
    lab = Image.new("L", (S, S), 0)
    ImageDraw.Draw(lab).ellipse((c - lr, c - lr, c + lr, c + lr), fill=255)
    lab = lab.filter(ImageFilter.GaussianBlur(1.0))
    blurred = np.asarray(Image.fromarray(np.clip(out, 0, 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(S * 0.03))).astype(np.float32)
    milky = blurred * 0.7 + 255 * 0.3
    la = np.asarray(lab).astype(np.float32)[..., None] / 255
    out = out * (1 - la) + milky * la
    lrim = Image.new("L", (S, S), 0)
    ImageDraw.Draw(lrim).ellipse((c - lr, c - lr, c + lr, c + lr), outline=255, width=max(2, int(S * 0.005)))
    paint(np.asarray(lrim.filter(ImageFilter.GaussianBlur(0.8))) * grad, (255, 255, 255), 0.9)

    tri = Image.new("L", (S * 2, S * 2), 0)
    tr = lr * 2 * 0.62
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
