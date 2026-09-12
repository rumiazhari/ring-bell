"""Render floor plans from out_floorplans/plans.json to PNG sheets.

Top-down diagnostic view: room fills by kind, kind+index labels, partition walls
with their door openings, the stair shaft, facade (window) edges, the entrance,
the footprint outline and a scale bar. No engine needed.

    python .hermes/tools/render_floorplans.py                 # all plans, one PNG per floor
    python .hermes/tools/render_floorplans.py --sheet         # + contact sheets
    python .hermes/tools/render_floorplans.py --only narrow   # filter by footprint name
"""
import json
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

SRC = "out_floorplans/plans.json"
OUT = ".hermes/out/floorplans"
SCALE = 26.0          # pixels per metre
PAD = 26
BG = (250, 250, 250)
WALL = (40, 40, 40)
PART = (70, 70, 70)
OPEN = (255, 255, 255)
FACADE = (30, 140, 60)
CORE = (170, 30, 170)
ENTRY = (200, 30, 30)

KIND_FILL = {
    "corridor": (232, 232, 232),
    "stair_hall": (216, 216, 230),
    "hall": (243, 238, 222),
    "lobby": (243, 238, 222),
    "living": (255, 226, 176),
    "sleeping": (212, 230, 255),
    "kitchen": (255, 210, 190),
    "toilet": (196, 226, 220),
    "storage": (230, 222, 200),
    "store_room": (230, 222, 200),
    "toolstore": (230, 222, 200),
    "archive": (230, 222, 200),
    "office": (224, 236, 212),
    "meeting": (224, 236, 212),
    "reception": (224, 236, 212),
    "council": (224, 236, 212),
    "ward": (224, 236, 212),
    "surgery": (224, 236, 212),
    "dispensary": (224, 236, 212),
    "holding": (224, 236, 212),
    "sales": (224, 236, 212),
    "workshop": (220, 212, 236),
    "craft": (220, 212, 236),
    "machine_shop": (220, 212, 236),
    "warehouse": (220, 212, 236),
    "loading": (220, 212, 236),
    "taproom": (255, 200, 170),
}
DEFAULT_FILL = (240, 240, 240)


