#!/usr/bin/env python3
import argparse, json, re, shutil, sys
from pathlib import Path

try:
    import numpy as np
    from PIL import Image
except ImportError:
    print("ERROR: needs Pillow and numpy", file=sys.stderr, flush=True)
    sys.exit(1)

SINGLE_DIFF_MULTIPLIER   = 1.0
CUMULATIVE_MULTIPLIER    = 2.0
ACTIVITY_FRACTION        = 0.02


def parse_ts(name):
    m = re.search(r'(\d{8})_(\d{6})', name)
    return f"{m.group(1)}_{m.group(2)}" if m else None


def load_image(path):
    """Loads image, returns RGB array and a boolean indicating if it has transparency."""
    with Image.open(path) as im:
        arr_rgba = np.array(im.convert('RGBA'))
        has_transparency = np.any(arr_rgba[:, :, 3] == 0)
        arr_rgb = arr_rgba[:, :, :3].copy()
    return arr_rgb, has_transparency


def ensure_palette(sample_png, palette_path):
    if palette_path.exists():
        return json.load(open(palette_path))
    arr, _ = load_image(sample_png)
    unique = np.unique(arr.reshape(-1, 3), axis=0)
    palette = ['#%02x%02x%02x' % tuple(int(v) for v in c) for c in unique]
    with open(palette_path, 'w') as f:
        json.dump(palette, f)
    return palette


def compute_changes_np(base_arr, new_arr, palette):
    mask = np.any(base_arr != new_arr, axis=2)
    ys, xs = np.where(mask)
    colors = new_arr[ys, xs] 
    
    packed = (colors[:, 0].astype(np.uint32) << 16) | (colors[:, 1].astype(np.uint32) << 8) | colors[:, 2].astype(np.uint32)
    
    lookup = np.zeros(1 << 24, dtype=np.uint8)
    for i, hex_c in enumerate(palette):
        r = int(hex_c[1:3], 16)
        g = int(hex_c[3:5], 16)
        b = int(hex_c[5:7], 16)
        lookup[(r << 16) | (g << 8) | b] = i
        
    idxs = lookup[packed]
    return xs, ys, idxs


def encode_rle_rows_np(xs, ys, idxs):
    if len(xs) == 0:
        return []
        
    order = np.lexsort((xs, ys))
    xs = xs[order]
    ys = ys[order]
    idxs = idxs[order]
    
    new_segment = np.ones(len(xs), dtype=bool)
    new_segment[1:] = (ys[1:] != ys[:-1]) | (xs[1:] != xs[:-1] + 1)
    segment_starts = np.where(new_segment)[0]
    
    rows = []
    for i, start_idx in enumerate(segment_starts):
        y = int(ys[start_idx])
        x_start = int(xs[start_idx])
        
        end_idx = segment_starts[i+1] if i+1 < len(segment_starts) else len(xs)
        seg_idxs = idxs[start_idx:end_idx]
        
        idx_changes = np.ones(len(seg_idxs), dtype=bool)
        idx_changes[1:] = (seg_idxs[1:] != seg_idxs[:-1])
        run_starts = np.where(idx_changes)[0]
        run_lengths = np.diff(np.append(run_starts, len(seg_idxs)))
        
        runs = []
        for j, r_start in enumerate(run_starts):
            idx_val = int(seg_idxs[r_start])
            run_len = int(run_lengths[j])
            runs.append([idx_val, run_len])
            
        rows.append([y, x_start, runs])
        
    return rows


