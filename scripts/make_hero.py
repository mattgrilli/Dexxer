#!/usr/bin/env python3
"""Builds docs/hero.png for the README from a demo screenshot.

1. Capture the window with fictional data (debug build):
       Dexxer.app/Contents/MacOS/Dexxer -DexxerDemo YES
   This writes screenshot.png to
       ~/Library/Containers/com.mattgrilli.Dexxer/Data/tmp/Dexxer Demo/
2. Run: python3 scripts/make_hero.py [screenshot.png]

Requires Pillow and macOS (uses the system San Francisco font).
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SCREENSHOT = Path.home() / "Library/Containers/com.mattgrilli.Dexxer/Data/tmp/Dexxer Demo/screenshot.png"
ICON = ROOT / "Dexxer/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png"
OUTPUT = ROOT / "docs/hero.png"

WIDTH, HEIGHT = 1600, 1000
TOP, BOTTOM = (31, 42, 72), (19, 21, 32)  # same navy as the other project heroes
WHITE = (255, 255, 255)
TAGLINE = (205, 212, 228)
ACCENT = (125, 184, 255)
FONT = "/System/Library/Fonts/SFNS.ttf"


def font(size, weight):
    face = ImageFont.truetype(FONT, size)
    face.set_variation_by_name(weight)
    return face


def rounded(image, radius):
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, *image.size), radius, fill=255)
    image = image.convert("RGBA")
    image.putalpha(mask)
    return image


def centered_text(draw, y, parts):
    """Draws (text, font, color) pieces side by side, centered horizontally."""
    widths = [draw.textlength(text, font=face) for text, face, _ in parts]
    x = (WIDTH - sum(widths)) / 2
    for (text, face, color), width in zip(parts, widths):
        draw.text((x, y), text, font=face, fill=color)
        x += width


def main():
    screenshot_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SCREENSHOT

    hero = Image.new("RGB", (WIDTH, HEIGHT))
    draw = ImageDraw.Draw(hero)
    for y in range(HEIGHT):
        t = y / (HEIGHT - 1)
        draw.line([(0, y), (WIDTH, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)))

    # Icon and name
    title_font = font(96, "Bold")
    icon = rounded(Image.open(ICON).resize((92, 92), Image.LANCZOS), 22)
    title_width = draw.textlength("Dexxer", font=title_font)
    left = (WIDTH - (92 + 28 + title_width)) / 2
    hero.paste(icon, (round(left), 72), icon)
    draw.text((left + 92 + 28, 118), "Dexxer", font=title_font, fill=WHITE, anchor="lm")

    centered_text(draw, 184, [("Find any file on your Mac and network shares, by name or by what's inside.", font(31, "Regular"), TAGLINE)])
    dot = ("  ·  ", font(25, "Medium"), ACCENT)
    centered_text(draw, 236, [
        ("macOS", font(25, "Semibold"), ACCENT), dot,
        ("PDFs, Word, Outlook email, scans", font(25, "Semibold"), ACCENT), dot,
        ("Swift + SQLite full-text search", font(25, "Semibold"), ACCENT),
    ])

    # Window screenshot, running off the bottom edge
    shot = Image.open(screenshot_path).convert("RGBA")
    shot_width = 1300
    shot = shot.resize((shot_width, round(shot.height * shot_width / shot.width)), Image.LANCZOS)
    shot = rounded(shot, 14)
    x, y = (WIDTH - shot_width) // 2, 316

    shadow = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((x, y + 14, x + shot.width, y + shot.height + 14), 14, fill=(0, 0, 0, 150))
    hero.paste(shadow.filter(ImageFilter.GaussianBlur(28)), (0, 0), shadow.filter(ImageFilter.GaussianBlur(28)))
    hero.paste(shot, (x, y), shot)
    ImageDraw.Draw(hero).rounded_rectangle((x, y, x + shot.width - 1, y + shot.height), 14, outline=(255, 255, 255, 40), width=1)

    OUTPUT.parent.mkdir(exist_ok=True)
    hero.save(OUTPUT, optimize=True)
    print(f"Wrote {OUTPUT}")


if __name__ == "__main__":
    main()
