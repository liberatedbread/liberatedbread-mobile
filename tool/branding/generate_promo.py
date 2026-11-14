#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Store-listing promo assets, built from the same two sources as the app icons
# (brand.json + app_icon_mascot.png) so they can't drift from the app:
#
#   assets/promo/icon_512.png              Google Play hi-res icon (512x512, 32-bit)
#   assets/promo/feature_graphic_1024x500.png  Google Play feature graphic (no alpha)
#   assets/promo/screenshots/framed/*.png  raw screenshots captioned on brand
#                                          backgrounds, if any raw shots exist
#
# Usage (from the repo root):
#   python3 tool/branding/generate_promo.py
#
# Needs Pillow. The headline face is Lato (Ubuntu: fonts-lato); any other bold
# sans works via PROMO_FONT_DIR, with a DejaVu fallback.

import json
import os
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
BRANDING = ROOT / "tool" / "branding"
OUT = ROOT / "assets" / "promo"
RAW_SHOTS = OUT / "screenshots" / "raw"
FRAMED = OUT / "screenshots" / "framed"

brand = json.loads((BRANDING / "brand.json").read_text())
BLUSH = brand["blush"]
BLUSH_DEEP = brand["blushDeep"]
ORANGE = brand["breadOrange"]
CRUST = brand["crust"]
FACE = brand["face"]

# Caption per raw screenshot (file stem -> (headline, subline)). Shots with no
# entry are framed with no caption.
CAPTIONS = {
    "01_devices": ("Find what's around you", "Discovered locally over Bluetooth"),
    "02_controls": ("Control it directly", "No account. No cloud relay."),
    "03_device_details": ("Every command, exposed", "Straight from the open device spec"),
    "04_spec_packs": ("New devices, no app update", "Install open device-spec packs"),
    "05_home_assistant": ("Your own Home Assistant", "Forward live readings to your server"),
    "06_raw_gatt": ("Poke at anything", "A raw GATT browser for unknown gear"),
}

def font(weight: str, size: int) -> ImageFont.FreeTypeFont:
    dirs = [os.environ.get("PROMO_FONT_DIR", ""), "/usr/share/fonts/truetype/lato"]
    for d in dirs:
        p = Path(d) / f"Lato-{weight}.ttf"
        if d and p.exists():
            return ImageFont.truetype(str(p), size)
    return ImageFont.truetype("DejaVuSans-Bold.ttf", size)


def mascot() -> Image.Image:
    """The mascot cropped tight to its artwork."""
    im = Image.open(BRANDING / "app_icon_mascot.png").convert("RGBA")
    return im.crop(im.getbbox())


def fit(im: Image.Image, box: int) -> Image.Image:
    scale = box / max(im.size)
    return im.resize((round(im.width * scale), round(im.height * scale)), Image.LANCZOS)


