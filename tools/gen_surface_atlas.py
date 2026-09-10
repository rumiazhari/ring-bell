"""Generate the surface detail atlas used by MeshBatcher / surface_atlas.gdshader.

Design notes (read before changing):
  * The city mesh multiplies these tiles by the per-vertex COLOR, so tiles are
    drawn as NEUTRAL GREY detail maps: the per-box tint supplies the colour
    (oak, walnut, ochre plaster, verdigris...). Never bake colour into a tile.
  * Tiles are generated at NATIVE resolution with multi-octave noise. The first
    version of this script upscaled 10x10 noise blobs, which is why every
    surface rendered as a blurry smear - do not do that again.
  * EVERY tile is TILEABLE. Noise is built on a wrapping lattice (power-of-two
    resolutions that divide TILE_PX) and blobs/patterns are drawn with periodic
    distance, so there is no seam where a surface repeats.
  * 4 columns x 5 rows of TILE_PX tiles; the shader slices this atlas into a
    Texture2DArray at load (MeshBatcher._atlas_texture_array), so each tile has
    its own mip chain and cannot bleed into its neighbours.
  * Tile ORDER must match MeshBatcher.TILE_* constants exactly.
  * Deterministic: fixed seeds only, so the atlas is reproducible and diffable.

Run:  python tools/gen_surface_atlas.py
"""

import os

import numpy as np
from PIL import Image

TILE_PX = 512
COLS = 4
ROWS = 6
OUT = os.path.join("world", "streaming", "surface_atlas.png")

# Tile order - keep in sync with MeshBatcher.TILE_* constants.
TILES = [
    "plaster_fine",      # 0
    "plaster_coarse",    # 1
    "plaster_damaged",   # 2
    "brick",             # 3
    "stone_rubble",      # 4
    "wood_pale",         # 5
    "wood_dark",         # 6
    "floorboard",        # 7
    "tile_checker",      # 8
    "cobble",            # 9
    "slate",             # 10
    "rust_metal",        # 11
    "moss",              # 12
    "grime",             # 13
    "glass",             # 14
    "render_grey",       # 15
    "setts",             # 16  street surface: small granite setts
    "paving_slab",       # 17  pavement: big stone slabs
    "dirt_ground",       # 18  bare city ground: compacted earth + gravel
    "wallpaper",         # 19  Victorian wall covering, damp-stained
    "grass",             # 20  terrain: grazed meadow / lawn
    "meadow_dry",        # 21  terrain: dry upland grass
    "soil",              # 22  terrain: bare / alluvial soil
    "rock",              # 23  terrain: exposed rock
]

_YY, _XX = np.mgrid[0:TILE_PX, 0:TILE_PX].astype(np.float32)


def rng(seed):
    return np.random.default_rng(seed)


# --------------------------------------------------------------------------- #
# Tileable primitives
# --------------------------------------------------------------------------- #

def pnoise(size, res, seed):
    """Periodic value noise: `res` control points that wrap around `size`.

    res MUST divide size (power-of-two here), otherwise the wrap would band.
    """
    lattice = rng(seed).random((res, res)).astype(np.float32)
    step = res / float(size)
    coords = np.arange(size, dtype=np.float32) * step
    i0 = np.floor(coords).astype(np.int32) % res
    i1 = (i0 + 1) % res
    t = coords - np.floor(coords)
    t = t * t * (3.0 - 2.0 * t)                      # smoothstep
    tx = t[None, :]
    ty = t[:, None]
    a = lattice[np.ix_(i0, i0)]
    b = lattice[np.ix_(i0, i1)]
    c = lattice[np.ix_(i1, i0)]
    d = lattice[np.ix_(i1, i1)]
    top = a * (1.0 - tx) + b * tx
    bot = c * (1.0 - tx) + d * tx
    return top * (1.0 - ty) + bot * ty


def pfbm(size, seed, octaves=6, base_res=4, gain=0.55):
    """Periodic multi-octave noise in ~0..1 (resolutions double, so all wrap)."""
    total = np.zeros((size, size), dtype=np.float32)
    amp, norm, res = 1.0, 0.0, base_res
    for o in range(octaves):
        total += amp * pnoise(size, res, seed + o * 7919)
        norm += amp
        amp *= gain
        res = min(size, res * 2)
    return total / max(norm, 1e-6)


