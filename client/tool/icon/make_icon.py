"""Ikona Opentify: zrnit?? barevn?? gradient (petrolej / tyrkys / jantar, bez
fialov?? a r????ov??) + sklen??n?? ??o??ka (Liquid Glass) se symbolem p??ehr??v??n??."""
import sys

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 1024
rng = np.random.default_rng(7)


def flow_field():
    """Zvlněné pásy barev (domain warping) -- jako tekuté pozadí appky, ne
    kulaté skvrny. Paleta bez fialové/růžové."""
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32) / S
    # Jemný vír kolem bodu vlevo dole -- pásy se kolem něj stáčejí.
    cx, cy = 0.38, 0.62
    dx, dy = xx - cx, yy - cy
    r = np.sqrt(dx * dx + dy * dy)
    ang = 2.4 * np.exp(-r * 2.2)
    rx = cx + dx * np.cos(ang) - dy * np.sin(ang)
    ry = cy + dx * np.sin(ang) + dy * np.cos(ang)
    wx = rx + 0.10 * np.sin(2 * np.pi * (ry * 1.1 + 0.15))
    wy = ry + 0.09 * np.sin(2 * np.pi * (rx * 0.9 + 0.4))
    t = 0.5 + 0.5 * np.sin(2 * np.pi * (wx * 0.55 + wy * 0.7) + 0.9 * np.sin(2 * np.pi * wy * 0.6) - 1.4)
    t = np.clip(t, 0, 1)
    # Stejná paleta jako výchozí pozadí appky (app_background.dart
    # _startDark včetně _soften: sytost ×0.8, světlosti o 22 % blíž k sobě).
    import colorsys
    raw = [(0x2A, 0x10, 0x60), (0x7B, 0x2C, 0xFF), (0xE0, 0x35, 0x9A), (0x12, 0xB5, 0xCB), (0xFF, 0x8A, 0x3D), (0x2B, 0xD6, 0x7B)]
    hls = [colorsys.rgb_to_hls(*(v / 255 for v in c)) for c in raw]
    mean_l = sum(h[1] for h in hls) / len(hls)
    soft = [tuple(int(v * 255) for v in colorsys.hls_to_rgb(h, mean_l + (l - mean_l) * 0.78, s * 0.8)) for h, l, s in hls]
    indigo, violet, magenta, cyan, orange, green = soft
    stops = [
        (0.00, indigo),
        (0.22, violet),
        (0.42, magenta),
        (0.58, orange),
        (0.78, cyan),
        (1.00, green),
    ]
    out = np.zeros((S, S, 3), np.float32)
    for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
        m = (t >= p0) & (t <= p1)
        k = ((t - p0) / (p1 - p0))[..., None]
        k = k * k * (3 - 2 * k)
        seg = np.array(c0, np.float32) * (1 - k) + np.array(c1, np.float32) * k
        out = np.where(m[..., None], seg, out)
    img = Image.fromarray(out.astype(np.uint8))
    return img.filter(ImageFilter.GaussianBlur(S * 0.03))


def home_field():
    """Jako pozadí Domů: převážně indigo/fialová, měkké vzdálené skvrny
    tyrkysové, zelené, magenty a oranžové (silně rozostřené, ne pásy)."""
    import colorsys
    raw = [(0x2A, 0x10, 0x60), (0x7B, 0x2C, 0xFF), (0xE0, 0x35, 0x9A), (0x12, 0xB5, 0xCB), (0xFF, 0x8A, 0x3D), (0x2B, 0xD6, 0x7B)]
    hls = [colorsys.rgb_to_hls(*(v / 255 for v in c)) for c in raw]
    mean_l = sum(h[1] for h in hls) / len(hls)
    soft = [tuple(int(v * 255) for v in colorsys.hls_to_rgb(h, mean_l + (l - mean_l) * 0.78, s * 0.8)) for h, l, s in hls]
    indigo, violet, magenta, cyan, orange, green = soft
    img = Image.new("RGB", (S, S), indigo)
    blobs = [
        ((0.35, 0.30), 0.75, violet, 210),
        ((1.00, 0.05), 0.75, cyan, 240),
        ((0.00, 0.55), 0.65, green, 225),
        ((0.75, 0.70), 0.50, violet, 200),
        ((1.00, 1.00), 0.60, magenta, 225),
        ((0.15, 1.02), 0.55, orange, 215),
        ((0.62, 0.40), 0.30, cyan, 120),
    ]
    for (cx, cy), r, col, alpha in blobs:
        mask = Image.new("L", (S, S), 0)
        rr = r * S / 2
        ImageDraw.Draw(mask).ellipse((cx * S - rr, cy * S - rr, cx * S + rr, cy * S + rr), fill=alpha)
        mask = mask.filter(ImageFilter.GaussianBlur(S * 0.11))
        img = Image.composite(Image.new("RGB", (S, S), col), img, mask)
    return img.filter(ImageFilter.GaussianBlur(S * 0.04))


