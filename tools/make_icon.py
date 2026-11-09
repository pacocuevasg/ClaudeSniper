"""Generates AppIcon.icns: pixel-art Clawd on the app's warm gradient.
Run from the repo root: python3 tools/make_icon.py   (needs Pillow and macOS iconutil)"""
from PIL import Image, ImageDraw, ImageFilter
import os, shutil, subprocess

S = 1024
BODY = ["...############..", "...##@######@##..", ".################", "...############..", "....#.#....#.#..."]
ORANGE, EYE = (217, 119, 87, 255), (33, 23, 18, 255)

def lerp(a, b, t): return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))

# Diagonal gradient: warm brown (top-left) → near black → deep purple (bottom-right)
A, B, C = (122, 58, 38), (30, 22, 24), (48, 37, 66)
grad = Image.new("RGB", (S, S))
px = grad.load()
for y in range(S):
    for x in range(S):
        t = (x + y) / (2 * S - 2)
        px[x, y] = lerp(A, B, t / 0.5) if t < 0.5 else lerp(B, C, (t - 0.5) / 0.5)

# macOS icon shape: 824 px rounded square inside the 1024 canvas
inset, radius = 100, 185
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([inset, inset, S - inset, S - inset], radius, fill=255)

icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle([inset, inset + 12, S - inset, S - inset + 12], radius, fill=(0, 0, 0, 110))
icon.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18)))
icon.paste(grad, (0, 0), mask)

# Clawd: 17 x 5 cells, each cell twice as tall as wide
cw, ch = 32, 64
ox, oy = (S - 17 * cw) // 2, (S - 5 * ch) // 2 - 6
ground = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(ground).ellipse([ox + 2 * cw, oy + 5 * ch - 6, ox + 15 * cw, oy + 5 * ch + 30], fill=(0, 0, 0, 120))
icon.alpha_composite(ground.filter(ImageFilter.GaussianBlur(12)))
d = ImageDraw.Draw(icon)
for r, row in enumerate(BODY):
    for c, cell in enumerate(row):
        if cell in "#@":
            d.rectangle([ox + c * cw, oy + r * ch, ox + (c + 1) * cw - 1, oy + (r + 1) * ch - 1], fill=ORANGE if cell == "#" else EYE)
# A thin light edge, like glass
edge = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(edge).rounded_rectangle([inset + 2, inset + 2, S - inset - 2, S - inset - 2], radius - 2, outline=(255, 255, 255, 34), width=4)
icon.alpha_composite(edge)

out = "build/AppIcon.iconset"
shutil.rmtree(out, ignore_errors=True)
os.makedirs(out)
for size in (16, 32, 128, 256, 512):
    icon.resize((size, size), Image.LANCZOS).save(f"{out}/icon_{size}x{size}.png")
    icon.resize((size * 2, size * 2), Image.LANCZOS).save(f"{out}/icon_{size}x{size}@2x.png")
subprocess.run(["iconutil", "-c", "icns", out, "-o", "AppIcon.icns"], check=True)
icon.resize((256, 256), Image.LANCZOS).save("docs/icon.png")
print("wrote AppIcon.icns and docs/icon.png")
