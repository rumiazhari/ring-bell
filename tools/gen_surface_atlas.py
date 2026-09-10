"""Generate the surface detail atlas used by MeshBatcher.

Design notes (read before changing):
  * The city mesh multiplies this atlas by the per-vertex COLOR
    (ALBEDO = tex.rgb * COLOR.rgb), so every tile is drawn as a NEUTRAL
    grey detail map around ~1.0 - the per-box tint supplies the actual
    colour (oak, walnut, ochre plaster, verdigris...). Do not bake colours
    into tiles: they would fight the building palette.
  * 4x4 grid of TILE_PX tiles. MeshBatcher.TILE_* indices must match the
    order below; the shader derives the atlas cell from the tile index.
  * Deterministic: fixed seeds, no time/random-per-run input, so the atlas
    is reproducible and diffable.

Run:  python tools/gen_surface_atlas.py
"""

import os
import random

from PIL import Image, ImageDraw, ImageFilter

TILE_PX = 256
GRID = 4
OUT = os.path.join("world", "streaming", "surface_atlas.png")

# Tile order - keep in sync with MeshBatcher.TILE_* constants.
TILES = [
    "plaster_fine",
    "plaster_coarse",
    "plaster_damaged",
    "brick",
    "stone_rubble",
    "wood_pale",
    "wood_dark",
    "floorboard",
    "tile_checker",
    "cobble",
    "slate",
    "rust_metal",
    "moss",
    "grime",
    "glass",
    "render_grey",
]


