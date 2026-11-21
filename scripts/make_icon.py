"""Genera Resources/AppIcon.png (1024x1024): icona originale di Armonia EQ."""
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 1024
out = sys.argv[1] if len(sys.argv) > 1 else "Resources/AppIcon.png"
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# Sfondo: quadrato arrotondato scuro con leggero gradiente verticale
bg = Image.new("RGBA", (S, S))
d = ImageDraw.Draw(bg)
for y in range(S):
    t = y / S
    d.line([(0, y), (S, y)], fill=(int(22 + 10 * (1 - t)), int(26 + 12 * (1 - t)), int(34 + 16 * (1 - t)), 255))
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([100, 100, S - 100, S - 100], radius=185, fill=255)
img.paste(bg, (0, 0), mask)

# Barre dell'equalizzatore (valori di una curva "a sorriso" gentile)
tracks = Image.new("RGBA", (S, S), (0, 0, 0, 0))
td = ImageDraw.Draw(tracks)
values = [0.55, 0.72, 0.6, 0.42, 0.36, 0.48, 0.66, 0.78, 0.62]
n = len(values)
left, right, top, bottom = 220, S - 220, 250, S - 250
step = (right - left) / (n - 1)
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
points = []
for i, v in enumerate(values):
    x = left + i * step
    y = bottom - v * (bottom - top)
    points.append((x, y))
    td.rounded_rectangle([x - 14, top, x + 14, bottom], radius=14, fill=(255, 255, 255, 30))
    td.rounded_rectangle([x - 14, y, x + 14, bottom], radius=14, fill=(69, 219, 194, 235))
    gd.ellipse([x - 34, y - 34, x + 34, y + 34], fill=(69, 219, 194, 120))
glow = glow.filter(ImageFilter.GaussianBlur(18))
img = Image.alpha_composite(img, tracks)
img = Image.alpha_composite(img, glow)
d = ImageDraw.Draw(img)
d.line(points, fill=(255, 255, 255, 230), width=12, joint="curve")
for x, y in points:
    d.ellipse([x - 22, y - 22, x + 22, y + 22], fill=(255, 255, 255, 255))
    d.ellipse([x - 10, y - 10, x + 10, y + 10], fill=(69, 219, 194, 255))
img.save(out)
print("scritto", out)
