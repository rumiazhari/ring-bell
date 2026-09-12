"""Compose before/after pairs of the same capture name.

Usage: python tools/q3_pair_sheet.py <pre_dir> <post_dir> <out.png> [name_filter]

Both directories hold PNGs captured from identical camera positions (the
harness is deterministic), so a pair shows exactly what the fix changed for the
player: row 1 = before, row 2 = after, with the capture name burned in.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def font(size: int):
    for name in ("segoeui.ttf", "arial.ttf", "DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


def main() -> int:
    pre_dir, post_dir, out_path = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    filt = sys.argv[4] if len(sys.argv) > 4 else ""
    names = sorted(p.name for p in post_dir.glob("*.png") if filt in p.name)
    pairs = [n for n in names if (pre_dir / n).exists()]
    if not pairs:
        print(f"no matching pairs ({len(names)} post images, filter={filt!r})")
        return 1
    label_h = 34
    tiles = []
    for name in pairs:
        a = Image.open(pre_dir / name).convert("RGB")
        b = Image.open(post_dir / name).convert("RGB")
        w = min(a.width, b.width)
        h = min(a.height, b.height)
        tiles.append((name, a.crop((0, 0, w, h)), b.crop((0, 0, w, h))))
    cols = min(2, len(tiles))
    rows = (len(tiles) + cols - 1) // cols
    tw, th = tiles[0][1].size
    sheet = Image.new("RGB", (cols * tw, rows * (th * 2 + label_h * 2)), (16, 16, 20))
    d = ImageDraw.Draw(sheet)
    f = font(22)
    for idx, (name, a, b) in enumerate(tiles):
        cx = (idx % cols) * tw
        cy = (idx // cols) * (th * 2 + label_h * 2)
        sheet.paste(a, (cx, cy + label_h))
        sheet.paste(b, (cx, cy + label_h * 2 + th))
        d.text((cx + 8, cy + 6), f"BEFORE  {name}", fill=(255, 140, 140), font=f)
        d.text((cx + 8, cy + label_h + th + 6), f"AFTER  {name}", fill=(140, 255, 160), font=f)
    sheet.save(out_path)
    print(f"wrote {out_path} ({len(tiles)} pairs, {sheet.width}x{sheet.height})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
