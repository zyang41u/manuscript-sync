"""Turn square artwork into a macOS app icon on Apple's grid.

The artwork is cropped, scaled to an 824 px rounded square with transparent
corners, and centered on a 1024 px canvas with a soft shadow.

Usage: python3 make_icon.py icon-source.png AppIcon.png [left,top,right,bottom]
"""
import sys

from PIL import Image, ImageDraw, ImageFilter

SIZE, CANVAS, SUPERSAMPLE = 824, 1024, 4

src, dst = sys.argv[1], sys.argv[2]
art = Image.open(src).convert("RGBA")
if len(sys.argv) > 3:
    art = art.crop(tuple(int(v) for v in sys.argv[3].split(",")))
art = art.resize((SIZE, SIZE), Image.Resampling.LANCZOS)

# Draw the mask large and shrink it, for smooth corners.
big = SIZE * SUPERSAMPLE
mask = Image.new("L", (big, big), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, big - 1, big - 1), radius=round(big * 0.2237), fill=255)
mask = mask.resize((SIZE, SIZE), Image.Resampling.LANCZOS)
art.putalpha(mask)

offset = (CANVAS - SIZE) // 2
shadow_alpha = Image.new("L", (CANVAS, CANVAS), 0)
shadow_alpha.paste(mask.point(lambda a: int(a * 0.28)), (offset, offset + 10))
icon = Image.new("RGBA", (CANVAS, CANVAS))  # transparent black
icon.putalpha(shadow_alpha.filter(ImageFilter.GaussianBlur(14)))
icon.alpha_composite(art, (offset, offset))
icon.save(dst)