def blob_field():
    base = Image.new("RGB", (S, S), (8, 22, 28))
    layer = Image.new("RGB", (S, S), (0, 0, 0))
    blobs = [
        ((0.18, 0.20), 0.55, (14, 92, 104)),   # petrolej
        ((0.85, 0.15), 0.45, (31, 170, 168)),  # tyrkys
        ((0.80, 0.88), 0.55, (240, 160, 60)),  # jantar
        ((0.15, 0.90), 0.45, (22, 70, 96)),    # hlubok?? modrozelen??
        ((0.55, 0.55), 0.35, (120, 190, 150)), # sv??tl?? mint
    ]
    img = base
    for (cx, cy), r, col in blobs:
        mask = Image.new("L", (S, S), 0)
        d = ImageDraw.Draw(mask)
        rr = r * S / 2
        d.ellipse((cx * S - rr, cy * S - rr, cx * S + rr, cy * S + rr), fill=255)
        mask = mask.filter(ImageFilter.GaussianBlur(S * 0.12))
        img = Image.composite(Image.new("RGB", (S, S), col), img, mask)
    return img.filter(ImageFilter.GaussianBlur(S * 0.03))


def swirl(img):
    """Zkroutí barevné pole do víru a vln -- barvy se přelévají kolem desky."""
    arr = np.asarray(img).astype(np.float32)
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32) / S
    cx, cy = 0.5, 0.52
    dx, dy = xx - cx, yy - cy
    r = np.sqrt(dx * dx + dy * dy)
    ang = 3.2 * np.exp(-r * 2.4)
    sx = cx + dx * np.cos(ang) - dy * np.sin(ang) + 0.05 * np.sin(2 * np.pi * yy * 2.3)
    sy = cy + dx * np.sin(ang) + dy * np.cos(ang) + 0.05 * np.sin(2 * np.pi * xx * 1.9 + 1.1)
    px = np.clip(sx * (S - 1), 0, S - 2)
    py = np.clip(sy * (S - 1), 0, S - 2)
    x0, y0 = px.astype(np.int32), py.astype(np.int32)
    fx, fy = (px - x0)[..., None], (py - y0)[..., None]
    out = (arr[y0, x0] * (1 - fx) * (1 - fy) + arr[y0, x0 + 1] * fx * (1 - fy)
           + arr[y0 + 1, x0] * (1 - fx) * fy + arr[y0 + 1, x0 + 1] * fx * fy)
    return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8))


def vignette(img):
    """Tmavý okraj jako tmavé ikony iOS: barvy hlavně uprostřed pod deskou,
    ke krajům a do rohů skoro černá (zrno se přidá až potom, zůstane)."""
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32) / S
    r = np.sqrt((xx - 0.5) ** 2 + (yy - 0.5) ** 2) / 0.707
    k = np.clip(1.0 - (r - 0.35) / 0.6, 0.0, 1.0)
    k = (k * k * (3 - 2 * k)) * 0.88 + 0.12
    arr = np.asarray(img).astype(np.float32) * k[..., None]
    dark = np.array([14, 12, 20], np.float32)
    arr = np.maximum(arr, dark * (1 - k[..., None]))
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))


def add_grain(img, strength):
    arr = np.asarray(img).astype(np.float32)
    noise = rng.normal(0, strength, (S, S, 1))
    arr = np.clip(arr + noise, 0, 255).astype(np.uint8)
    return Image.fromarray(arr)


