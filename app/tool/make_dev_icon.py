#!/usr/bin/env python3
"""Derives the "Famio Dev" macOS icon from the normal one: an orange band
with "DEV" across the lower part, so both apps are told apart in the Dock,
Launchpad and Spotlight.

    python3 tool/make_dev_icon.py   # from the app/ directory; after make_icons.py
"""
import os
import shutil

from PIL import Image, ImageChops, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "macos", "Runner", "Assets.xcassets")
SRC = os.path.join(ASSETS, "AppIcon.appiconset")
DST = os.path.join(ASSETS, "AppIconDev.appiconset")
ORANGE = (232, 112, 58, 255)
FONT = "/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf"


def badge(icon):
    size = icon.width
    band = Image.new("RGBA", icon.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(band)
    top, bottom = int(size * 0.64), int(size * 0.80)
    draw.rectangle((0, top, size, bottom), fill=ORANGE)
    if size >= 32:
        font = ImageFont.truetype(FONT, int((bottom - top) * 0.72))
        draw.text(
            (size / 2, (top + bottom) / 2),
            "DEV",
            font=font,
            fill=(255, 255, 255, 255),
            anchor="mm",
        )
    # Only where the icon itself is drawn (keeps the rounded shape).
    band.putalpha(ImageChops.multiply(band.getchannel("A"), icon.getchannel("A")))
    return Image.alpha_composite(icon, band)


os.makedirs(DST, exist_ok=True)
for name in os.listdir(SRC):
    if name.endswith(".png"):
        badge(Image.open(os.path.join(SRC, name)).convert("RGBA")).save(
            os.path.join(DST, name)
        )
shutil.copy(os.path.join(SRC, "Contents.json"), DST)
print("wrote", DST)