def icon_512() -> None:
    # Same composition as the platform icons: blush ground, mascot centred at
    # ~78% so nothing is lost to Play's rounded-corner mask.
    size = 512
    canvas = Image.new("RGBA", (size, size), BLUSH)
    m = fit(mascot(), round(size * 0.78))
    canvas.alpha_composite(m, ((size - m.width) // 2, (size - m.height) // 2))
    canvas.save(OUT / "icon_512.png", optimize=True)


def feature_graphic() -> None:
    w, h = 1024, 500
    canvas = Image.new("RGBA", (w, h), BLUSH)
    d = ImageDraw.Draw(canvas)

    # Soft diagonal band in the deep blush behind the mascot for depth.
    band = Image.new("L", (w, h), 0)
    ImageDraw.Draw(band).polygon([(560, 0), (w, 0), (w, h), (420, h)], fill=60)
    canvas.paste(Image.new("RGBA", (w, h), BLUSH_DEEP), (0, 0), band)

    # Mascot on the right, slightly oversized and nudged so it feels lively.
    m = fit(mascot(), 430).rotate(-6, resample=Image.BICUBIC, expand=True)
    shadow = Image.new("RGBA", m.size, FACE)
    shadow.putalpha(m.getchannel("A").point(lambda a: a * 0.35))
    shadow = shadow.filter(ImageFilter.GaussianBlur(10))
    mx, my = w - m.width - 30, (h - m.height) // 2 + 10
    canvas.alpha_composite(shadow, (mx + 10, my + 14))
    canvas.alpha_composite(m, (mx, my))

    # Wordmark + tagline on the left. Google overlays a play button only on
    # video features, but keep text in the left ~55% anyway.
    x = 64
    title = font("Black", 92)
    d.text((x, 118), "Liberated", font=title, fill=FACE)
    d.text((x, 208), "Bread", font=title, fill=FACE)
    tag = font("Bold", 34)
    d.text((x, 322), "Control your own devices.", font=tag, fill=FACE)
    sub = font("Semibold", 26)
    d.text((x, 368), "Bluetooth + Wi-Fi · No cloud · Open source", font=sub, fill=BLUSH_DEEP)

    # Play rejects alpha in the feature graphic.
    canvas.convert("RGB").save(OUT / "feature_graphic_1024x500.png", optimize=True)


def rounded(im: Image.Image, r: int) -> Image.Image:
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, im.width - 1, im.height - 1), r, fill=255)
    out = im.convert("RGBA")
    out.putalpha(mask)
    return out


def strip_status_bar(im: Image.Image) -> Image.Image:
    """Drop the solid-black status bar a headless emulator draws at the top."""
    px = im.load()
    y = 0
    while y < im.height // 8 and all(px[x, y] == (0, 0, 0) for x in range(0, im.width, 16)):
        y += 1
    return im.crop((0, y, im.width, im.height))


def frame_shot(src: Path) -> None:
    """Caption a raw phone screenshot on a 9:16 brand canvas.

    Output is 1080x1920 (exactly 9:16, inside Play's 2:1 aspect limit and
    320-3840px bounds), saved as RGB PNG, well under the 8 MB cap.
    """
    w, h = 1080, 1920
    canvas = Image.new("RGBA", (w, h), BLUSH)
    d = ImageDraw.Draw(canvas)
    head, subline = CAPTIONS.get(src.stem, ("", ""))

    top = 80
    if head:
        f1 = font("Black", 76)
        tw = d.textlength(head, font=f1)
        if tw > w - 120:
            f1 = font("Black", int(76 * (w - 120) / tw))
        d.text((w / 2, top), head, font=f1, fill=FACE, anchor="mt")
        f2 = font("Semibold", 40)
        d.text((w / 2, top + 100), subline, font=f2, fill=BLUSH_DEEP, anchor="mt")
        top += 190

    shot = strip_status_bar(Image.open(src).convert("RGB"))
    avail_h = h - top - 40
    scale = min((w - 160) / shot.width, avail_h / shot.height)
    shot = shot.resize((round(shot.width * scale), round(shot.height * scale)), Image.LANCZOS)
    shot = rounded(shot, 44)
    border = 14
    phone = Image.new("RGBA", (shot.width + 2 * border, shot.height + 2 * border), (0, 0, 0, 0))
    ImageDraw.Draw(phone).rounded_rectangle(
        (0, 0, phone.width - 1, phone.height - 1), 44 + border, fill=FACE
    )
    phone.alpha_composite(shot, (border, border))
    px = (w - phone.width) // 2
    canvas.alpha_composite(phone, (px, top))
    canvas.convert("RGB").save(FRAMED / src.name, optimize=True)


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    icon_512()
    feature_graphic()
    shots = sorted(RAW_SHOTS.glob("*.png")) if RAW_SHOTS.exists() else []
    if shots:
        FRAMED.mkdir(parents=True, exist_ok=True)
        for s in shots:
            frame_shot(s)
    for p in sorted(OUT.rglob("*.png")):
        with Image.open(p) as im:
            print(f"{p.relative_to(ROOT)}  {im.size[0]}x{im.size[1]} {im.mode}  {p.stat().st_size // 1024} KB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
