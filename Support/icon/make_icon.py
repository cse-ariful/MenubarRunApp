"""Generates Support/AppIcon.icns (original design: hammer + green run badge)."""
import os, sys
from PIL import Image, ImageDraw, ImageFilter

S = 2048  # supersampled canvas (final 1024)
k = S / 1024

def sc(*v): return [x * k for x in v]

def vertical_gradient(size, top, bottom):
    w, h = size
    g = Image.new("RGBA", size)
    d = ImageDraw.Draw(g)
    for y in range(h):
        t = y / (h - 1)
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
        d.line([(0, y), (w, y)], fill=c)
    return g

def rounded_mask(box, radius):
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m

canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# Body: macOS icon grid (824pt body in 1024 canvas), soft drop shadow.
body = sc(100, 100, 924, 924)
radius = 185 * k
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle(sc(100, 118, 924, 942), radius=radius, fill=(0, 0, 0, 110))
canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18 * k)))
bg = vertical_gradient((S, S), (52, 60, 82), (22, 26, 38))
canvas.paste(bg, (0, 0), rounded_mask(body, radius))
# subtle top highlight
hl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(hl).rounded_rectangle(body, radius=radius, outline=(255, 255, 255, 28), width=int(4 * k))
canvas.alpha_composite(hl)

# Hammer, drawn upright then rotated.
ham = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(ham)
white = (245, 247, 252, 255)
# handle
d.rounded_rectangle(sc(484, 330, 540, 860), radius=28 * k, fill=white)
# grip
d.rounded_rectangle(sc(474, 650, 550, 870), radius=38 * k, fill=(196, 204, 222, 255))
# head: flat striking face on the left, tapered claw on the right
d.rounded_rectangle(sc(340, 215, 600, 335), radius=22 * k, fill=white)
d.rounded_rectangle(sc(318, 200, 372, 350), radius=16 * k, fill=white)
d.polygon(sc(580, 222, 580, 328, 735, 300, 760, 262), fill=white)
ham = ham.rotate(-35, resample=Image.BICUBIC, center=(512 * k, 512 * k), translate=(-30 * k, -20 * k))
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow.putalpha(ham.getchannel("A").point(lambda a: a * 0.45))
canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14 * k)), (0, int(10 * k)))
canvas.alpha_composite(ham)

# Run badge: knockout ring + green circle + white play triangle.
cx, cy, r = 690 * k, 690 * k, 165 * k
d = ImageDraw.Draw(canvas)
d.ellipse([cx - r - 22 * k, cy - r - 22 * k, cx + r + 22 * k, cy + r + 22 * k], fill=(24, 28, 40, 255))
badge = vertical_gradient((S, S), (76, 217, 100), (36, 168, 72))
m = Image.new("L", (S, S), 0)
ImageDraw.Draw(m).ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)
canvas.paste(badge, (0, 0), m)
t = 78 * k  # triangle half-height
ox = 14 * k  # optical centering
d.polygon([(cx - t * 0.75 + ox, cy - t), (cx - t * 0.75 + ox, cy + t), (cx + t * 0.95 + ox, cy)], fill=(255, 255, 255, 255))

icon = canvas.resize((1024, 1024), Image.LANCZOS)
out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
icon.save(os.path.join(out_dir, "AppIcon.png"))
icon.save(os.path.join(out_dir, "AppIcon.icns"),
          sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
print("wrote", out_dir)
