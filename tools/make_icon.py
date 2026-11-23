"""Draws Open Opal's app icon as an Icon Composer document.

    python3 tools/make_icon.py Assets/AppIcon.icon 5

The icon is an opal seen through a lens. The stone is soft patches of colour
with gaps the background shows through: on the light background it is a white
opal, and on the dark one a black opal. The outer ring, the small inner ring
and a clear dome over the stone are Liquid Glass. The second argument is the
seed for the colours. Add "nopupil" as a third to leave the inner ring out.
Needs Pillow and numpy.

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

# Play of colour: soft patches of hue drifting through the stone, with a finer
# shimmer inside them, and the stone's body showing between.
def equalised(field):
    """Spread values evenly over 0...1, so every colour gets its share."""
    order = field.ravel().argsort().argsort().astype(np.float32)
    return (order / (order.size - 1)).reshape(field.shape)

hue_field = equalised(0.56 * smooth_noise(5, 40) + 0.30 * smooth_noise(11, 14) + 0.14 * smooth_noise(22, 8))
# Opal runs green, teal, blue, violet and pink, with a little warm orange.
stops = [(0.00, (0.16, 0.86, 0.50)), (0.20, (0.05, 0.80, 0.82)), (0.42, (0.12, 0.52, 1.00)),
         (0.62, (0.50, 0.38, 1.00)), (0.80, (0.98, 0.42, 0.76)), (1.00, (1.00, 0.64, 0.28))]
rgb = np.zeros((N, N, 3), np.float32)
for (a, ca), (b, cb) in zip(stops, stops[1:]):
    t = np.clip((hue_field - a) / (b - a), 0, 1)[..., None]
    seg = ((hue_field >= a) & (hue_field <= b))[..., None]
    rgb = np.where(seg, np.array(ca) * (1 - t) + np.array(cb) * t, rgb)

# How strongly the colour shows. Patchy, so it reads as a stone and not a fog.
fire = equalised(0.50 * smooth_noise(7, 26) + 0.32 * smooth_noise(16, 9) + 0.18 * smooth_noise(26, 6))
fire = np.clip((fire - 0.22) / 0.55, 0, 1) ** 1.15
shimmer = smooth_noise(34, 5)
rgb = np.clip(rgb * (0.90 + 0.20 * shimmer[..., None]), 0, 1)

yy, xx = np.mgrid[0:N, 0:N].astype(np.float32)
cx = cy = N / 2
r = np.hypot(xx - cx, yy - cy)
R = 306.0
disc = np.clip((R - r) / 2.0, 0, 1)
# A stone is deeper in the middle, so the colour gathers there and thins at the rim.
depth = np.clip(1 - (r / R) ** 2, 0, 1) ** 0.35
alpha = disc * (0.32 + 0.66 * fire) * (0.58 + 0.42 * depth)

img = np.dstack([rgb, alpha])
Image.fromarray((img * 255).astype(np.uint8), "RGBA").save(out + "/Assets/fire.png")

ring = '''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<path fill="#fff" fill-rule="evenodd" d="M512 152a360 360 0 1 0 0 720a360 360 0 1 0 0-720zM512 212a300 300 0 1 1 0 600a300 300 0 1 1 0-600z"/>
</svg>'''
open(out + "/Assets/ring.svg", "w").write(ring)
pupil = '''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<path fill="#fff" fill-rule="evenodd" d="M512 396a116 116 0 1 0 0 232a116 116 0 1 0 0-232zM512 428a84 84 0 1 1 0 168a84 84 0 1 1 0-168z"/>
</svg>'''
with_pupil = len(sys.argv) <= 3 or sys.argv[3] != "nopupil"
if with_pupil:
    open(out + "/Assets/pupil.svg", "w").write(pupil)
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
                *([{"image-name": "pupil.svg", "name": "pupil", "glass": True,
                    "fill-specializations": [{"value": solid(1, 1, 1)},
                                             {"appearance": "tinted", "value": solid(1, 1, 1)}],
                    "opacity-specializations": [{"value": 0.92}]}] if with_pupil else []),
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
