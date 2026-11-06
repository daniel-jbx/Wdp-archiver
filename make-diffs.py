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


def compute_changes(base_arr, new_arr, color_to_idx):
    mask = np.any(base_arr != new_arr, axis=2)
    ys, xs = np.where(mask)
    colors = new_arr[ys, xs]
    
    # Convert to indices immediately to save memory
    hex_colors = ['#%02x%02x%02x' % (int(c[0]), int(c[1]), int(c[2])) for c in colors.tolist()]
    
    # Return list of (x, y, idx) directly
    return [
        (int(x), int(y), color_to_idx[c])
        for x, y, c in zip(xs.tolist(), ys.tolist(), hex_colors)
    ]


def encode_rle_rows(changes):
    by_row = {}
    for x, y, idx in changes:
        by_row.setdefault(y, []).append((x, idx))
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


def build_diff_payload(base_time, timestamp, changes):
    if not changes:
        payload = {'base': base_time, 'timestamp': timestamp,
                   'format': 'v2-flat', 'changes': []}
        return payload, json.dumps(payload, separators=(',', ':')).encode(), 'v2-flat'
    
    flat = [[x, y, idx] for x, y, idx in changes]
    fp = {'base': base_time, 'timestamp': timestamp, 'format': 'v2-flat', 'changes': flat}
    fb = json.dumps(fp, separators=(',', ':')).encode()
    
    rows = encode_rle_rows(changes)
    rp = {'base': base_time, 'timestamp': timestamp, 'format': 'v3-rle', 'rows': rows}
    rb = json.dumps(rp, separators=(',', ':')).encode()
    
    if len(rb) < len(fb):
        return rp, rb, 'v3-rle'
    return fp, fb, 'v2-flat'


def diff_content_set(diff):
    if 'rows' in diff:
        s = set()
        for y, x0, runs in diff['rows']:
            x = x0
            for idx, length in runs:
                for i in range(length):
                    s.add((x + i, y, idx))
                x += length
        return s
    if 'changes' in diff:
        return set(tuple(c) for c in diff['changes'])
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--input', required=True)
    ap.add_argument('--output', required=True)
    ap.add_argument('--chain-state', default=None,
                    help='JSON file with prior chain state (base PNG, cumulative bytes, last diff)')
    args = ap.parse_args()

    in_dir = Path(args.input)
    out_dir = Path(args.output)
    out_dir.mkdir(parents=True, exist_ok=True)

    prior = None
    if args.chain_state:
        prior = json.load(open(args.chain_state))
        print(f"Continuing chain from base {prior['base_time']} "
              f"({prior['cumulative_bytes']} bytes already accumulated)")

    pngs = sorted(in_dir.glob('wdpsnapshot_*.png'))
    if not pngs:
        print(f"No wdpsnapshot_*.png in {in_dir}", file=sys.stderr)
        sys.exit(1)
    print(f"Found {len(pngs)} snapshots")

    palette = ensure_palette(pngs[0], out_dir / 'palette.json')
    color_to_idx = {c: i for i, c in enumerate(palette)}
    print(f"Palette: {len(palette)} colors")

    timeline = []
    base_time = None
    base_arr = None
    prev_changes_set = None

    if prior:
        base_time = prior['base_time']
        base_png_path = Path(prior['base_png_local'])
        if not base_png_path.exists():
            print(f"ERROR: prior base PNG not found at {base_png_path}", file=sys.stderr)
            sys.exit(1)
        base_arr = load_rgb(base_png_path)
        print(f"Loaded prior base: {base_png_path.name} ({base_arr.shape[1]}x{base_arr.shape[0]})")
        if prior.get('last_diff_local') and Path(prior['last_diff_local']).exists():
            prev_diff = json.load(open(prior['last_diff_local']))
            prev_changes_set = diff_content_set(prev_diff)
            print(f"Loaded prior last diff for activity comparison")

    initial_base_arr = base_arr
    cumulative_prior = prior['cumulative_bytes'] if prior else 0

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
        
        # Added flush=True so you can see progress in GitHub Actions logs
        print(f"Processing {png_path.name} ({idx+1}/{len(pngs)})...", flush=True)
        
        orig_size = png_path.stat().st_size
        total_original += orig_size
        png_size = orig_size

        if idx == 0 and initial_base_arr is None:
            shutil.copy2(png_path, out_dir / png_path.name)
            base_arr = load_rgb(png_path)
            base_time = t
            timeline.append({"time": t, "kind": "png", "src": png_path.name,
                             "name": t, "bytes": png_size})
            prev_changes_set = set()
            total_new += orig_size
            print(f"{t}: base png ({orig_size/1024/1024:.2f} MB)")
            continue

        new_arr = load_rgb(png_path)

        if new_arr.shape != base_arr.shape:
            shutil.copy2(png_path, out_dir / png_path.name)
            base_arr = new_arr
            base_time = t
            cumulative_prior = 0
            prev_changes_set = set()
            timeline.append({"time": t, "kind": "png", "src": png_path.name,
                             "name": t, "bytes": png_size})
            total_new += orig_size
            promoted_count += 1
            print(f"{t}: size change -> base png")
            continue

        changes = compute_changes(base_arr, new_arr, color_to_idx)
        curr_set = set(changes)
        activity = len(curr_set ^ prev_changes_set) if prev_changes_set is not None else None

        if prev_changes_set is not None and activity == 0 and timeline:
            prev_entry = timeline[-1]
            if prev_entry['kind'] == 'diff':
                timeline.append({
                    "time": t, "kind": "diff", "format": prev_entry["format"],
                    "base": base_time, "src": prev_entry["src"],
                    "name": t, "bytes": 0,
                })
                prev_changes_set = curr_set
                reused_count += 1
                print(f"{t}: unchanged -> reuse {prev_entry['src']}")
                continue

        payload, encoded, fmt = build_diff_payload(base_time, t, changes)
        if fmt == 'v3-rle': rle_wins += 1
        else:               flat_wins += 1

        cumulative_this_run = sum(e.get('bytes', 0) for e in timeline if e['kind'] == 'diff')
        cumulative = cumulative_prior + cumulative_this_run + len(encoded)

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
            cumulative_prior = 0
            prev_changes_set = curr_set
            timeline.append({"time": t, "kind": "png", "src": png_path.name,
                             "name": t, "bytes": png_size})
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
            prev_changes_set = curr_set
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
