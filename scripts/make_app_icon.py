"""
Generates the Parley app icon (1024x1024, no transparency, as App Store Connect requires):
an indigo -> violet -> coral gradient with a white speech bubble holding a sound wave.

    python scripts/make_app_icon.py
"""
import os

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
OUT = os.path.join(os.path.dirname(__file__), "..", "ios", "Parley", "Resources", "Assets.xcassets",
                   "AppIcon.appiconset", "AppIcon.png")
STOPS = [(0.0, (75, 59, 208)), (0.55, (163, 75, 216)), (1.0, (255, 122, 133))]


def lerp(a, b, t):
    return tuple(int(round(x + (y - x) * t)) for x, y in zip(a, b))


def gradient_color(t):
    for (t0, c0), (t1, c1) in zip(STOPS, STOPS[1:]):
        if t <= t1:
            return lerp(c0, c1, (t - t0) / (t1 - t0))
    return STOPS[-1][1]


def main():
    # Diagonal gradient, computed on a small image and scaled up (smooth and fast).
    small = 256
    g = Image.new("RGB", (small, small))
    px = g.load()
    for y in range(small):
        for x in range(small):
            px[x, y] = gradient_color((x + y) / (2 * (small - 1)))
    img = g.resize((SIZE, SIZE), Image.BICUBIC)

    # Soft glow behind the bubble
    glow = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(glow).ellipse((170, 150, 854, 834), fill=110)
    glow = glow.filter(ImageFilter.GaussianBlur(90))
    img = Image.composite(Image.new("RGB", (SIZE, SIZE), (255, 255, 255)), img, glow.point(lambda v: v // 3))

    # Speech bubble with a tail (drawn at 4x then downsampled for clean edges)
    S = 4
    mask = Image.new("L", (SIZE * S, SIZE * S), 0)
    d = ImageDraw.Draw(mask)
    box = (196 * S, 214 * S, 828 * S, 742 * S)
    d.rounded_rectangle(box, radius=170 * S, fill=255)
    d.polygon([(300 * S, 690 * S), (262 * S, 846 * S), (450 * S, 724 * S)], fill=255)
    mask = mask.resize((SIZE, SIZE), Image.LANCZOS)
    shadow = mask.filter(ImageFilter.GaussianBlur(26)).point(lambda v: int(v * 0.35))
    img = Image.composite(Image.new("RGB", (SIZE, SIZE), (40, 22, 110)), img,
                          shadow.transform(shadow.size, Image.AFFINE, (1, 0, 0, 0, 1, -18)))
    img = Image.composite(Image.new("RGB", (SIZE, SIZE), (255, 255, 255)), img, mask)

    # Sound wave: five rounded bars filled with the gradient
    bars = Image.new("L", (SIZE * S, SIZE * S), 0)
    db = ImageDraw.Draw(bars)
    heights = [150, 290, 400, 260, 170]
    cx, cy, w, gap = 512, 478, 58, 40
    x0 = cx - (len(heights) * w + (len(heights) - 1) * gap) / 2
    for i, h in enumerate(heights):
        x = x0 + i * (w + gap)
        db.rounded_rectangle(((x) * S, (cy - h / 2) * S, (x + w) * S, (cy + h / 2) * S), radius=w / 2 * S, fill=255)
    bars = bars.resize((SIZE, SIZE), Image.LANCZOS)
    img = Image.composite(g.resize((SIZE, SIZE), Image.BICUBIC), img, bars)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    img.convert("RGB").save(OUT, "PNG", optimize=True)
    print("wrote", os.path.abspath(OUT))


if __name__ == "__main__":
    main()
