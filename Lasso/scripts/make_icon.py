#!/usr/bin/env python3
"""Renders the Lasso app icon (1024x1024 PNG) on the macOS icon grid.

A dark squircle with a glowing gradient progress ring (the "lasso") around a glass play button.
Usage: python3 make_icon.py <output.png>
"""
import math
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 2048                  # supersampled canvas, downscaled to 1024 at the end
INSET = 200               # macOS grid: 824/1024 body
R = (S - 2 * INSET) / 2
C = S / 2
YY, XX = np.mgrid[0:S, 0:S].astype(np.float32)


def squircle_points(r=R, n=5.0, steps=1440):
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        pts.append((C + abs(c) ** (2 / n) * r * (1 if c >= 0 else -1), C + abs(s) ** (2 / n) * r * (1 if s >= 0 else -1)))
    return pts


def mask_from(draw_fn):
    m = Image.new("L", (S, S), 0)
    draw_fn(ImageDraw.Draw(m))
    return m


def interp(t, stops):
    out = np.zeros(t.shape + (3,), np.float32)
    for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
        sel = (t >= p0) & (t <= p1)
        f = ((t - p0) / max(1e-6, p1 - p0))[..., None]
        out = np.where(sel[..., None], np.array(c0) * (1 - f) + np.array(c1) * f, out)
    return out


def linear(stops, angle):
    a = math.radians(angle)
    t = XX * math.cos(a) + YY * math.sin(a)
    return interp((t - t.min()) / (t.max() - t.min()), stops)


def conic(stops, start_deg=-90):
    t = (np.degrees(np.arctan2(YY - C, XX - C)) - start_deg) % 360 / 360
    return interp(t, stops)


def glow(arr, cx, cy, radius, color, strength):
    d = np.sqrt((XX - cx) ** 2 + (YY - cy) ** 2) / radius
    a = (np.clip(1 - d, 0, 1) ** 2 * strength)[..., None]
    return arr * (1 - a) + np.array(color, np.float32) * a


def rgba(arr, alpha):
    im = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB").convert("RGBA")
    im.putalpha(alpha)
    return im


def solid(color, alpha):
    im = Image.new("RGBA", (S, S), color + (0,))
    im.putalpha(alpha)
    return im


def scale_alpha(mask, factor):
    return Image.fromarray((np.asarray(mask, np.float32) * factor).clip(0, 255).astype(np.uint8))


def sharp_round(mask, radius):
    """Rounds corners of a hard mask while keeping a crisp, anti-aliased edge."""
    blurred = np.asarray(mask.filter(ImageFilter.GaussianBlur(radius)), np.float32)
    return Image.fromarray(np.clip((blurred - 128) * 18 + 128, 0, 255).astype(np.uint8))


def shifted(img, dx, dy):
    return img.transform((S, S), Image.AFFINE, (1, 0, -dx, 0, 1, -dy))


def main(out):
    body_mask = mask_from(lambda d: d.polygon(squircle_points(), fill=255))

    # Background: deep indigo with soft colour blooms.
    bg = linear([(0, (34, 34, 66)), (0.55, (18, 17, 38)), (1, (8, 8, 18))], 90)
    bg = glow(bg, C - 420, C - 520, 1000, (60, 110, 220), 0.35)
    bg = glow(bg, C + 520, C + 560, 900, (200, 50, 150), 0.30)
    layers = [rgba(bg, Image.new("L", (S, S), 255))]

    # Ring track (faint full circle).
    ring_r, ring_w = 600, 156
    box = (C - ring_r, C - ring_r, C + ring_r, C + ring_r)
    track = mask_from(lambda d: d.ellipse(box, outline=255, width=ring_w))
    layers.append(solid((255, 255, 255), scale_alpha(track, 0.09)))

    # Progress arc with round caps.
    start, end = -90 + 20, -90 + 302

    def arc(d):
        d.arc(box, start=start, end=end, fill=255, width=ring_w)
        rr = ring_r - ring_w / 2
        for deg in (start, end):
            a = math.radians(deg)
            px, py = C + rr * math.cos(a), C + rr * math.sin(a)
            d.ellipse((px - ring_w / 2, py - ring_w / 2, px + ring_w / 2, py + ring_w / 2), fill=255)

    ring = mask_from(arc)
    ring_colors = conic([(0, (0, 214, 255)), (0.32, (70, 140, 255)), (0.62, (140, 90, 255)),
                         (0.86, (240, 70, 170)), (1, (255, 110, 120))])
    layers.append(solid((120, 100, 255), scale_alpha(ring.filter(ImageFilter.GaussianBlur(70)), 0.55)))
    layers.append(rgba(ring_colors, ring))
    # Glassy highlight on the ring's upper half.
    ring_hl = Image.fromarray((np.asarray(ring, np.float32) * np.clip(1.15 - YY / S * 1.9, 0, 1) * 0.30).astype(np.uint8))
    layers.append(solid((255, 255, 255), ring_hl))

    # Play button.
    h = 500
    cx = C + 34
    tri = mask_from(lambda d: d.polygon([(cx - h * 0.42, C - h / 2), (cx - h * 0.42, C + h / 2), (cx + h * 0.50, C)], fill=255))
    tri = sharp_round(tri, 34)
    layers.append(shifted(solid((10, 0, 30), scale_alpha(tri.filter(ImageFilter.GaussianBlur(28)), 0.55)), 0, 22))
    layers.append(rgba(linear([(0, (255, 255, 255)), (1, (206, 212, 255))], 70), tri))

    body = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    for layer in layers:
        body = Image.alpha_composite(body, layer)
    clipped = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    clipped.paste(body, (0, 0), body_mask)

    # Subtle glass sheen on the top half of the tile.
    sheen = mask_from(lambda d: d.ellipse((C - R * 1.25, C - R * 1.9, C + R * 1.25, C - R * 0.15), fill=255))
    sheen = Image.fromarray((np.asarray(sheen.filter(ImageFilter.GaussianBlur(90)), np.float32)
                             * np.asarray(body_mask, np.float32) / 255 * 0.07).astype(np.uint8))
    clipped = Image.alpha_composite(clipped, solid((255, 255, 255), sheen))

    # Rim light.
    rim = mask_from(lambda d: d.line(squircle_points() + [squircle_points()[0]], fill=255, width=7))
    rim = Image.fromarray((np.asarray(rim, np.float32) * np.clip(1.25 - YY / S * 1.5, 0.12, 1) * 0.4).astype(np.uint8))
    clipped = Image.alpha_composite(clipped, solid((255, 255, 255), rim))

    # Drop shadow under the tile.
    shadow = shifted(solid((0, 0, 0), scale_alpha(body_mask.filter(ImageFilter.GaussianBlur(34)), 0.45)), 0, 22)
    final = Image.alpha_composite(shadow, clipped)
    final.resize((1024, 1024), Image.LANCZOS).save(out)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "AppIcon.png")