def build_diff_payload(base_time, timestamp, xs, ys, idxs):
    if len(xs) == 0:
        payload = {'base': base_time, 'timestamp': timestamp,
                   'format': 'v2-flat', 'changes': []}
        return payload, json.dumps(payload, separators=(',', ':')).encode(), 'v2-flat'
    
    flat = np.column_stack((xs, ys, idxs)).tolist()
    fp = {'base': base_time, 'timestamp': timestamp, 'format': 'v2-flat', 'changes': flat}
    fb = json.dumps(fp, separators=(',', ':')).encode()
    
    rows = encode_rle_rows_np(xs, ys, idxs)
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
                    s.add((y << 32) | ((x + i) << 16) | idx)
                x += length
        return s
    if 'changes' in diff:
        return set((y << 32) | (x << 16) | idx for x, y, idx in diff['changes'])
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
              f"({prior['cumulative_bytes']} bytes already accumulated)", flush=True)

    pngs = sorted(in_dir.glob('wdpsnapshot_*.png'))
    if not pngs:
        print(f"No wdpsnapshot_*.png in {in_dir}", file=sys.stderr, flush=True)
        sys.exit(1)
    print(f"Found {len(pngs)} snapshots", flush=True)

    palette = ensure_palette(pngs[0], out_dir / 'palette.json')
    print(f"Palette: {len(palette)} colors", flush=True)

    timeline = []
    base_time = None
    base_arr = None
    prev_changes_set = None

    if prior:
        base_time = prior['base_time']
        base_png_path = Path(prior['base_png_local'])
        if not base_png_path.exists():
            print(f"ERROR: prior base PNG not found at {base_png_path}", file=sys.stderr, flush=True)
            sys.exit(1)
        base_arr, _ = load_image(base_png_path)
        print(f"Loaded prior base: {base_png_path.name} ({base_arr.shape[1]}x{base_arr.shape[0]})", flush=True)
        if prior.get('last_diff_local') and Path(prior['last_diff_local']).exists():
            prev_diff = json.load(open(prior['last_diff_local']))
            prev_changes_set = diff_content_set(prev_diff)
            print(f"Loaded prior last diff for activity comparison", flush=True)

    initial_base_arr = base_arr
    cumulative_prior = prior['cumulative_bytes'] if prior else 0
    bytes_since_base = cumulative_prior  # <--- FIX: Track bytes since last base

    total_original = 0
    total_new = 0
    reused_count = 0
    promoted_count = 0
    flat_wins = 0
    rle_wins = 0
    culled_count = 0

    for idx, png_path in enumerate(pngs):
        t = parse_ts(png_path.name)
        if not t:
            continue
        
        print(f"Processing {png_path.name} ({idx+1}/{len(pngs)})...", flush=True)
        
        orig_size = png_path.stat().st_size
        total_original += orig_size
        png_size = orig_size

        new_arr, has_trans = load_image(png_path)
        
        if not has_trans:
            print(f"{t}: WARNING: Image has zero transparency (flattened). Culling from archive.", flush=True)
            culled_count += 1
            continue

        if initial_base_arr is None and base_arr is None:
            shutil.copy2(png_path, out_dir / png_path.name)
            base_arr = new_arr
            base_time = t
            timeline.append({"time": t, "kind": "png", "src": png_path.name,
                             "name": t, "bytes": png_size})
            prev_changes_set = set()
            total_new += orig_size
            bytes_since_base = 0
            print(f"{t}: base png ({orig_size/1024/1024:.2f} MB)", flush=True)
            continue

        if new_arr.shape != base_arr.shape:
            shutil.copy2(png_path, out_dir / png_path.name)
            base_arr = new_arr
            base_time = t
            bytes_since_base = 0
            prev_changes_set = set()
            timeline.append({"time": t, "kind": "png", "src": png_path.name,
                             "name": t, "bytes": png_size})
            total_new += orig_size
            promoted_count += 1
            print(f"{t}: size change -> base png", flush=True)
            continue

        xs, ys, idxs = compute_changes_np(base_arr, new_arr, palette)
        
        if len(xs) > 0:
            flat_changes = np.column_stack((xs, ys, idxs)).tolist()
            curr_set = set(map(tuple, flat_changes))
        else:
            curr_set = set()
            
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
                print(f"{t}: unchanged -> reuse {prev_entry['src']}", flush=True)
                continue

        payload, encoded, fmt = build_diff_payload(base_time, t, xs, ys, idxs)
        if fmt == 'v3-rle': rle_wins += 1
        else:               flat_wins += 1

        cumulative = bytes_since_base + len(encoded)

        single_exceeded     = len(encoded) > SINGLE_DIFF_MULTIPLIER * png_size
        cumulative_exceeded = cumulative    > CUMULATIVE_MULTIPLIER * png_size
        churning = (activity is None) or (activity > len(curr_set) * ACTIVITY_FRACTION)

        promote_reason = None
        if single_exceeded:
            promote_reason = 'single-diff'
        elif cumulative_exceeded and churning:
            promote_reason = 'cumulative'
        elif cumulative_exceeded and not churning:
            print(f"{t}: {fmt} {len(curr_set):,} changes -> {len(encoded)/1024:.1f} KB "
                  f"(deferred promote; activity={activity})", flush=True)

        if promote_reason:
            shutil.copy2(png_path, out_dir / png_path.name)
            base_arr = new_arr
            base_time = t
            bytes_since_base = 0
            prev_changes_set = curr_set
            timeline.append({"time": t, "kind": "png", "src": png_path.name,
                             "name": t, "bytes": png_size})
            total_new += orig_size
            promoted_count += 1
            print(f"{t}: promote ({promote_reason}, {len(curr_set):,} changes)", flush=True)
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
            bytes_since_base += len(encoded)
            print(f"{t}: {fmt} {len(curr_set):,} changes -> {len(encoded)/1024:.1f} KB", flush=True)

    (out_dir / 'timeline.json').write_text(json.dumps(timeline, indent=2))

    print("\nReport:", flush=True)
    print(f"  Original: {total_original/1024/1024:.2f} MB ({len(pngs)} PNGs)", flush=True)
    npng = sum(1 for e in timeline if e['kind'] == 'png')
    ndiff = sum(1 for e in timeline if e['kind'] == 'diff')
    print(f"  New:      {total_new/1024/1024:.2f} MB "
          f"({npng} PNGs + {ndiff} diffs, {reused_count} reused, {promoted_count} promoted, {culled_count} culled)", flush=True)
    print(f"  Format:   {flat_wins} v2-flat, {rle_wins} v3-rle", flush=True)
    if total_original:
        print(f"  Savings:  {(1 - total_new/total_original)*100:.1f}%", flush=True)


if __name__ == '__main__':
    main()