def pdist(cx, cy, size=TILE_PX):
    """Distance to (cx, cy) on a torus: emulates wrapping blobs/stones."""
    dx = np.abs(_XX - cx)
    dy = np.abs(_YY - cy)
    dx = np.minimum(dx, size - dx)
    dy = np.minimum(dy, size - dy)
    return np.sqrt(dx * dx + dy * dy)


def blob(a, cx, cy, radius, mult, softness=1.0):
    """Multiply a disc into the tile, wrapping across the edges."""
    f = np.clip(1.0 - pdist(cx, cy) / max(radius, 1e-3), 0.0, 1.0)
    return a * (1.0 + (mult - 1.0) * (f ** softness))


def grain(size, seed, lo=0.90, hi=1.08):
    """Per-pixel grain, kept periodic by construction (pure noise, no blur)."""
    n = rng(seed).random((size, size)).astype(np.float32)
    return lo + n * (hi - lo)


def to_grey(arr, hi=1.15):
    a = np.clip(np.clip(arr, 0.0, None) / hi, 0.0, 1.0)
    return Image.fromarray((a * 255.0).astype(np.uint8), mode="L")


# --------------------------------------------------------------------------- #
# Tiles
# --------------------------------------------------------------------------- #

def t_plaster(seed, base=0.94, grain_amt=0.07, stains=0.16, trowel=0.12, blotches=0):
    size = TILE_PX
    n = pfbm(size, seed, octaves=7, base_res=4)
    a = base * (1.0 - grain_amt) + (n * 2.0 - 1.0) * grain_amt
    a *= grain(size, seed + 5)
    sweep = np.sin((_XX * 0.055 + _YY * 0.09) + pfbm(size, seed + 11, octaves=3, base_res=4) * 6.0)
    a *= 1.0 - trowel * np.clip(sweep, 0.0, 1.0) * 0.35
    st = pfbm(size, seed + 17, octaves=4, base_res=2)
    a *= 1.0 - stains * np.clip((st - 0.55) * 2.0, 0.0, 1.0)
    r = rng(seed + 100)
    for i in range(blotches):
        cx, cy = r.uniform(0, size, 2)
        a = blob(a, cx, cy, r.uniform(40, 120), 0.72, 1.6)
    return to_grey(a, 1.12)


