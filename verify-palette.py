#!/usr/bin/env python3
"""Compare the unique color sets of two PNG snapshots.

If the palettes are byte-identical, palette-index compression (Tier 1) is safe.
If not, we'd need to force a fixed palette via pngquant --map before compressing.
"""
import hashlib
import sys
from pathlib import Path

import numpy as np
from PIL import Image


def unique_colors(path):
    img = Image.open(path).convert('RGB')
    arr = np.array(img)
    pixels = arr.reshape(-1, 3)
    unique = np.unique(pixels, axis=0)          # sorted lexicographically
    h = hashlib.md5(unique.tobytes()).hexdigest()
    return img.size, unique, h


def main():
    if len(sys.argv) < 3:
        print("Usage: verify-palette.py <png1> <png2>", file=sys.stderr)
        sys.exit(1)

    results = []
    for path in sys.argv[1:]:
        if not Path(path).exists():
            print(f"ERROR: {path} not found", file=sys.stderr)
            sys.exit(1)
        size, unique, h = unique_colors(path)
        results.append((path, unique, h))
        print(f"{path}")
        print(f"  dimensions:     {size[0]} x {size[1]} = {size[0]*size[1]:,} pixels")
        print(f"  unique colors:  {len(unique)}")
        print(f"  md5 of colors:  {h}")
        print(f"  first 5:        {[tuple(int(v) for v in c) for c in unique[:5]]}")
        print()

    _, u1, h1 = results[0]
    _, u2, h2 = results[1]

    print("=== Comparison ===")
    if h1 == h2:
        print(f"MATCH: both files share the identical {len(u1)}-color palette.")
        print("  → Palette-index compression is safe.")
        return

    set1 = set(map(tuple, u1))
    set2 = set(map(tuple, u2))
    only1 = set1 - set2
    only2 = set2 - set1
    print("DIFFER: palettes are NOT byte-identical.")
    print(f"  file 1 colors: {len(set1)}")
    print(f"  file 2 colors: {len(set2)}")
    print(f"  colors only in file 1: {len(only1)}")
    print(f"  colors only in file 2: {len(only2)}")
    if only1:
        print(f"  sample only-in-1: {list(only1)[:5]}")
    if only2:
        print(f"  sample only-in-2: {list(only2)[:5]}")

    if len(u1) <= 64 and len(u2) <= 64:
        print()
        print("NOTE: both ≤64 colors, so quantization is happening somewhere upstream.")
        print("  Palette indices aren't portable across files without a forced palette.")


if __name__ == '__main__':
    main()