def smooth_noise(seed, size, coarse, contrast):
    """Smooth value noise in 0..1 range, built by upscaling a tiny random image."""
    rnd = random.Random(seed)
    small = Image.new("L", (max(2, size // coarse), max(2, size // coarse)))
    small.putdata([rnd.randint(0, 255) for _ in range(small.width * small.height)])
    big = small.resize((size, size), Image.Resampling.BICUBIC)
    return big.point(lambda v: int(128 + (v - 128) * contrast))


def combine(base, noise, strength):
    """Blend two same-size 'L' images; both must match in size."""
    assert base.size == noise.size, (base.size, noise.size)
    return Image.blend(base, noise, strength)


def grain(size, seed, spacing, shade, wiggle=3, horizontal=False):
    """Wood-grain style lines."""
    rnd = random.Random(seed)
    img = Image.new("L", (size, size), 255)
    d = ImageDraw.Draw(img)
    pos = 0
    while pos < size:
        x = pos + rnd.randint(-wiggle, wiggle)
        if horizontal:
            d.line([(0, x), (size, x)], fill=shade, width=1)
        else:
            d.line([(x, 0), (x, size)], fill=shade, width=1)
        pos += spacing + rnd.randint(-1, 2)
    return img


def tile_plaster(seed, base, contrast, blotches=0, blotch_shade=170):
    """Plaster with vertical damp streaks - the give-away of a rotten wall."""
    n = smooth_noise(seed, TILE_PX, 24, contrast)
    img = combine(Image.new("L", (TILE_PX, TILE_PX), base), n, 0.55)
    streak = smooth_noise(seed + 41, TILE_PX, 3, contrast)
    streak = streak.resize((max(4, TILE_PX // 8), TILE_PX), Image.Resampling.BICUBIC).resize(
        (TILE_PX, TILE_PX), Image.Resampling.BICUBIC)
    img = combine(img, streak, 0.4)
    if blotches:
        rnd = random.Random(seed + 77)
        d = ImageDraw.Draw(img)
        for _ in range(blotches):
            cx, cy = rnd.randint(0, TILE_PX), rnd.randint(0, TILE_PX)
            r = rnd.randint(18, 58)
            d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=blotch_shade)
        img = img.filter(ImageFilter.GaussianBlur(3))
    return img


def tile_brick(seed):
    rnd = random.Random(seed)
    img = Image.new("L", (TILE_PX, TILE_PX), 225)  # mortar
    d = ImageDraw.Draw(img)
    bh, bw = 22, 52
    y = 0
    row = 0
    while y < TILE_PX:
        offset = 0 if row % 2 == 0 else bw // 2
        x = -bw + offset
        while x < TILE_PX:
            shade = 165 + rnd.randint(-18, 18)
            d.rectangle([x + 2, y + 2, x + bw - 2, y + bh - 2], fill=shade)
            x += bw
        y += bh
        row += 1
    n = smooth_noise(seed + 5, TILE_PX, 40, 0.5)
    return combine(img, n, 0.3)


def tile_stone(seed):
    rnd = random.Random(seed)
    img = Image.new("L", (TILE_PX, TILE_PX), 120)  # dark mortar
    d = ImageDraw.Draw(img)
    y = 0
    row = 0
    while y < TILE_PX:
        offset = 0 if row % 2 == 0 else 20
        x = -40 + offset
        while x < TILE_PX:
            w = rnd.randint(28, 62)
            h = rnd.randint(16, 24)
            shade = 175 + rnd.randint(-30, 30)
            d.rectangle([x + 3, y + 3, x + w - 3, y + h - 3], fill=shade)
            x += w
        y += 20
        row += 1
    n = smooth_noise(seed + 3, TILE_PX, 30, 0.6)
    return combine(img, n, 0.35)


def tile_wood(seed, base, spacing, shade, horizontal):
    g = grain(TILE_PX, seed, spacing, shade, horizontal=horizontal)
    n = smooth_noise(seed + 9, TILE_PX, 60, 0.35)
    img = combine(Image.new("L", (TILE_PX, TILE_PX), base), g, 0.45)
    return combine(img, n, 0.25)


def tile_floorboard(seed):
    rnd = random.Random(seed)
    img = Image.new("L", (TILE_PX, TILE_PX), 205)
    d = ImageDraw.Draw(img)
    for i in range(0, TILE_PX, 64):  # plank seams
        d.line([(0, i), (TILE_PX, i)], fill=140, width=2)
    g = grain(TILE_PX, seed + 1, 9, 190, wiggle=2, horizontal=True)
    img = combine(img, g, 0.5)
    n = smooth_noise(seed + 4, TILE_PX, 50, 0.3)
    return combine(img, n, 0.25)


def tile_checker(seed):
    img = Image.new("L", (TILE_PX, TILE_PX), 235)
    d = ImageDraw.Draw(img)
    step = 32
    for y in range(0, TILE_PX, step):
        for x in range(0, TILE_PX, step):
            if ((x // step) + (y // step)) % 2 == 0:
                d.rectangle([x, y, x + step - 1, y + step - 1], fill=170)
    n = smooth_noise(seed + 2, TILE_PX, 60, 0.25)
    return combine(img, n, 0.2)


def tile_cobble(seed):
    rnd = random.Random(seed)
    img = Image.new("L", (TILE_PX, TILE_PX), 110)
    d = ImageDraw.Draw(img)
    y = 0
    while y < TILE_PX:
        x = 0
        while x < TILE_PX:
            w = rnd.randint(20, 34)
            h = rnd.randint(18, 28)
            shade = 180 + rnd.randint(-35, 25)
            d.ellipse([x + 2, y + 2, x + w - 2, y + h - 2], fill=shade)
            x += w
        y += 26
    return combine(img, smooth_noise(seed + 6, TILE_PX, 26, 0.5), 0.3)


def tile_slate(seed):
    rnd = random.Random(seed)
    img = Image.new("L", (TILE_PX, TILE_PX), 150)
    d = ImageDraw.Draw(img)
    for row in range(0, TILE_PX, 28):
        offset = 0 if (row // 28) % 2 == 0 else 22
        for x in range(-44 + offset, TILE_PX, 44):
            shade = 165 + rnd.randint(-20, 20)
            d.rectangle([x, row, x + 42, row + 26], fill=shade, outline=125)
    return combine(img, smooth_noise(seed + 8, TILE_PX, 40, 0.35), 0.3)


def tile_rust(seed):
    n = smooth_noise(seed, TILE_PX, 18, 0.9)
    s = smooth_noise(seed + 11, TILE_PX, 90, 0.5)
    img = combine(n, s, 0.4)
    d = ImageDraw.Draw(img)
    rnd = random.Random(seed + 12)
    for _ in range(40):  # pitting
        x, y = rnd.randint(0, TILE_PX), rnd.randint(0, TILE_PX)
        r = rnd.randint(2, 9)
        d.ellipse([x - r, y - r, x + r, y + r], fill=90)
    return img.filter(ImageFilter.GaussianBlur(1))


def tile_moss(seed):
    n = smooth_noise(seed, TILE_PX, 14, 1.1)
    img = combine(Image.new("L", (TILE_PX, TILE_PX), 200), n, 0.7)
    d = ImageDraw.Draw(img)
    rnd = random.Random(seed + 13)
    for _ in range(70):
        x, y = rnd.randint(0, TILE_PX), rnd.randint(0, TILE_PX)
        r = rnd.randint(6, 22)
        d.ellipse([x - r, y - r, x + r, y + r], fill=150 + rnd.randint(-30, 30))
    return img.filter(ImageFilter.GaussianBlur(2))


def tile_grime(seed):
    n = smooth_noise(seed, TILE_PX, 10, 1.0)
    s = smooth_noise(seed + 21, TILE_PX, 70, 0.5)
    return combine(combine(Image.new("L", (TILE_PX, TILE_PX), 210), n, 0.8), s, 0.35)


def tile_glass(seed):
    img = Image.new("L", (TILE_PX, TILE_PX), 235)
    d = ImageDraw.Draw(img)
    rnd = random.Random(seed)
    for _ in range(7):  # faint streaks
        x = rnd.randint(0, TILE_PX)
        d.line([(x, 0), (x + rnd.randint(-30, 30), TILE_PX)], fill=215, width=rnd.randint(1, 3))
    return combine(img, smooth_noise(seed + 31, TILE_PX, 80, 0.2), 0.15)


def build():
    atlas = Image.new("L", (TILE_PX * GRID, TILE_PX * GRID), 128)
    makers = {
        "plaster_fine": lambda: tile_plaster(101, 234, 2.2),
        "plaster_coarse": lambda: tile_plaster(102, 228, 2.6),
        "plaster_damaged": lambda: tile_plaster(103, 226, 2.4, blotches=22, blotch_shade=150),
        "brick": lambda: tile_brick(104),
        "stone_rubble": lambda: tile_stone(105),
        "wood_pale": lambda: tile_wood(106, 226, 7, 178, False),
        "wood_dark": lambda: tile_wood(107, 205, 5, 132, False),
        "floorboard": lambda: tile_floorboard(108),
        "tile_checker": lambda: tile_checker(109),
        "cobble": lambda: tile_cobble(110),
        "slate": lambda: tile_slate(111),
        "rust_metal": lambda: tile_rust(112),
        "moss": lambda: tile_moss(113),
        "grime": lambda: tile_grime(114),
        "glass": lambda: tile_glass(115),
        "render_grey": lambda: tile_plaster(116, 224, 1.8),
    }
    for i, name in enumerate(TILES):
        img = makers[name]()
        assert img.size == (TILE_PX, TILE_PX), (name, img.size)
        cx, cy = (i % GRID) * TILE_PX, (i // GRID) * TILE_PX
        atlas.paste(img, (cx, cy))
    rgb = Image.merge("RGB", (atlas, atlas, atlas))
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    rgb.save(OUT)
    print("wrote %s  %dx%d  tiles=%d" % (OUT, rgb.width, rgb.height, len(TILES)))


if __name__ == "__main__":
    build()
