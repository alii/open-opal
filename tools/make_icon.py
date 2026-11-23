"""Draws Open Opal's app icon as an Icon Composer document.

    python3 tools/make_icon.py Assets/AppIcon.icon 19

The icon is an opal set in a lens ring. The stone is a mosaic of flat flakes,
each flashing one colour, with gaps the background shows through: on the light
background it is a white opal, and on the dark one a black opal. The ring and
a clear dome over the stone are Liquid Glass. The second argument is the seed
for the flakes, and 19 is the one that shipped. Needs Pillow and numpy.

Preview every appearance with the ictool inside Icon Composer:

    ictool Assets/AppIcon.icon --export-image --output-file out.png \\
        --platform macOS --rendition Dark --width 256 --height 256 --scale 2

The renditions are Default, Dark, ClearLight, ClearDark, TintedLight and
TintedDark.
"""
import json, os, sys, colorsys
import numpy as np
from PIL import Image, ImageFilter

out = sys.argv[1]
os.makedirs(out + "/Assets", exist_ok=True)
N = 1024
rng = np.random.default_rng(int(sys.argv[2]) if len(sys.argv) > 2 else 7)

def smooth_noise(cells, blur):
    small = rng.random((cells, cells)).astype(np.float32)
    img = Image.fromarray((small * 255).astype(np.uint8)).resize((N, N), Image.BICUBIC)
    return np.asarray(img.filter(ImageFilter.GaussianBlur(blur)), dtype=np.float32) / 255

# Play of colour. Real opal is not a soft cloud: it is a mosaic of flat flakes,
# each flashing one colour, with the milky or dark body of the stone between.
yy, xx = np.mgrid[0:N, 0:N].astype(np.float32)
cx = cy = N / 2
r = np.hypot(xx - cx, yy - cy)
R = 306.0

K = 78
ang = rng.random(K) * 2 * np.pi
rad = np.sqrt(rng.random(K)) * (R + 30)
sx, sy = cx + rad * np.cos(ang), cy + rad * np.sin(ang)
# Flakes are shards, longer one way than the other, and they roughly line up.
theta = 0.6
ct, st = np.cos(theta), np.sin(theta)
u = (xx * ct + yy * st)
v = (-xx * st + yy * ct) * 2.1
su, sv = sx * ct + sy * st, (-sx * st + sy * ct) * 2.1
best = np.full((N, N), 1e12, np.float32); second = best.copy(); cell = np.zeros((N, N), np.int32)
for k in range(K):
    d = (u - su[k]) ** 2 + (v - sv[k]) ** 2
    closer = d < best
    second = np.where(closer, best, np.minimum(second, d))
    cell = np.where(closer, k, cell)
    best = np.where(closer, d, best)

hue_field = smooth_noise(4, 60)
hue_field = (hue_field - hue_field.min()) / (hue_field.max() - hue_field.min())
# Green and teal lead, blue and violet follow, with a few hot orange flashes.
stops = [(0.00, (0.98, 0.45, 0.16)), (0.14, (0.98, 0.78, 0.20)), (0.30, (0.20, 0.86, 0.45)),
         (0.50, (0.04, 0.80, 0.78)), (0.70, (0.10, 0.50, 1.00)), (0.88, (0.42, 0.34, 0.98)),
         (1.00, (0.86, 0.36, 0.86))]
def colour_at(t):
    for (a, ca), (b, cb) in zip(stops, stops[1:]):
        if t <= b:
            f = (t - a) / (b - a)
            return np.array(ca) * (1 - f) + np.array(cb) * f
    return np.array(stops[-1][1])

rgb = np.zeros((N, N, 3), np.float32)
alpha = np.zeros((N, N), np.float32)
for k in range(K):
    px, py = int(np.clip(sx[k], 0, N - 1)), int(np.clip(sy[k], 0, N - 1))
    t = float(np.clip(hue_field[py, px] + rng.normal(0, 0.27), 0, 1))
    c = colour_at(t)
    strength = rng.random()
    mask = cell == k
    # A sheen across each flake, so it reads as a flat face catching light.
    d = rng.random() * 2 * np.pi
    sheen = 0.5 + 0.5 * np.clip(((xx - sx[k]) * np.cos(d) + (yy - sy[k]) * np.sin(d)) / 70, -1, 1)
    bright = 0.80 + 0.20 * sheen
    rgb[mask] = (np.clip(c[None, :] * bright[mask][:, None] + 0.16 * sheen[mask][:, None], 0, 1))
    alpha[mask] = (0.46 + 0.54 * strength ** 0.7) * (0.84 + 0.16 * sheen[mask])

# A hairline of the stone's body between flakes.
edge = np.clip((np.sqrt(second) - np.sqrt(best)) / 7.0, 0, 1)
alpha *= 0.30 + 0.70 * edge
disc = np.clip((R - r) / 2.0, 0, 1)
alpha *= disc

img = np.dstack([np.clip(rgb, 0, 1), np.clip(alpha, 0, 1)])
tile = Image.fromarray((img * 255).astype(np.uint8), "RGBA").filter(ImageFilter.GaussianBlur(1.4))
tile.save(out + "/Assets/fire.png")

ring = '''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<path fill="#fff" fill-rule="evenodd" d="M512 164a348 348 0 1 0 0 696a348 348 0 1 0 0-696zM512 208a304 304 0 1 1 0 608a304 304 0 1 1 0-608z"/>
</svg>'''
open(out + "/Assets/ring.svg", "w").write(ring)
dome = '''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<circle fill="#fff" cx="512" cy="512" r="304"/>
</svg>'''
open(out + "/Assets/dome.svg", "w").write(dome)

def solid(r, g, b, a=1.0): return {"solid": "srgb:%.5f,%.5f,%.5f,%.5f" % (r, g, b, a)}
def grad(top, bottom):
    return {"linear-gradient": ["srgb:%.5f,%.5f,%.5f,1.00000" % top, "srgb:%.5f,%.5f,%.5f,1.00000" % bottom],
            "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}}}

doc = {
    "fill-specializations": [
        {"value": grad((0.985, 0.980, 0.972), (0.850, 0.885, 0.905))},
        {"appearance": "dark", "value": grad((0.070, 0.085, 0.110), (0.012, 0.016, 0.024))},
    ],
    "groups": [
        {
            "name": "lens",
            "layers": [
                {"image-name": "ring.svg", "name": "ring", "glass": True,
                 "fill-specializations": [{"value": solid(1, 1, 1)},
                                          {"appearance": "dark", "value": solid(0.93, 0.95, 0.98)},
                                          {"appearance": "tinted", "value": solid(1, 1, 1)}]},
            ],
            "shadow": {"kind": "neutral", "opacity": 0.35},
            "translucency": {"enabled": True, "value": 0.45},
            "specular": True,
        },
        {
            "name": "dome",
            "layers": [
                {"image-name": "dome.svg", "name": "dome", "glass": True,
                 "fill-specializations": [{"value": solid(1, 1, 1)}],
                 "opacity-specializations": [{"value": 0.14}, {"appearance": "dark", "value": 0.10}]},
            ],
            "shadow": {"kind": "none", "opacity": 0},
            "translucency": {"enabled": True, "value": 0.9},
            "specular": True,
        },
        {
            "name": "stone",
            "layers": [
                {"image-name": "fire.png", "name": "fire", "glass": False},
            ],
            "shadow": {"kind": "none", "opacity": 0},
            "translucency": {"enabled": False, "value": 0.5},
            "specular": False,
        },
    ],
    "supported-platforms": {"squares": "shared"},
}
json.dump(doc, open(out + "/icon.json", "w"), indent=2)
