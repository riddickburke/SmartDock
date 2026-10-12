"""Generates the SmartDock icon set:
   icon.png, icon-dark.png, icon-clear.png  - flat 1024px previews (icon.png feeds the .icns)
   SmartDock.icon/                          - layered Icon Composer package (Xcode 26+), the system
                                              derives Dark / Clear / Tinted from the glyph layer
   Run: python3 make_icon.py   (needs Pillow)"""
import json, os, shutil
from PIL import Image, ImageDraw, ImageFilter

S = 3
N = 1024 * S
sc = lambda v: int(v * S)

def stroke_line(d, pts, w, fill):
    """Polyline with round caps/joins."""
    for a, b in zip(pts, pts[1:]):
        d.line([(sc(a[0]), sc(a[1])), (sc(b[0]), sc(b[1]))], fill=fill, width=sc(w))
    for p in pts:
        r = w / 2 + 0.6
        d.ellipse([sc(p[0] - r), sc(p[1] - r), sc(p[0] + r), sc(p[1] + r)], fill=fill)

def glyph_layer(color, bar_color=None):
    """Down-arrow landing on a bar (the Dock). Transparent background."""
    layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    stroke_line(d, [(512, 255), (512, 640)], 118, color)                    # shaft
    stroke_line(d, [(335, 470), (512, 650), (689, 470)], 118, color)        # head
    stroke_line(d, [(330, 785), (694, 785)], 98, bar_color or color)        # dock bar
    return layer

def body_mask(m=100, r=185):
    mask = Image.new("L", (N, N), 0)
    ImageDraw.Draw(mask).rounded_rectangle([sc(m), sc(m), sc(1024 - m), sc(1024 - m)], radius=sc(r), fill=255)
    return mask

def vgrad(top, bot, a_top=255, a_bot=255):
    g = Image.new("RGBA", (N, N))
    d = ImageDraw.Draw(g)
    for y in range(N):
        t = y / (N - 1)
        c = tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)) + (int(a_top + (a_bot - a_top) * t),)
        d.line([(0, y), (N, y)], fill=c)
    return g

def drop_shadow(mask, strength=120):
    sh = Image.new("L", (N, N), 0)
    sh.paste(mask.transform(mask.size, Image.AFFINE, (1, 0, 0, 0, 1, -sc(14))), (0, 0))
    sh = sh.point(lambda v: int(v * strength / 255)).filter(ImageFilter.GaussianBlur(sc(14)))
    out = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    out.putalpha(sh)
    return out

def finish(img, path):
    img.resize((1024, 1024), Image.LANCZOS).save(path)

def make_default():
    mask = body_mask()
    img = drop_shadow(mask)
    body = vgrad((38, 36, 98), (24, 150, 160))
    img.paste(body, (0, 0), mask)
    img = Image.alpha_composite(img, glyph_layer((255, 255, 255, 255)))
    finish(img, "icon.png")

def make_dark():
    mask = body_mask()
    img = drop_shadow(mask, 160)
    body = vgrad((52, 52, 62), (14, 14, 18))
    img.paste(body, (0, 0), mask)
    img = Image.alpha_composite(img, glyph_layer((110, 226, 232, 255), (235, 235, 240, 255)))
    finish(img, "icon-dark.png")

def make_clear():
    """Frosted-glass look on a transparent background (what macOS 'Clear' style resembles)."""
    mask = body_mask()
    body = vgrad((255, 255, 255), (255, 255, 255), 78, 26)
    img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    img.paste(body, (0, 0), mask)
    # rim light
    rim = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(rim).rounded_rectangle([sc(100), sc(100), sc(924), sc(924)], radius=sc(185),
                                          outline=(255, 255, 255, 150), width=sc(6))
    img = Image.alpha_composite(img, rim)
    img = Image.alpha_composite(img, glyph_layer((255, 255, 255, 245)))
    finish(img, "icon-clear.png")

def make_icon_package():
    pkg = "SmartDock.icon"
    shutil.rmtree(pkg, ignore_errors=True)
    os.makedirs(os.path.join(pkg, "Assets"))
    g = glyph_layer((255, 255, 255, 255)).resize((1024, 1024), Image.LANCZOS)
    g.save(os.path.join(pkg, "Assets", "glyph.png"))
    doc = {
        "fill-specializations": [
            {"value": {"automatic-gradient": "extended-srgb:0.09000,0.55000,0.60000,1.00000"}},
            {"appearance": "dark", "value": {"solid": "extended-srgb:0.08000,0.08000,0.10000,1.00000"}},
        ],
        "groups": [{
            "layers": [{"image-name": "glyph.png", "name": "glyph", "glass": True}],
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "translucency": {"enabled": True, "value": 0.4},
        }],
        "supported-platforms": {"squares": "shared"},
    }
    with open(os.path.join(pkg, "icon.json"), "w") as f:
        json.dump(doc, f, indent=2)

make_default(); make_dark(); make_clear(); make_icon_package()
print("icons generated")