def t_brick(seed):
    """Running bond with crisp mortar, per-brick tone and grit in the mortar."""
    size = TILE_PX
    bw, bh = 128, 64          # both divide 512 -> wraps exactly
    r = rng(seed)
    a = np.full((size, size), 0.60, dtype=np.float32)          # mortar
    tone = pfbm(size, seed + 3, octaves=5, base_res=16)
    for row in range(size // bh):
        y0 = row * bh
        offset = (bw // 2) if row % 2 else 0
        for col in range(size // bw):
            x0 = (col * bw + offset) % size
            xs, xe = x0 + 3, x0 + bw - 3
            if xe > size:                                       # wrap the brick
                parts = [(xs, size), (0, xe - size)]
            else:
                parts = [(xs, xe)]
            for (px0, px1) in parts:
                if px1 <= px0:
                    continue
                shade = 0.76 + r.uniform(-0.12, 0.12)
                patch = np.full((bh - 6, px1 - px0), shade, dtype=np.float32)
                patch *= tone[y0 + 3:y0 + bh - 3, px0:px1] * 0.35 + 0.65
                a[y0 + 3:y0 + bh - 3, px0:px1] = patch
    a *= grain(size, seed + 9, 0.90, 1.10)
    a *= 1.0 - 0.10 * (_YY / size)                              # damp at the base
    return to_grey(a, 1.12)


def t_stone(seed):
    """Coursed rubble: irregular blocks, dark mortar, gritty faces."""
    size = TILE_PX
    r = rng(seed)
    a = np.full((size, size), 0.42, dtype=np.float32)
    tone = pfbm(size, seed + 3, octaves=5, base_res=8)
    y = 0
    rows = []
    while y < size:                      # rows that tile: pick 64/80 heights
        h = int(r.choice([64, 80, 128]))
        rows.append((y, h))
        y += h
        if y >= size:
            break
    # Force the last row to end exactly at the tile edge for a clean wrap.
    if rows and rows[-1][0] + rows[-1][1] != size:
        rows[-1] = (rows[-1][0], size - rows[-1][0])
    for (y0, h) in rows:
        x = 0
        while x < size:
            w = int(r.choice([64, 96, 128, 160]))
            x0 = x
            x1 = min(x + w, size)
            shade = 0.80 + r.uniform(-0.16, 0.14)
            block = np.full((max(h - 8, 1), max(x1 - x0 - 8, 1)), shade, dtype=np.float32)
            ys, xs = y0 + 4, x0 + 4
            ye, xe = min(ys + block.shape[0], size), min(xs + block.shape[1], size)
            if ye > ys and xe > xs:
                a[ys:ye, xs:xe] = block[:ye - ys, :xe - xs] * (tone[ys:ye, xs:xe] * 0.35 + 0.65)
            x += w
    a *= grain(size, seed + 6, 0.88, 1.10)
    return to_grey(a, 1.14)


def t_wood(seed, base, contrast, plank=None):
    """Grain stretched along the grain axis, rings modulated by noise."""
    size = TILE_PX
    gr = pfbm(size, seed, octaves=6, base_res=4)
    stretched = pfbm(size, seed + 41, octaves=5, base_res=8)
    gr = np.clip(gr * 0.55 + stretched * 0.45, 0.0, 1.0)
    # Ring frequency MUST be an integer number of cycles across the tile, or the
    # sine does not wrap and every plank shows a hard seam (measured: wrap step
    # 17-21 vs internal steps of ~8). k=24 keeps the ring pitch about the same.
    ring_freq = (2.0 * np.pi * 24.0) / size
    rings = np.sin((_YY * ring_freq) + gr * 20.0) * 0.5 + 0.5
    a = base + (gr - 0.5) * contrast + (rings - 0.5) * contrast * 0.6
    a *= grain(size, seed + 7, 0.94, 1.06)
    if plank:
        r = rng(seed + 13)
        for i in range(0, size, plank):        # plank divides 512 -> wraps
            a[i:i + 2, :] *= 0.66
            a[(i - 1) % size, :] *= 0.90
            a[i:i + plank, :] *= 1.0 + r.uniform(-0.06, 0.06)
            if r.random() < 0.75:
                a = blob(a, r.uniform(0, size), i + r.uniform(14, plank - 14), 10.0, 0.62, 1.2)
    return to_grey(a, 1.18)


def t_checker(seed):
    """Marble checker with veining in the light squares and grout lines."""
    step = 64
    dark = ((_XX // step).astype(np.int32) + (_YY // step).astype(np.int32)) % 2 == 0
    a = np.where(dark, 0.66, 0.96).astype(np.float32)
    vein = pfbm(TILE_PX, seed + 2, octaves=6, base_res=4)
    a *= np.where(dark, 1.0, 0.86 + vein * 0.28)
    a *= grain(TILE_PX, seed + 6, 0.96, 1.04)
    a[(_XX % step) < 3] *= 0.70
    a[(_YY % step) < 3] *= 0.70
    return to_grey(a, 1.12)


def t_cobble(seed, cells=8, jitter=0.22, joint=0.38):
    """Rounded stones laid on a jittered cell grid; wraps by construction."""
    size = TILE_PX
    r = rng(seed)
    a = np.full((size, size), joint, dtype=np.float32)
    cell = size // cells
    for gy in range(cells):
        for gx in range(cells):
            cx = (gx + 0.5 + r.uniform(-jitter, jitter)) * cell
            cy = (gy + 0.5 + r.uniform(-jitter, jitter)) * cell
            rad = cell * r.uniform(0.40, 0.50)
            shade = 0.80 + r.uniform(-0.14, 0.16)
            d = pdist(cx % size, cy % size)
            bevel = 1.0 - 0.30 * np.clip((d / rad - 0.30) / 0.70, 0.0, 1.0)
            a = np.where(d <= rad, shade * bevel, a)
    a *= grain(size, seed + 8, 0.86, 1.12)
    a *= 1.0 - 0.14 * pfbm(size, seed + 15, octaves=4, base_res=4)
    return to_grey(a, 1.12)


def t_slab(seed):
    """Large pavement slabs, hard joints, chips, worn tops."""
    size = TILE_PX
    r = rng(seed)
    sw, sh = 256, 128
    a = np.full((size, size), 0.50, dtype=np.float32)
    for ry in range(size // sh):
        off = sw // 2 if ry % 2 else 0
        for rx in range(size // sw):
            x0 = (rx * sw + off) % size
            shade = 0.87 + r.uniform(-0.09, 0.09)
            for (px0, px1) in (((x0 + 3, min(x0 + sw - 3, size)),) if x0 + sw - 3 <= size
                               else ((x0 + 3, size), (0, x0 + sw - 3 - size))):
                if px1 > px0:
                    a[ry * sh + 3:ry * sh + sh - 3, px0:px1] = shade
            if r.random() < 0.40:                    # chipped corner
                a = blob(a, x0 + 6, ry * sh + 6, 16.0, 0.74, 1.4)
    a *= grain(size, seed + 12, 0.92, 1.08)
    a *= 1.0 - 0.16 * pfbm(size, seed + 19, octaves=5, base_res=4)
    return to_grey(a, 1.12)


def t_dirt(seed):
    """Compacted earth, gravel, scuffs - the city's bare ground."""
    size = TILE_PX
    n = pfbm(size, seed, octaves=7, base_res=4)
    a = 0.80 + (n - 0.5) * 0.34
    a *= grain(size, seed + 3, 0.80, 1.12)
    r = rng(seed + 23)
    for _ in range(150):            # gravel
        a = blob(a, r.uniform(0, size), r.uniform(0, size), r.uniform(2, 7), 1.25, 1.0)
    for _ in range(7):              # scuffs / ruts
        cx, cy = r.uniform(0, size, 2)
        a = blob(a, cx, cy, r.uniform(10, 26), 0.80, 1.2)
    return to_grey(a, 1.18)


def t_slate(seed):
    size = TILE_PX
    r = rng(seed)
    sw, sh = 128, 64
    a = np.full((size, size), 0.50, dtype=np.float32)
    for ry in range(size // sh):
        off = sw // 2 if ry % 2 else 0
        for rx in range(size // sw):
            x0 = (rx * sw + off) % size
            shade = 0.72 + r.uniform(-0.12, 0.12)
            for (px0, px1) in (((x0 + 2, min(x0 + sw - 2, size)),) if x0 + sw - 2 <= size
                               else ((x0 + 2, size), (0, x0 + sw - 2 - size))):
                if px1 > px0:
                    a[ry * sh + 2:ry * sh + sh - 2, px0:px1] = shade
    a *= grain(size, seed + 6, 0.90, 1.10)
    return to_grey(a, 1.12)


def t_rust(seed):
    size = TILE_PX
    n = pfbm(size, seed, octaves=7, base_res=4)
    a = 0.55 + (n - 0.5) * 0.5
    a *= grain(size, seed + 4, 0.72, 1.15)
    r = rng(seed + 8)
    for _ in range(180):            # flaking patches
        a = blob(a, r.uniform(0, size), r.uniform(0, size), r.uniform(3, 16),
                 r.uniform(0.62, 0.88), 1.0)
    return to_grey(a, 1.10)


def t_moss(seed):
    size = TILE_PX
    n = pfbm(size, seed, octaves=6, base_res=4)
    a = 0.55 + (n - 0.5) * 0.7
    a *= grain(size, seed + 2, 0.85, 1.12)
    r = rng(seed + 2)
    for _ in range(200):            # clumps
        a = blob(a, r.uniform(0, size), r.uniform(0, size), r.uniform(6, 34),
                 r.uniform(0.75, 1.18), 1.1)
    return to_grey(a, 1.15)


def t_grime(seed):
    size = TILE_PX
    n = pfbm(size, seed, octaves=7, base_res=4)
    return to_grey((0.72 + (n - 0.5) * 0.5) * grain(size, seed + 3, 0.72, 1.10), 1.15)


def t_glass(seed):
    size = TILE_PX
    n = pfbm(size, seed, octaves=5, base_res=4)
    a = 0.92 + (n - 0.5) * 0.06
    a *= grain(size, seed + 5, 0.985, 1.015)
    r = rng(seed + 9)
    for _ in range(26):             # grime films
        a = blob(a, r.uniform(0, size), r.uniform(0, size), r.uniform(10, 60), 0.90, 1.3)
    return to_grey(a, 1.02)


def t_grass(seed, blades=2600, base=0.72, tuft=0.34):
    """Clumpy grass: mid-frequency clumps plus individual blades so it reads as
    vegetation up close instead of a green blur."""
    size = TILE_PX
    n = pfbm(size, seed, octaves=6, base_res=4)
    a = base + (n - 0.5) * tuft
    a *= grain(size, seed + 3, 0.86, 1.14)
    r = rng(seed + 7)
    for _ in range(blades):
        x = r.uniform(0, size)
        y = r.uniform(0, size)
        ln = r.uniform(3.5, 10.0)
        lean = r.uniform(-1.6, 1.6)
        shade = r.uniform(0.80, 1.22)
        steps = int(ln)
        for k in range(steps):
            xx = int(x + lean * k / max(steps, 1)) % size
            yy = int(y + k) % size
            a[yy, xx] *= shade
    # Clump shading on top of the blades.
    for _ in range(120):
        a = blob(a, r.uniform(0, size), r.uniform(0, size), r.uniform(12, 46),
                 r.uniform(0.86, 1.14), 1.3)
    return to_grey(a, 1.22)


def t_soil(seed):
    """Bare / alluvial soil: fine tilth, pebbles, damp patches."""
    size = TILE_PX
    n = pfbm(size, seed, octaves=7, base_res=4)
    a = 0.78 + (n - 0.5) * 0.36
    a *= grain(size, seed + 4, 0.82, 1.12)
    r = rng(seed + 9)
    for _ in range(140):
        a = blob(a, r.uniform(0, size), r.uniform(0, size), r.uniform(2, 9),
                 r.uniform(0.72, 1.20), 1.0)
    damp = pfbm(size, seed + 21, octaves=4, base_res=2)
    a *= 1.0 - 0.22 * np.clip((damp - 0.5) * 2.0, 0.0, 1.0)
    return to_grey(a, 1.18)


def t_rock(seed):
    """Exposed rock: fracture lines, mineral speckle, weathered plates."""
    size = TILE_PX
    n = pfbm(size, seed, octaves=6, base_res=4)
    cracks = np.abs(pfbm(size, seed + 27, octaves=5, base_res=3) - 0.5)
    a = 0.72 + (n - 0.5) * 0.34
    a *= 1.0 - 0.45 * np.clip(1.0 - cracks * 14.0, 0.0, 1.0)      # dark fissures
    a *= grain(size, seed + 5, 0.82, 1.16)
    r = rng(seed + 11)
    for _ in range(70):
        a = blob(a, r.uniform(0, size), r.uniform(0, size), r.uniform(6, 28),
                 r.uniform(0.86, 1.16), 1.3)
    return to_grey(a, 1.20)


def t_wallpaper(seed, period=128):
    """Victorian wall covering: stripe groups, damask diamonds, rising damp,
    torn patches. The strongest 'period interior' surface cue there is."""
    size = TILE_PX
    a = np.full((size, size), 0.94, dtype=np.float32)
    band = _XX % period
    a *= np.where(band < period * 0.30, 0.78, 1.0)
    a *= np.where((band > period * 0.42) & (band < period * 0.48), 0.87, 1.0)
    a *= np.where((band > period * 0.62) & (band < period * 0.68), 0.87, 1.0)
    cell = period
    row = (_YY // (cell * 0.5)).astype(np.int32)
    shifted = (_XX + (row % 2) * (cell * 0.5)) % cell
    dd = np.abs(shifted - cell * 0.5) + np.abs((_YY % (cell * 0.5)) - cell * 0.25)
    a *= np.where(dd < cell * 0.15, 0.80, 1.0)
    a *= grain(size, seed + 4, 0.95, 1.04)
    st = pfbm(size, seed + 13, octaves=5, base_res=4)
    rising = np.clip(1.0 - (_YY / size) * 1.6, 0.0, 1.0)
    a *= 1.0 - 0.30 * rising * np.clip((st - 0.35) * 1.6, 0.0, 1.0)
    r = rng(seed + 17)
    for _ in range(5):
        a = blob(a, r.uniform(0, size), r.uniform(0, size), r.uniform(20, 70), 0.70, 1.4)
    return to_grey(a, 1.10)


BUILDERS = {
    "plaster_fine": lambda: t_plaster(101, 0.94, 0.07, 0.16, 0.12),
    "plaster_coarse": lambda: t_plaster(102, 0.92, 0.12, 0.24, 0.20),
    "plaster_damaged": lambda: t_plaster(103, 0.90, 0.16, 0.40, 0.26, blotches=10),
    "brick": lambda: t_brick(104),
    "stone_rubble": lambda: t_stone(105),
    "wood_pale": lambda: t_wood(106, 0.92, 0.20),
    "wood_dark": lambda: t_wood(107, 0.80, 0.28),
    "floorboard": lambda: t_wood(108, 0.88, 0.24, plank=128),
    "tile_checker": lambda: t_checker(109),
    "cobble": lambda: t_cobble(110, cells=8, jitter=0.22, joint=0.38),
    "slate": lambda: t_slate(111),
    "rust_metal": lambda: t_rust(112),
    "moss": lambda: t_moss(113),
    "grime": lambda: t_grime(114),
    "glass": lambda: t_glass(115),
    "render_grey": lambda: t_plaster(116, 0.90, 0.11, 0.20, 0.16),
    "setts": lambda: t_cobble(117, cells=10, jitter=0.16, joint=0.32),
    "paving_slab": lambda: t_slab(118),
    "dirt_ground": lambda: t_dirt(119),
    "wallpaper": lambda: t_wallpaper(120),
    "grass": lambda: t_grass(121),
    "meadow_dry": lambda: t_grass(122, blades=1800, base=0.78, tuft=0.42),
    "soil": lambda: t_soil(123),
    "rock": lambda: t_rock(124),
}


## Tiles MULTIPLY the per-box tint, so a tile whose average is 0.45 darkens the
## whole world by half and crushes the detail into black (measured: the city
## ground rendered near-black because GROUND_COLOR is already 0.30). Every tile
## is therefore normalised to a bright, low-contrast detail map: mean ~0.92 with
## its own structure carrying only +-0.11. Overrides keep deliberately smooth or
## bright surfaces in character.
NORMALISE = {
    "glass": (1.0, 0.04),
    "plaster_fine": (0.95, 0.09),
    "plaster_coarse": (0.94, 0.11),
    "plaster_damaged": (0.92, 0.14),
    "render_grey": (0.93, 0.11),
    "wallpaper": (0.94, 0.13),
    "grass": (0.90, 0.15),
    "meadow_dry": (0.91, 0.15),
}
## Contrast note: ground/paving tints in the city are mid-dark greys, and a
## detail map only reads if its modulation survives the tint multiply. At 0.11
## std the city ground measured high-frequency energy 0.61 (invisible); 0.15
## keeps surfaces legible without looking like noise.
NORMALISE_DEFAULT = (0.92, 0.15)


def normalise(img, mean, std):
    """Rescale a tile to a target mean/std so it MODULATES the tint instead of
    darkening it. Clipped to keep a sane range for a multiply detail map."""
    a = np.asarray(img, dtype=np.float32) / 255.0
    cur_mean = float(a.mean())
    cur_std = float(a.std())
    a = (a - cur_mean) / max(cur_std, 1e-3) * std + mean
    # Clip to 1.0: a uint8 cast of anything above it WRAPS (293 -> 37) and
    # corrupts the tile into noise.
    a = np.clip(a, 0.30, 1.0)
    return Image.fromarray((a * 255.0).astype(np.uint8), mode="L")


def build():
    atlas = Image.new("L", (TILE_PX * COLS, TILE_PX * ROWS), 128)
    for i, name in enumerate(TILES):
        img = BUILDERS[name]()
        assert img.size == (TILE_PX, TILE_PX), (name, img.size)
        target_mean, target_std = NORMALISE.get(name, NORMALISE_DEFAULT)
        img = normalise(img, target_mean, target_std)
        atlas.paste(img, ((i % COLS) * TILE_PX, (i // COLS) * TILE_PX))
    rgb = Image.merge("RGB", (atlas, atlas, atlas))
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    rgb.save(OUT)
    print("wrote %s  %dx%d  tiles=%d (%d per row)" % (
        OUT, rgb.width, rgb.height, len(TILES), COLS))


if __name__ == "__main__":
    build()
