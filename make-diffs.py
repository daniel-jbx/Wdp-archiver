#!/usr/bin/env python3
import argparse, json, re, shutil, sys
from pathlib import Path

try:
    import numpy as np
    from PIL import Image
except ImportError:
    print("ERROR: needs Pillow and numpy", file=sys.stderr)
    sys.exit(1)


def parse_ts(name):
    m = re.search(r'(\d{8})_(\d{6})', name)
    return f"{m.group(1)}_{m.group(2)}" if m else None


def load_rgb(path):
    with Image.open(path) as im:
        return np.array(im.convert('RGB'))


def compute_changes(base_arr, new_arr):
    mask = np.any(base_arr != new_arr, axis=2)
    ys, xs = np.where(mask)
    colors = new_arr[ys, xs]
    return [
        [int(x), int(y), '#%02x%02x%02x' % (int(c[0]), int(c[1]), int(c[2]))]
        for x, y, c in zip(xs.tolist(), ys.tolist(), colors.tolist())
    ]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--input', required=True)
    ap.add_argument('--output', required=True)
    ap.add_argument('--promote-threshold-bytes', type=int, default=500_000)
    args = ap.parse_args()

    in_dir = Path(args.input)
    out_dir = Path(args.output)
    out_dir.mkdir(parents=True, exist_ok=True)

    pngs = sorted(in_dir.glob('wdpsnapshot_*.png'))
    if not pngs:
        print(f"No wdpsnapshot_*.png in {in_dir}", file=sys.stderr)
        sys.exit(1)
    print(f"Found {len(pngs)} snapshots")

    sizes = set()
    for p in pngs:
        with Image.open(p) as im:
            sizes.add(im.size)
    if len(sizes) > 1:
        print(f"ERROR: mixed sizes {sizes}", file=sys.stderr)
        sys.exit(1)

    timeline = []
    base_time = None
    base_arr = None
    prev_arr = None
    prev_entry = None
    total_original = 0
    total_new = 0
    reused_count = 0

    for idx, png_path in enumerate(pngs):
        t = parse_ts(png_path.name)
        if not t:
            continue
        orig_size = png_path.stat().st_size
        total_original += orig_size

        if idx == 0:
            shutil.copy2(png_path, out_dir / png_path.name)
            base_arr = load_rgb(png_path)
            base_time = t
            timeline.append({"time": t, "kind": "png", "src": png_path.name, "name": t})
            prev_arr = base_arr
            prev_entry = timeline[-1]
            total_new += orig_size
            print(f"{t}: base png ({orig_size/1024/1024:.2f} MB)")
            continue

        new_arr = load_rgb(png_path)

        if new_arr.shape != base_arr.shape:
            shutil.copy2(png_path, out_dir / png_path.name)
            base_arr = new_arr
            base_time = t
            timeline.append({"time": t, "kind": "png", "src": png_path.name, "name": t})
            prev_arr = new_arr
            prev_entry = timeline[-1]
            total_new += orig_size
            print(f"{t}: size change → base png")
            continue

        # Dedupe: if this snapshot is pixel-identical to the previous one and
        # the previous entry was a diff, reuse that diff file instead of
        # writing a byte-identical copy.
        if (prev_arr is not None
                and prev_entry is not None
                and prev_entry["kind"] == "diff"
                and np.array_equal(new_arr, prev_arr)):
            timeline.append({
                "time": t,
                "kind": "diff",
                "base": base_time,
                "src":  prev_entry["src"],
                "name": t,
            })
            prev_arr = new_arr
            prev_entry = timeline[-1]
            reused_count += 1
            print(f"{t}: unchanged → reuse {prev_entry['src']}")
            continue

        changes = compute_changes(base_arr, new_arr)
        payload = json.dumps(
            {"base": base_time, "timestamp": t, "changes": changes},
            separators=(',', ':')
        ).encode('utf-8')

        if len(payload) > args.promote_threshold_bytes:
            shutil.copy2(png_path, out_dir / png_path.name)
            base_arr = new_arr
            base_time = t
            timeline.append({"time": t, "kind": "png", "src": png_path.name, "name": t})
            prev_arr = new_arr
            prev_entry = timeline[-1]
            total_new += orig_size
            print(f"{t}: promote → png ({len(changes):,} changes)")
        else:
            diff_name = f"wdpdiff_{t}.json"
            (out_dir / diff_name).write_bytes(payload)
            timeline.append({"time": t, "kind": "diff", "base": base_time, "src": diff_name, "name": t})
            prev_arr = new_arr
            prev_entry = timeline[-1]
            total_new += len(payload)
            print(f"{t}: diff {len(changes):,} changes → {len(payload)/1024:.1f} KB")

    (out_dir / 'timeline.json').write_text(json.dumps(timeline, indent=2))

    print()
    print("Report:")
    print(f"  Original: {total_original/1024/1024:.2f} MB ({len(pngs)} PNGs)")
    npng = sum(1 for e in timeline if e['kind'] == 'png')
    ndiff = sum(1 for e in timeline if e['kind'] == 'diff')
    print(f"  New:      {total_new/1024/1024:.2f} MB ({npng} PNGs + {ndiff} diffs, {reused_count} reused)")
    if total_original:
        print(f"  Savings:  {(1 - total_new/total_original)*100:.1f}%")


if __name__ == '__main__':
    main()