def font(size):
    for name in ("arial.ttf", "segoeui.ttf", "DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


def rect_of(d):
    return (float(d["x"]), float(d["y"]), float(d["x"]) + float(d["w"]), float(d["y"]) + float(d["h"]))


def rect4(v):
    return (float(v[0]), float(v[1]), float(v[0]) + float(v[2]), float(v[1]) + float(v[3]))


def floor_bbox(fl):
    xs, ys = [], []
    for r in fl["rooms"]:
        xs += [r["x"], r["x"] + r["w"]]
        ys += [r["y"], r["y"] + r["h"]]
    for w in fl.get("solid_walls", []):
        xs += [w[0], w[0] + w[2]]
        ys += [w[1], w[1] + w[3]]
    for p in fl["partitions"]:
        xs += [p["wall"][0], p["wall"][0] + p["wall"][2]]
        ys += [p["wall"][1], p["wall"][1] + p["wall"][3]]
    if not xs:
        return None
    return min(xs), min(ys), max(xs), max(ys)


def render_floor(plan, fl, path, title_extra=""):
    bb = floor_bbox(fl)
    if bb is None:
        return None
    ox, oy = bb[0], bb[1]
    w_m, h_m = bb[2] - bb[0], bb[3] - bb[1]
    W = int(w_m * SCALE) + 2 * PAD
    H = int(h_m * SCALE) + 2 * PAD + 58
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    f_lab, f_t, f_s = font(13), font(15), font(11)

    def P(x, y):
        return (PAD + (x - ox) * SCALE, PAD + 34 + (y - oy) * SCALE)

    rooms = sorted(fl["rooms"], key=lambda r: -float(r["w"]) * float(r["h"]))
    # facade edges: a room edge that lies on the footprint outline is a wall the
    # street or the courtyard can put a window in.
    for r in fl["rooms"]:
        x0, y0, x1, y1 = rect_of(r)
        fill = (KIND_FILL.get(r["kind"], DEFAULT_FILL) if not r.get("circ") else
                KIND_FILL.get(r["kind"], DEFAULT_FILL))
        d.rectangle([P(x0, y0), P(x1, y1)], fill=fill, outline=PART, width=1)
        for (ax, ay, bx, by) in ((x0, y0, x1, y0), (x0, y1, x1, y1), (x0, y0, x0, y1), (x1, y0, x1, y1)):
            on_edge = (abs(ay - oy) < 0.02 and abs(by - oy) < 0.02) or \
                      (abs(ay - bb[3]) < 0.02 and abs(by - bb[3]) < 0.02) or \
                      (abs(ax - ox) < 0.02 and abs(bx - ox) < 0.02) or \
                      (abs(ax - bb[2]) < 0.02 and abs(bx - bb[2]) < 0.02)
            if on_edge:
                d.line([P(ax, ay), P(bx, by)], fill=FACADE, width=4)

    for p in fl["partitions"]:
        wx0, wy0, wx1, wy1 = rect4(p["wall"])
        d.rectangle([P(wx0, wy0), P(wx1, wy1)], fill=WALL)
        ox0, oy0, ox1, oy1 = rect4(p["opening"])
        d.rectangle([P(ox0, oy0), P(ox1, oy1)], fill=OPEN, outline=(255, 150, 0), width=2)

    for w in fl.get("solid_walls", []):
        x0, y0, x1, y1 = rect4(w)
        d.rectangle([P(x0, y0), P(x1, y1)], fill=(90, 90, 90))

    if fl.get("core_rect"):
        x0, y0, x1, y1 = rect4(fl["core_rect"])
        d.rectangle([P(x0, y0), P(x1, y1)], outline=CORE, width=3)
        d.line([P(x0, y0), P(x1, y1)], fill=CORE, width=1)
        d.line([P(x0, y1), P(x1, y0)], fill=CORE, width=1)
        d.text((P(x0, y0)[0] + 3, P(x0, y0)[1] + 3), "STAIR", font=f_s, fill=CORE)

    for i, r in enumerate(rooms):
        x0, y0, x1, y1 = rect_of(r)
        cx, cy = (x0 + x1) / 2.0, (y0 + y1) / 2.0
        label = "%d %s" % (i, r["kind"])
        if float(r["w"]) < 2.0 or float(r["h"]) < 1.6:
            continue
        d.text((P(cx, cy)[0] - len(label) * 3.1, P(cx, cy)[1] - 7), label, font=f_lab,
               fill=(60, 20, 20) if r.get("entry") else (20, 20, 20))
        if r.get("entry"):
            ex = P(cx, y0)
            d.polygon([(ex[0], ex[1] - 16), (ex[0] - 9, ex[1] - 32), (ex[0] + 9, ex[1] - 32)], fill=ENTRY)
            d.text((ex[0] - 22, ex[1] - 46), "ENTRY", font=f_s, fill=ENTRY)

    d.rectangle([P(ox, oy), P(bb[2], bb[3])], outline=(0, 0, 0), width=2)
    title = "%s  seed %s  floor %d  %s%s" % (plan["footprint"], plan["seed"], fl["floor_i"],
                                             fl["archetype"], " (mirrored)" if fl.get("mirrored") else "")
    d.text((PAD, 8), title + title_extra, font=f_t, fill=(0, 0, 0))
    d.text((PAD, 26), "%.1f x %.1f m   rooms=%d  doors=%d   green = facade edge, magenta = stair shaft, orange = door opening"
           % (w_m, h_m, len(fl["rooms"]), len(fl["partitions"])), font=f_s, fill=(90, 90, 90))
    d.line([(PAD, H - 24), (PAD + SCALE * 5, H - 24)], fill=(0, 0, 0), width=3)
    d.text((PAD + SCALE * 5 + 6, H - 32), "5 m", font=f_s, fill=(0, 0, 0))
    img.save(path)
    return path


def contact_sheet(paths, out_path, cols=3):
    if not paths:
        return None
    imgs = [Image.open(p) for p in paths]
    cw = max(i.width for i in imgs) + 16
    ch = max(i.height for i in imgs) + 16
    rows = int(math.ceil(len(imgs) / float(cols)))
    sheet = Image.new("RGB", (cw * min(cols, len(imgs)), ch * rows), (255, 255, 255))
    for i, im in enumerate(imgs):
        sheet.paste(im, ((i % cols) * cw + 8, (i // cols) * ch + 8))
    sheet.save(out_path)
    return out_path


def main():
    args = sys.argv[1:]
    only = None
    if "--only" in args:
        only = args[args.index("--only") + 1]
    data = json.load(open(SRC, encoding="utf-8"))
    plans = [p for p in data["plans"] if not only or only in p["footprint"]]
    os.makedirs(OUT, exist_ok=True)
    made = []
    per_footprint = {}
    for plan in plans:
        for fl in plan["floors"]:
            name = "%s_s%s_f%d.png" % (plan["footprint"].replace(" ", "_"), plan["seed"], fl["floor_i"])
            p = os.path.join(OUT, name)
            if render_floor(plan, fl, p):
                made.append(p)
                per_footprint.setdefault(plan["footprint"], []).append(p)
    print("rendered %d floor images into %s" % (len(made), OUT))
    for k in sorted(per_footprint):
        print("  %-26s %d" % (k, len(per_footprint[k])))
    if "--sheet" in args:
        pics = []
        for k in sorted(per_footprint):
            pics.append(per_footprint[k][0])
            if len(per_footprint[k]) > 1:
                pics.append(per_footprint[k][1])
        sheet = contact_sheet(pics[:12], os.path.join(OUT, "sheet_ground_floors.png"), cols=3)
        print("sheet:", sheet)
    if made:
        print("sample:", made[0])


if __name__ == "__main__":
    main()
