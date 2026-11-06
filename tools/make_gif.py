"""Generates docs/clawd.gif (Clawd walking) from the same pixel grids the app uses."""
from PIL import Image, ImageDraw
import sys
E = "................."
BODY = ["...############..", "...##@######@##..", ".################", "...############.."]
BLINK = ["...############..", "...############..", ".################", "...############.."]
LA, LB = "....#.#....#.#...", "...#.#....#.#...."
FRAMES = [[E]+BODY+[LA], [E]+BODY+[LB], BODY+[LA]+[E], [E]+BODY+[LB], [E]+BODY+[LA], [E]+BLINK+[LA]]
PX, PH, PAD = 12, 24, 12
COL = {"#": (217, 119, 87, 255), "@": (33, 23, 18, 255)}
W, H = 17 * PX + 2 * PAD, 6 * PH + 2 * PAD
imgs = []
for f in FRAMES:
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    for y, row in enumerate(f):
        for x, ch in enumerate(row):
            if ch in COL:
                d.rectangle([PAD + x*PX, PAD + y*PH, PAD + (x+1)*PX - 1, PAD + (y+1)*PH - 1], fill=COL[ch])
    imgs.append(im)
# Transparent GIF: palette + transparent index
pal = []
for im in imgs:
    p = im.convert("RGBA")
    alpha = p.getchannel("A")
    q = p.convert("RGB").convert("P", palette=Image.ADAPTIVE, colors=8)
    mask = Image.eval(alpha, lambda a: 255 if a < 128 else 0)
    q.paste(7, mask)
    pal.append(q)
pal[0].save(sys.argv[1], save_all=True, append_images=pal[1:], duration=[180, 180, 180, 180, 180, 900],
            loop=0, transparency=7, disposal=2)
