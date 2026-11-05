#!/usr/bin/env python3
import argparse, json, re, shutil, sys
from pathlib import Path

try:
    import numpy as np
    from PIL import Image
except ImportError:
    print("ERROR: needs Pillow and numpy", file=sys.stderr)
    sys.exit(1)

SINGLE_DIFF_MULTIPLIER   = 1.0
CUMULATIVE_MULTIPLIER    = 2.0
ACTIVITY_FRACTION        = 0.02


def parse_ts(name):
    m = re.search(r'(\d{8})_(\d{6})', name)
    return f"{m.group(1)}_{m.group(2)}" if m else None


def load_rgb(path):
    with Image.open(path) as im:
        return np.array(im.convert('RGB'))


def ensure_palette(sample_png, palette_path):
    if palette_path.exists():
        return json.load(open(palette_path))
    arr = load_rgb(sample_png)
    unique = np.unique(arr.reshape(-1, 3), axis=0)
    palette = ['#%02x%02x%02x' % tuple(int(v) for v in c) for c in unique]
    with open(palette_path, 'w') as f:
        json.dump(palette, f)
    return palette


def compute_changes(base_arr, new_arr):
    mask = np.any(base_arr != new_arr, axis=2)
    ys, xs = np.where(mask)
    colors = new_arr[ys, xs]
    return [
        (int(x), int(y), '#%02x%02x%02x' % (int(c[0]), int(c[1]), int(c[2])))
        for x, y, c in zip(xs.tolist(), ys.tolist(), colors.tolist())
    ]


def encode_rle_rows(changes, color_to_idx):
    by_row = {}
    for x, y, c in changes:
        by_row.setdefault(y, []).append((x, color_to_idx[c]))
    rows = []
    for y in sorted(by_row):
        pixels = sorted(by_row[y])
        segments, current = [], []
        for x, idx in pixels:
            if current and x != current[-1][0] + 1:
                segments.append(current); current = []
            current.append((x, idx))
        if current: segments.append(current)
        for seg in segments:
            x_start = seg[0][0]
            runs, i = [], 0
            while i < len(seg):
                idx = seg[i][1]
                j = i + 1
                while j < len(seg) and seg[j][1] == idx:
                    j += 1
                runs.append([idx, j - i])
                i = j
            rows.append([y, x_start, runs])
    return rows


