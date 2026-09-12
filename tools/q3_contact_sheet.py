#!/usr/bin/env python3
"""Contact sheets for the room-perception captures.

Tiles the PNGs of a capture directory into sheets of 6 (2 cols x 3 rows) with
the capture name burned into each tile, so an inspector (human or vision model)
can read many rooms per image instead of one.

Usage: python tools/q3_contact_sheet.py <capture_dir> [--cols 2] [--pattern glob]
"""
from __future__ import annotations

import argparse
import glob
import os
import sys

from PIL import Image, ImageDraw

CAP_H = 28


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("capture_dir")
    ap.add_argument("--cols", type=int, default=2)
    ap.add_argument("--rows", type=int, default=3)
    ap.add_argument("--pattern", default="*.png")
    ap.add_argument("--out", default=None)
    ap.add_argument("--max-sheets", type=int, default=0, help="0 = all")
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(args.capture_dir, args.pattern)))
    files = [f for f in files if not os.path.basename(f).startswith("sheet_")]
    if not files:
        print(f"no files matched {args.pattern} in {args.capture_dir}", file=sys.stderr)
        return 2

    per = args.cols * args.rows
    made = []
    for i in range(0, len(files), per):
        chunk = files[i:i + per]
        tiles = []
        for path in chunk:
            im = Image.open(path).convert("RGB")
            draw = ImageDraw.Draw(im)
            draw.rectangle([0, 0, im.width, CAP_H], fill=(0, 0, 0))
            draw.text((6, 8), os.path.basename(path)[:-4], fill=(255, 255, 255))
            tiles.append(im)
        tw = max(t.width for t in tiles)
        th = max(t.height for t in tiles)
        sheet = Image.new("RGB", (tw * args.cols, th * args.rows), (16, 16, 16))
        for idx, tile in enumerate(tiles):
            cx = (idx % args.cols) * tw
            cy = (idx // args.cols) * th
            sheet.paste(tile, (cx, cy))
        name = args.out or os.path.join(args.capture_dir, f"sheet_{i // per + 1:02d}.png")
        if i // per > 0 and args.out:
            root, ext = os.path.splitext(args.out)
            name = f"{root}_{i // per + 1:02d}{ext}"
        sheet.save(name)
        made.append((name, len(chunk)))
        if args.max_sheets and len(made) >= args.max_sheets:
            break

    for name, count in made:
        print(f"{name} ({count} tiles)")
    print(f"total source images: {len(files)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
