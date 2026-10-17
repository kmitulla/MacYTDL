#!/usr/bin/env python3
"""Renders the MacYTDL app icon (1024x1024 PNG) following the macOS icon grid.

Usage: python3 make_icon.py <output.png>
"""
import math
import sys

from PIL import Image, ImageDraw, ImageFilter

S = 2048            # supersampled canvas, downscaled to 1024 at the end
INSET = 200         # macOS grid: 824/1024 body => 100px margin at 1x
BODY = S - 2 * INSET


def superellipse(cx, cy, r, n=5.0, steps=720):
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        x = abs(c) ** (2 / n) * r * (1 if c >= 0 else -1)
        y = abs(s) ** (2 / n) * r * (1 if s >= 0 else -1)
        pts.append((cx + x, cy + y))
    return pts


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def gradient(size, stops, angle_deg):
    w, h = size
    img = Image.new("RGBA", size)
    px = img.load()
    a = math.radians(angle_deg)
    dx, dy = math.cos(a), math.sin(a)
    proj = [x * dx + y * dy for x, y in ((0, 0), (w, 0), (0, h), (w, h))]
    lo, hi = min(proj), max(proj)
    for y in range(h):
        for x in range(w):
            t = ((x * dx + y * dy) - lo) / (hi - lo)
            for i in range(len(stops) - 1):
                p0, c0 = stops[i]
                p1, c1 = stops[i + 1]
                if p0 <= t <= p1:
                    px[x, y] = lerp(c0, c1, (t - p0) / (p1 - p0))
                    break
    return img


def rounded(alpha, radius):
    """Rounds the corners of a shape mask (blur + threshold), keeping an anti-aliased edge."""
    blurred = alpha.filter(ImageFilter.GaussianBlur(radius))
    return blurred.point(lambda v: max(0, min(255, (v - 128) * 8 + 128)))


def main(out):
    cx = cy = S / 2
    r = BODY / 2
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).polygon(superellipse(cx, cy, r), fill=255)

    # Soft drop shadow below the body.
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sm = Image.new("L", (S, S), 0)
    ImageDraw.Draw(sm).polygon(superellipse(cx, cy + 24, r * 0.98), fill=110)
    shadow.putalpha(sm.filter(ImageFilter.GaussianBlur(36)))

    # Body gradient (computed small, then upscaled for speed).
    g = gradient((256, 256), [
        (0.0, (64, 196, 255, 255)),
        (0.45, (88, 104, 255, 255)),
        (1.0, (176, 60, 230, 255)),
    ], 60).resize((S, S), Image.BICUBIC)
    body = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    body.paste(g, (0, 0), mask)

    # Glow blob (Mica-like light bloom) in the upper-left.
    glow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(glow).ellipse((INSET - 200, INSET - 260, INSET + 1000, INSET + 760), fill=120)
    glow = glow.filter(ImageFilter.GaussianBlur(220))
    white = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    white.putalpha(Image.composite(glow, Image.new("L", (S, S), 0), mask))
    body = Image.alpha_composite(body, white)

    # Glass disc.
    disc_r = 560
    disc = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(disc)
    d.ellipse((cx - disc_r, cy - disc_r, cx + disc_r, cy + disc_r), fill=(255, 255, 255, 52))
    d.ellipse((cx - disc_r, cy - disc_r, cx + disc_r, cy + disc_r), outline=(255, 255, 255, 150), width=14)
    # Specular highlight on the top edge of the disc.
    hl = Image.new("L", (S, S), 0)
    ImageDraw.Draw(hl).ellipse((cx - disc_r + 60, cy - disc_r + 30, cx + disc_r - 60, cy - 40), fill=70)
    hl = hl.filter(ImageFilter.GaussianBlur(40))
    hl_img = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    hl_img.putalpha(hl)
    disc = Image.alpha_composite(disc, hl_img)
    body = Image.alpha_composite(body, disc)

    # Glyph: down arrow above a tray bar, with a soft shadow.
    glyph = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glyph)
    shaft_w = 150
    top = cy - 360
    head_y = cy + 40
    gd.rounded_rectangle((cx - shaft_w / 2, top, cx + shaft_w / 2, head_y + 40), radius=shaft_w / 2, fill=(255, 255, 255, 255))
    head = [(cx - 320, head_y - 135), (cx + 320, head_y - 135), (cx, head_y + 225)]
    gd.polygon(head, fill=(255, 255, 255, 255))
    gd.rounded_rectangle((cx - 330, cy + 290, cx + 330, cy + 400), radius=55, fill=(255, 255, 255, 255))
    glyph_alpha = rounded(glyph.split()[3], 26)
    glyph = Image.new("RGBA", (S, S), (255, 255, 255, 255))
    glyph.putalpha(glyph_alpha)

    gshadow = Image.new("RGBA", (S, S), (20, 10, 80, 0))
    gshadow.putalpha(glyph.split()[3].point(lambda v: v * 0.35).filter(ImageFilter.GaussianBlur(30)))
    gshadow = gshadow.transform((S, S), Image.AFFINE, (1, 0, 0, 0, 1, -24))
    body = Image.alpha_composite(body, gshadow)
    body = Image.alpha_composite(body, glyph)

    # Play badge (top-right) - warm accent.
    bx, by, br = cx + 470, cy - 470, 190
    badge = gradient((64, 64), [(0.0, (255, 170, 60, 255)), (1.0, (255, 70, 120, 255))], 45).resize((int(br * 2), int(br * 2)), Image.BICUBIC)
    bm = Image.new("L", badge.size, 0)
    ImageDraw.Draw(bm).ellipse((0, 0, br * 2 - 1, br * 2 - 1), fill=255)
    bshadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bsm = Image.new("L", (S, S), 0)
    ImageDraw.Draw(bsm).ellipse((bx - br, by - br + 20, bx + br, by + br + 20), fill=90)
    bshadow.putalpha(bsm.filter(ImageFilter.GaussianBlur(24)))
    body = Image.alpha_composite(body, bshadow)
    body.paste(badge, (int(bx - br), int(by - br)), bm)
    bd = ImageDraw.Draw(body)
    bd.ellipse((bx - br, by - br, bx + br, by + br), outline=(255, 255, 255, 170), width=10)
    tri_mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(tri_mask).polygon([(bx - 62, by - 95), (bx - 62, by + 95), (bx + 105, by)], fill=255)
    tri_img = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    tri_img.putalpha(rounded(tri_mask, 14))
    body = Image.alpha_composite(body, tri_img)

    # Inner rim light along the body edge.
    rim = Image.new("L", (S, S), 0)
    ImageDraw.Draw(rim).polygon(superellipse(cx, cy, r), outline=255, width=10)
    rim_img = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    rim_img.putalpha(rim.point(lambda v: v * 0.35))
    body = Image.alpha_composite(body, rim_img)

    final = Image.alpha_composite(shadow, body)
    final = final.resize((1024, 1024), Image.LANCZOS)
    final.save(out)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "AppIcon.png")
