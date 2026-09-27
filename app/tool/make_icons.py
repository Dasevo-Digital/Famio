#!/usr/bin/env python3
"""Draws the Famio app icon and writes it in the native shape of every
platform (macOS, Windows, Linux, Android incl. adaptive/themed icons).

    python3 tool/make_icons.py      # from the app/ directory; needs Pillow
"""
import math
import os

from PIL import Image, ImageChops, ImageDraw, ImageFilter

TOP = (255, 184, 140)  # peach
BOTTOM = (239, 104, 145)  # rose
HEART = (236, 90, 134)
WHITE = (255, 255, 255, 255)
SS = 4  # supersampling for smooth edges

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def path(*parts):
    p = os.path.join(ROOT, *parts)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    return p


def gradient(size):
    """Vertical peach → rose gradient."""
    g = Image.new("RGBA", (1, 256))
    for y in range(256):
        t = y / 255
        g.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)) + (255,))
    return g.resize((size, size), Image.BILINEAR)


def superellipse(size, box, n=5.0):
    """Mask of Apple's continuous-corner squircle inside [box]."""
    x0, y0, x1, y1 = box
    cx, cy, a, b = (x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) / 2, (y1 - y0) / 2
    pts = []
    for i in range(720):
        t = 2 * math.pi * i / 720
        c, s = math.cos(t), math.sin(t)
        pts.append((cx + a * math.copysign(abs(c) ** (2 / n), c),
                    cy + b * math.copysign(abs(s) ** (2 / n), s)))
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).polygon(pts, fill=255)
    return m


def rounded(size, box, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m


def heart_points(cx, cy, w):
    """Classic parametric heart, [w] wide, centered at (cx, cy)."""
    pts = []
    for i in range(400):
        t = 2 * math.pi * i / 400
        x = 16 * math.sin(t) ** 3
        y = 13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)
        pts.append((cx + x * w / 32, cy - y * w / 32 - w * 0.03))
    return pts


def glyph(size, scale=1.0, heart=HEART + (255,), knockout=False):
    """House with a heart, on a transparent canvas of [size] px.

    [scale] is the glyph width relative to the canvas. With [knockout] the
    heart is cut out (single-color silhouettes such as themed icons).
    """
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    u = size * scale / 100  # glyph units: 100 wide
    cx = size / 2
    top = size / 2 - 48 * u
    stroke = 13 * u
    # Roof: thick line with round caps.
    left, apex, right = (cx - 44 * u, top + 38 * u), (cx, top + 4 * u), (cx + 44 * u, top + 38 * u)
    d.line([left, apex, right], fill=WHITE, width=round(stroke), joint="curve")
    for x, y in (left, apex, right):
        d.ellipse([x - stroke / 2, y - stroke / 2, x + stroke / 2, y + stroke / 2], fill=WHITE)
    # Body below the roof.
    body = [cx - 32 * u, top + 30 * u, cx + 32 * u, top + 92 * u]
    d.rounded_rectangle(body, radius=9 * u, fill=WHITE)
    d.polygon([(cx - 32 * u, top + 30 * u), apex, (cx + 32 * u, top + 30 * u)], fill=WHITE)
    pts = heart_points(cx, top + 62 * u, 34 * u)
    if knockout:
        mask = Image.new("L", (size, size), 0)
        ImageDraw.Draw(mask).polygon(pts, fill=255)
        im.putalpha(ImageChops.subtract(im.getchannel("A"), mask))
    else:
        d.polygon(pts, fill=heart)
    return im


def compose(size, shape_mask, glyph_scale, shadow=None):
    """Gradient tile clipped by [shape_mask], glyph on top, optional shadow."""
    tile = gradient(size)
    tile.alpha_composite(glyph(size, glyph_scale))
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    if shadow:
        blur, dy, alpha = shadow
        sh = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        sh.putalpha(shape_mask.point(lambda v: v * alpha // 255))
        sh = sh.transform(sh.size, Image.AFFINE, (1, 0, 0, 0, 1, -dy)).filter(ImageFilter.GaussianBlur(blur))
        out.alpha_composite(sh)
    tile.putalpha(shape_mask)
    out.alpha_composite(tile)
    return out


def render(px, draw):
    """Draws at [px]*SS and downsamples for anti-aliasing."""
    return draw(px * SS).resize((px, px), Image.LANCZOS)


# --- platform shapes ---------------------------------------------------------

def macos(px):
    # Apple grid: 824/1024 squircle body, soft drop shadow.
    def draw(s):
        k = s / 1024
        mask = superellipse(s, (100 * k, 92 * k, 924 * k, 916 * k))
        return compose(s, mask, 0.56 * 824 / 1024, shadow=(14 * k, 10 * k, 80))
    return render(px, draw)


def tile(px, margin):
    """Rounded square used on Windows, Linux and legacy Android."""
    def draw(s):
        m = s * margin
        return compose(s, rounded(s, (m, m, s - m, s - m), (s - 2 * m) * 0.23), 0.62 * (1 - 2 * margin))
    return render(px, draw)


def android_foreground(px):
    # 108dp canvas; launchers show the inner 72dp, keep the glyph in 66dp.
    return render(px, lambda s: glyph(s, 0.42))


def android_monochrome(px):
    return render(px, lambda s: glyph(s, 0.42, knockout=True))


def save_ico(file, sizes):
    images = [tile(s, 0.0 if s <= 32 else 0.04) for s in sizes]
    images[-1].save(file, format="ICO", sizes=[(s, s) for s in sizes], append_images=images[:-1])


def main():
    master = tile(1024, 0.0)
    master.save(path("assets/icon/app_icon.png"))
    android_foreground(1024).save(path("assets/icon/app_icon_foreground.png"))
    # House and heart without background, for the logo inside the app.
    render(256, lambda s: glyph(s, 0.8)).save(path("assets/icon/logo_glyph.png"))

    # macOS
    for s in (16, 32, 64, 128, 256, 512, 1024):
        macos(s).save(path(f"macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{s}.png"))

    # Windows: all sizes Explorer and the taskbar ask for.
    save_ico(path("windows/runner/resources/app_icon.ico"), [16, 20, 24, 32, 40, 48, 64, 96, 128, 256])

    # Linux: window icon inside the bundle + hicolor theme sizes for packages.
    tile(512, 0.04).save(path("linux/runner/resources/app_icon.png"))
    for s in (16, 24, 32, 48, 64, 128, 256, 512):
        tile(s, 0.0 if s <= 32 else 0.04).save(path(f"linux/packaging/icons/hicolor/{s}x{s}/apps/de.status403.famio.png"))

    # Android
    densities = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
    res = "android/app/src/main/res"
    for name, f in densities.items():
        tile(round(48 * f), 0.06).save(path(f"{res}/mipmap-{name}/ic_launcher.png"))
        android_foreground(round(108 * f)).save(path(f"{res}/drawable-{name}/ic_launcher_foreground.png"))
        android_monochrome(round(108 * f)).save(path(f"{res}/drawable-{name}/ic_launcher_monochrome.png"))
    tile(512, 0.0).save(path("android/play_store_512.png"))
    print("icons written")


if __name__ == "__main__":
    main()