def lens(bg):
    # Kulat?? ??o??ka uprost??ed (??? 64 % -- bezpe??n?? z??na maskable ikony).
    d = 0.80 * S
    x0 = (S - d) / 2
    box = (x0, x0, x0 + d, x0 + d)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).ellipse(box, fill=255)
    mask_s = mask.filter(ImageFilter.GaussianBlur(1.2))

    # Sklo: siln?? rozmazan?? pozad??, trochu zesv??tlen?? + lehce zv??t??en??
    # (lom -- obsah pod ??o??kou je "p??ibl????en??").
    zoom = bg.resize((int(S * 1.12), int(S * 1.12)), Image.LANCZOS)
    off = int(S * 0.06)
    zoom = zoom.crop((off, off, off + S, off + S))
    frosted = zoom.filter(ImageFilter.GaussianBlur(S * 0.022))
    frosted = Image.blend(frosted, Image.new("RGB", (S, S), (255, 255, 255)), 0.07)
    out = Image.composite(frosted, bg, mask_s)

    # M??kk?? st??n pod ??o??kou.
    shadow = Image.new("L", (S, S), 0)
    sd = ImageDraw.Draw(shadow)
    sd.ellipse((box[0], box[1] + S * 0.025, box[2], box[3] + S * 0.025), fill=110)
    shadow = shadow.filter(ImageFilter.GaussianBlur(S * 0.04))
    shadow = ImageChops.subtract(shadow, mask)
    out = Image.composite(Image.new("RGB", (S, S), (0, 0, 0)), out, shadow.point(lambda v: int(v * 0.6)))

    # Sv??teln?? hrana: naho??e vlevo jasn??, dole vpravo slab?? (gradient po obvodu).
    rim = Image.new("L", (S, S), 0)
    ImageDraw.Draw(rim).ellipse(box, outline=255, width=int(S * 0.008))
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
    grad = 1.0 - ((xx + yy) / (2 * S))  # 1 vlevo naho??e -> 0 vpravo dole
    grad = 0.18 + 0.82 * np.clip((grad - 0.25) / 0.5, 0, 1)
    rim_a = (np.asarray(rim).astype(np.float32) * grad).astype(np.uint8)
    rim_img = Image.fromarray(rim_a).filter(ImageFilter.GaussianBlur(1.0))
    out = Image.composite(Image.new("RGB", (S, S), (255, 255, 255)), out, rim_img)

    # Vnit??n?? odlesk: jemn?? srpek u horn?? hrany.
    gl = Image.new("L", (S, S), 0)
    gd = ImageDraw.Draw(gl)
    inset = S * 0.03
    gd.ellipse((box[0] + inset, box[1] + inset * 0.6, box[2] - inset, box[3] - inset), fill=255)
    cut = Image.new("L", (S, S), 0)
    ImageDraw.Draw(cut).ellipse((box[0] + inset, box[1] + inset * 2.2, box[2] - inset, box[3] + inset), fill=255)
    gl = ImageChops.subtract(gl, cut)
    top_fade = np.clip(1.0 - (yy - box[1]) / (d * 0.45), 0, 1)
    gl_a = (np.asarray(gl).astype(np.float32) * top_fade * 0.6).astype(np.uint8)
    gl_img = Image.fromarray(gl_a).filter(ImageFilter.GaussianBlur(S * 0.006))
    out = Image.composite(Image.new("RGB", (S, S), (255, 255, 255)), out, gl_img)

    # Symbol p??ehr??v??n??: zaoblen?? troj??heln??k, lehce opticky posunut?? doprava.
    # Gramodeska: světelné drážky (soustředné kroužky, nahoře vlevo jasnější).
    R = d / 2
    c = S / 2
    for frac, alpha in [(0.86, 0.30), (0.74, 0.22), (0.62, 0.16)]:
        ring = Image.new("L", (S, S), 0)
        rr = R * frac
        ImageDraw.Draw(ring).ellipse((c - rr, c - rr, c + rr, c + rr), outline=255, width=max(2, int(S * 0.004)))
        ring_a = (np.asarray(ring).astype(np.float32) * grad * alpha * 1.6).clip(0, 255).astype(np.uint8)
        out = Image.composite(Image.new("RGB", (S, S), (255, 255, 255)), out, Image.fromarray(ring_a).filter(ImageFilter.GaussianBlur(0.8)))

    # Středový štítek: jantarový kruh (tónovaný gradient) s jemným stínem.
    lr = R * 0.42
    label_mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(label_mask).ellipse((c - lr, c - lr, c + lr, c + lr), fill=255)
    label_mask = label_mask.filter(ImageFilter.GaussianBlur(1.0))
    lab_shadow = label_mask.filter(ImageFilter.GaussianBlur(S * 0.02)).point(lambda v: int(v * 0.45))
    lab_shadow = ImageChops.offset(lab_shadow, 0, int(S * 0.01))
    out = Image.composite(Image.new("RGB", (S, S), (0, 0, 0)), out, lab_shadow)
    # Štítek = hustěji namrzlé sklo (víc rozmazané, mléčnější), žádná barva
    # navíc -- odliší se od průhledného disku jen materiálem.
    milky = out.filter(ImageFilter.GaussianBlur(S * 0.03))
    milky = Image.blend(milky, Image.new("RGB", (S, S), (255, 255, 255)), 0.28)
    out = Image.composite(milky, out, label_mask)
    lrim = Image.new("L", (S, S), 0)
    ImageDraw.Draw(lrim).ellipse((c - lr, c - lr, c + lr, c + lr), outline=255, width=max(2, int(S * 0.005)))
    lrim_a = (np.asarray(lrim).astype(np.float32) * grad).astype(np.uint8)
    out = Image.composite(Image.new("RGB", (S, S), (255, 255, 255)), out, Image.fromarray(lrim_a).filter(ImageFilter.GaussianBlur(0.8)))
    # Lesk štítku nahoře.
    lg = Image.new("L", (S, S), 0)
    ImageDraw.Draw(lg).ellipse((c - lr * 0.85, c - lr * 0.95, c + lr * 0.85, c + lr * 0.1), fill=255)
    lg_a = (np.asarray(lg).astype(np.float32) * np.clip(1 - (yy - (c - lr)) / lr, 0, 1) * 0.28).astype(np.uint8)
    out = Image.composite(Image.new("RGB", (S, S), (255, 255, 255)), out, Image.fromarray(lg_a).filter(ImageFilter.GaussianBlur(S * 0.01)))

    tri = Image.new("L", (S * 2, S * 2), 0)
    cx, cy, r = S, S, lr * 2 * 0.62
    pts = [(cx - r * 0.55, cy - r * 0.78), (cx - r * 0.55, cy + r * 0.78), (cx + r * 0.85, cy)]
    ImageDraw.Draw(tri).polygon(pts, fill=255)
    tri = tri.filter(ImageFilter.GaussianBlur(S * 0.03)).point(lambda v: 255 if v > 110 else 0)
    tri = tri.resize((S, S), Image.LANCZOS)
    tri_shadow = tri.filter(ImageFilter.GaussianBlur(S * 0.015)).point(lambda v: int(v * 0.35))
    tri_shadow = ImageChops.offset(tri_shadow, 0, int(S * 0.008))
    out = Image.composite(Image.new("RGB", (S, S), (0, 0, 0)), out, tri_shadow)
    out = Image.composite(Image.new("RGB", (S, S), (250, 250, 247)), out, tri.point(lambda v: int(v * 0.95)))
    return out, mask_s


def main(out_dir):
    bg = add_grain(vignette(swirl(home_field())), 30)
    icon, disc = lens(bg)  # jemn?? zrno i p??es sklo
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
        # Zrno až PO zmenšení -- jinak se ze šumu zprůměruje nic a na malé
        # ikoně (iPhone 180 px) není vidět. Síla úměrná velikosti.
        arr = np.asarray(small).astype(np.float32)
        strength = 18 if size <= 200 else 16
        # Zrno jen na pozadí -- skleněná deska zůstane čistá.
        keep = 1 - np.asarray(disc.resize((size, size), Image.LANCZOS)).astype(np.float32)[..., None] / 255
        arr = np.clip(arr + rng.normal(0, strength, (size, size, 1)) * keep, 0, 255).astype(np.uint8)
        Image.fromarray(arr).save(f"{out_dir}/{name}", optimize=True)


if __name__ == "__main__":
    main(sys.argv[1])

