"""Generates MirrorMe's app icon (build/appicon.png + build/windows/icon.ico).

Design: a Windows 11 Fluent-style rounded-square badge in the app's own
accent blue (#005FB8, matching frontend/src/style.css --accent-default),
with a white iPhone glyph and radiating "mirroring" arcs cast from its
top-right corner -- the same visual language as Windows' own "Cast/Project"
glyph, but anchored to a phone shape (source device) rather than a monitor
(destination device), since MirrorMe mirrors FROM the iPhone TO the PC.

Run once with Pillow (`pip install pillow`) whenever the icon needs to be
regenerated; the rasterized outputs are what actually ship, not this script.
"""
import math
from PIL import Image, ImageDraw

SIZE = 1024
ACCENT = (0, 95, 184, 255)       # #005FB8
ACCENT_DARK = (0, 76, 147, 255)  # subtle shading for depth
WHITE = (255, 255, 255, 255)

def rounded_square(size, radius, fill):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=fill)
    return img

def draw_icon():
    img = rounded_square(SIZE, int(SIZE * 0.22), ACCENT)

    # Subtle bottom-lit gradient wash for depth (flat-but-not-flat, matching
    # how Win11 inbox app tiles use a faint linear shade rather than pure flat
    # fill).
    shade = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shade)
    for y in range(SIZE):
        t = y / SIZE
        alpha = int(40 * t)
        sd.line([(0, y), (SIZE, y)], fill=(0, 0, 0, alpha))
    mask = rounded_square(SIZE, int(SIZE * 0.22), (255, 255, 255, 255))
    img = Image.alpha_composite(img, Image.composite(shade, Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0)), mask))

    d = ImageDraw.Draw(img)

    # --- Phone glyph (source device) ---
    phone_w = int(SIZE * 0.30)
    phone_h = int(SIZE * 0.50)
    phone_x = int(SIZE * 0.27)
    phone_y = int(SIZE * 0.27)
    phone_r = int(phone_w * 0.22)
    d.rounded_rectangle(
        [phone_x, phone_y, phone_x + phone_w, phone_y + phone_h],
        radius=phone_r, fill=WHITE,
    )
    # Screen inset (accent-colored, so the phone reads as an outline/frame)
    inset = int(phone_w * 0.09)
    top_inset = int(phone_h * 0.07)
    d.rounded_rectangle(
        [phone_x + inset, phone_y + top_inset,
         phone_x + phone_w - inset, phone_y + phone_h - top_inset],
        radius=max(phone_r - inset, 4), fill=ACCENT,
    )
    # Speaker notch
    notch_w = int(phone_w * 0.28)
    notch_h = max(int(phone_h * 0.012), 4)
    notch_x = phone_x + (phone_w - notch_w) // 2
    notch_y = phone_y + int(phone_h * 0.035)
    d.rounded_rectangle(
        [notch_x, notch_y, notch_x + notch_w, notch_y + notch_h],
        radius=notch_h // 2, fill=WHITE,
    )

    # --- Mirroring arcs (cast signal), radiating from the phone's top-right
    # corner toward the badge's top-right corner ---
    origin_x = phone_x + phone_w - int(phone_w * 0.12)
    origin_y = phone_y + int(phone_h * 0.10)
    arc_width = int(SIZE * 0.045)
    radii = [int(SIZE * 0.14), int(SIZE * 0.235), int(SIZE * 0.33)]
    for radius in radii:
        bbox = [origin_x - radius, origin_y - radius, origin_x + radius, origin_y + radius]
        d.arc(bbox, start=300, end=345, fill=WHITE, width=arc_width)

    return img

def make_ico(src, path, sizes=(16, 20, 24, 32, 40, 48, 64, 96, 128, 256)):
    # Pillow's ICO writer downsamples the *base* image passed to save() for
    # each requested size and silently drops any size larger than the base
    # image -- so the base image must be the largest, highest-quality source
    # (never pre-shrunk), or every size above the smallest gets dropped.
    src.save(path, format="ICO", sizes=[(s, s) for s in sizes])

if __name__ == "__main__":
    icon = draw_icon()
    icon.save(r"X:\burkeholland\mirror-me\build\appicon.png")
    make_ico(icon, r"X:\burkeholland\mirror-me\build\windows\icon.ico")
    print("Icon written.")