def build_diff_payload(base_time, timestamp, changes, color_to_idx):
    if not changes:
        payload = {'base': base_time, 'timestamp': timestamp,
                   'format': 'v2-flat', 'changes': []}
        return payload, json.dumps(payload, separators=(',', ':')).encode(), 'v2-flat'
    flat = [[x, y, color_to_idx[c]] for x, y, c in changes]
    fp = {'base': base_time, 'timestamp': timestamp, 'format': 'v2-flat', 'changes': flat}
    fb = json.dumps(fp, separators=(',', ':')).encode()
    rows = encode_rle_rows(changes, color_to_idx)
    rp = {'base': base_time, 'timestamp': timestamp, 'format': 'v3-rle', 'rows': rows}
    rb = json.dumps(rp, separators=(',', ':')).encode()
    if len(rb) < len(fb):
        return rp, rb, 'v3-rle'
    return fp, fb, 'v2-flat'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--input', required=True)
    ap.add_argument('--output', required=True)
    args = ap.parse_args()

    in_dir = Path(args.input)
    out_dir = Path(args.output)
    out_dir.mkdir(parents=True, exist_ok=True)

    pngs = sorted(in_dir.glob('wdpsnapshot_*.png'))
    if not pngs:
        print(f"No wdpsnapshot_*.png in {in_dir}", file=sys.stderr)
        sys.exit(1)
    print(f"Found {len(pngs)} snapshots")

    # NOTE: mixed sizes are allowed — the loop below promotes to a new base
    # PNG whenever the size changes, which splits the chain cleanly.

    palette = ensure_palette(pngs[0], out_dir / 'palette.json')
    color_to_idx = {c: i for i, c in enumerate(palette)}
    print(f"Palette: {len(palette)} colors")

    timeline = []
    base_time = None
    base_arr = None
    prev_arr = None
    prev_changes_set = None
    prev_entry = None
    total_original = 0
    total_new = 0
    reused_count = 0
    promoted_count = 0
    flat_wins = 0
    rle_wins = 0

    for idx, png_path in enumerate(pngs):
        t = parse_ts(png_path.name)
        if not t:
            continue
        orig_size = png_path.stat().st_size
        total_original += orig_size
        png_size = orig_size

        if idx == 0:
            shutil.copy2(png_path, out_dir / png_path.name)
            base_arr = load_rgb(png_path)
            base_time = t
            timeline.append({"time": t, "kind": "png", "src": png_path.name,
                             "name": t, "bytes": png_size})
            prev_arr = base_arr
            prev_changes_set = set()
            prev_entry = timeline[-1]
            total_new += orig_size
            print(f"{t}: base png ({orig_size/1024/1024:.2f} MB)")
            continue

        new_arr = load_rgb(png_path)

        if new_arr.shape != base_arr.shape:
            shutil.copy2(png_path, out_dir / png_path.name)
            base_arr = new_arr
            base_time = t
            timeline.append({"time": t, "kind": "png", "src": png_path.name,
                             "name": t, "bytes": png_size})
            prev_arr = new_arr
            prev_changes_set = set()
            prev_entry = timeline[-1]
            total_new += orig_size
            promoted_count += 1
            print(f"{t}: size change -> base png")
            continue

        changes = compute_changes(base_arr, new_arr)

        curr_set = set((x, y, color_to_idx[c]) for x, y, c in changes)
        if prev_changes_set is not None:
            activity = len(curr_set ^ prev_changes_set)
        else:
            activity = None

        if prev_entry and prev_entry['kind'] == 'diff' and activity == 0:
            timeline.append({
                "time": t, "kind": "diff", "format": prev_entry["format"],
                "base": base_time, "src": prev_entry["src"],
                "name": t, "bytes": 0,
            })
            prev_arr = new_arr
            prev_changes_set = curr_set
            prev_entry = timeline[-1]
            reused_count += 1
            print(f"{t}: unchanged -> reuse {prev_entry['src']}")
            continue

        payload, encoded, fmt = build_diff_payload(base_time, t, changes, color_to_idx)
        if fmt == 'v3-rle': rle_wins += 1
        else:               flat_wins += 1

        cumulative = sum(e.get('bytes', 0) for e in timeline
                         if e['kind'] == 'diff' and e.get('base') == base_time)
        cumulative += len(encoded)

        single_exceeded     = len(encoded) > SINGLE_DIFF_MULTIPLIER * png_size
        cumulative_exceeded = cumulative    > CUMULATIVE_MULTIPLIER * png_size
        churning = (activity is None) or (activity > len(changes) * ACTIVITY_FRACTION)

        promote_reason = None
        if single_exceeded:
            promote_reason = 'single-diff'
        elif cumulative_exceeded and churning:
            promote_reason = 'cumulative'
        elif cumulative_exceeded and not churning:
            print(f"{t}: {fmt} {len(changes):,} changes -> {len(encoded)/1024:.1f} KB "
                  f"(deferred promote; activity={activity})")

        if promote_reason:
            shutil.copy2(png_path, out_dir / png_path.name)
            base_arr = new_arr
            base_time = t
            timeline.append({"time": t, "kind": "png", "src": png_path.name,
                             "name": t, "bytes": png_size})
            prev_arr = new_arr
            prev_changes_set = curr_set
            prev_entry = timeline[-1]
            total_new += orig_size
            promoted_count += 1
            print(f"{t}: promote ({promote_reason}, {len(changes):,} changes)")
        else:
            diff_name = f"wdpdiff_{t}.json"
            (out_dir / diff_name).write_bytes(encoded)
            timeline.append({
                "time": t, "kind": "diff", "format": fmt,
                "base": base_time, "src": diff_name,
                "name": t, "bytes": len(encoded),
            })
            prev_arr = new_arr
            prev_changes_set = curr_set
            prev_entry = timeline[-1]
            total_new += len(encoded)
            print(f"{t}: {fmt} {len(changes):,} changes -> {len(encoded)/1024:.1f} KB")

    (out_dir / 'timeline.json').write_text(json.dumps(timeline, indent=2))

    print()
    print("Report:")
    print(f"  Original: {total_original/1024/1024:.2f} MB ({len(pngs)} PNGs)")
    npng = sum(1 for e in timeline if e['kind'] == 'png')
    ndiff = sum(1 for e in timeline if e['kind'] == 'diff')
    print(f"  New:      {total_new/1024/1024:.2f} MB "
          f"({npng} PNGs + {ndiff} diffs, {reused_count} reused, {promoted_count} promoted)")
    print(f"  Format:   {flat_wins} v2-flat, {rle_wins} v3-rle")
    if total_original:
        print(f"  Savings:  {(1 - total_new/total_original)*100:.1f}%")


if __name__ == '__main__':
    main()
