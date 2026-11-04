#!/usr/bin/env python3
import argparse, json, os, re, subprocess, sys, tempfile
from pathlib import Path

try:
    import numpy as np
    from PIL import Image
except ImportError:
    print("ERROR: needs Pillow and numpy", file=sys.stderr)
    sys.exit(1)

# Promote thresholds (all relative to the size of a freshly-compressed PNG)
SINGLE_DIFF_MULTIPLIER   = 1.0   # promote if any single diff exceeds P
CUMULATIVE_MULTIPLIER    = 2.0   # promote if chain since base exceeds 2*P
ACTIVITY_FRACTION        = 0.02  # promote only if activity > 2% of chain


def rclone(env, *args):
    return subprocess.run(
        ['rclone',
         '--s3-provider=Cloudflare',
         f'--s3-endpoint={env["R2_ENDPOINT"]}',
         f'--s3-access-key-id={env["R2_ACCESS_KEY_ID"]}',
         f'--s3-secret-access-key={env["R2_SECRET_ACCESS_KEY"]}',
         '--s3-no-check-bucket', *args],
        check=True,
    )


def download(env, remote, local):
    rclone(env, 'copyto', f':s3:{env["R2_BUCKET"]}/{remote}', local)


def upload(env, local, remote):
    rclone(env, 'copyto', local, f':s3:{env["R2_BUCKET"]}/{remote}')


def load_rgb(path):
    with Image.open(path) as im:
        return np.array(im.convert('RGB'))


def ensure_palette(env, sample_png, tmp):
    local = tmp / 'palette.json'
    try:
        download(env, 'palette.json', str(local))
    except subprocess.CalledProcessError:
        pass
    if local.exists():
        palette = json.load(open(local))
        print(f"Palette: loaded {len(palette)} colors from R2")
        return palette
    arr = load_rgb(sample_png)
    unique = np.unique(arr.reshape(-1, 3), axis=0)
    palette = ['#%02x%02x%02x' % tuple(int(v) for v in c) for c in unique]
    with open(local, 'w') as f:
        json.dump(palette, f)
    upload(env, str(local), 'palette.json')
    print(f"Palette: generated {len(palette)} colors and uploaded to R2")
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


def parse_ts(name):
    m = re.search(r'(\d{8})_(\d{6})', name)
    return f"{m.group(1)}_{m.group(2)}" if m else None


def save_timeline(env, tmp, timeline):
    p = tmp / 'timeline.json'
    with open(p, 'w') as f:
        json.dump(timeline, f, indent=2)
    upload(env, str(p), 'timeline.json')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--snapshot', required=True)
    args = ap.parse_args()

    env = {k: os.environ[k] for k in (
        'R2_ENDPOINT', 'R2_ACCESS_KEY_ID', 'R2_SECRET_ACCESS_KEY', 'R2_BUCKET')}

    snap_path = Path(args.snapshot)
    if not snap_path.exists():
        print(f"ERROR: snapshot not found: {snap_path}", file=sys.stderr)
        sys.exit(1)
    snap_name = snap_path.name
    new_time = parse_ts(snap_name)
    if not new_time:
        print(f"ERROR: cannot parse timestamp from {snap_name}", file=sys.stderr)
        sys.exit(1)
    png_size = snap_path.stat().st_size

    print(f"New snapshot: {snap_name} ({png_size/1024/1024:.2f} MB)")
    print(f"Timestamp:    {new_time}")

    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = Path(tmpdir)
        palette = ensure_palette(env, snap_path, tmp)
        color_to_idx = {c: i for i, c in enumerate(palette)}

        timeline_path = tmp / 'timeline.json'
        try:
            download(env, 'timeline.json', str(timeline_path))
        except subprocess.CalledProcessError:
            pass
        if not timeline_path.exists():
            print("No existing timeline.json; initializing with this snapshot as base.")
            upload(env, str(snap_path), snap_name)
            timeline = [{"time": new_time, "kind": "png", "src": snap_name,
                         "name": new_time, "bytes": png_size}]
            save_timeline(env, tmp, timeline)
            print("Done (first entry).")
            return
        timeline = json.load(open(timeline_path))
        print(f"Loaded timeline: {len(timeline)} entries")

        if not timeline:
            print("ERROR: timeline.json is empty", file=sys.stderr)
            sys.exit(1)

        last = timeline[-1]
        if last['time'] >= new_time:
            print(f"ERROR: {new_time} not newer than {last['time']}", file=sys.stderr)
            sys.exit(1)
        print(f"Previous tip: {last['time']} ({last['kind']})")

        base_entry = None
        for entry in reversed(timeline):
            if entry['kind'] == 'png':
                base_entry = entry
                break
        if not base_entry:
            print("ERROR: no PNG base in timeline", file=sys.stderr)
            sys.exit(1)

        base_path = tmp / base_entry['src']
        print(f"Downloading base: {base_entry['src']}")
        download(env, base_entry['src'], str(base_path))
        base_arr = load_rgb(base_path)
        new_arr = load_rgb(snap_path)

        if base_arr.shape != new_arr.shape:
            print(f"Size change {base_arr.shape} -> {new_arr.shape}; uploading as new base PNG.")
            upload(env, str(snap_path), snap_name)
            timeline.append({"time": new_time, "kind": "png", "src": snap_name,
                             "name": new_time, "bytes": png_size})
            save_timeline(env, tmp, timeline)
            print(f"Done. Timeline: {len(timeline)} entries.")
            return

        changes = compute_changes(base_arr, new_arr)
        print(f"Changes vs base: {len(changes):,}")

        # --- Activity: pixels changed since previous snapshot (symmetric diff of chains)
        activity = None
        prev_diff_set = None
        if last['kind'] == 'diff' and last.get('base') == base_entry['time']:
            try:
                prev_path = tmp / last['src']
                download(env, last['src'], str(prev_path))
                prev_diff = json.load(open(prev_path))
                prev_diff_set = diff_content_set(prev_diff)
                curr_set = set((x, y, color_to_idx[c]) for x, y, c in changes)
                activity = len(curr_set ^ prev_diff_set)
            except Exception as e:
                print(f"Warning: activity check skipped ({e})")
        if activity is not None:
            print(f"Activity: {activity:,} pixels changed since previous snapshot")

        # --- Dedupe
        if (prev_diff_set is not None
                and activity is not None
                and activity == 0):
            print(f"Identical to previous snapshot; reusing {last['src']}")
            timeline.append({
                "time": new_time, "kind": "diff",
                "format": last.get('format', 'v1'),
                "base": base_entry['time'], "src": last['src'],
                "name": new_time, "bytes": 0,
            })
            save_timeline(env, tmp, timeline)
            print(f"Done (reused). Timeline: {len(timeline)} entries.")
            return

        payload, encoded, fmt = build_diff_payload(
            base_entry['time'], new_time, changes, color_to_idx)
        print(f"Encoded: {fmt}, {len(encoded)/1024:.1f} KB")

        # --- Promote decision
        cumulative = sum(e.get('bytes', 0) for e in timeline
                         if e['kind'] == 'diff' and e.get('base') == base_entry['time'])
        cumulative += len(encoded)
        print(f"Cumulative chain: {cumulative/1024/1024:.2f} MB "
              f"(PNG size {png_size/1024/1024:.2f} MB, "
              f"threshold {CUMULATIVE_MULTIPLIER:.1f}x)")

        single_exceeded     = len(encoded) > SINGLE_DIFF_MULTIPLIER * png_size
        cumulative_exceeded = cumulative    > CUMULATIVE_MULTIPLIER * png_size

        if activity is None:
            churning = True
        else:
            churning = activity > len(changes) * ACTIVITY_FRACTION

        promote_reason = None
        if single_exceeded:
            promote_reason = 'single-diff'
        elif cumulative_exceeded and churning:
            promote_reason = 'cumulative'
        elif cumulative_exceeded and not churning:
            print(f"  (deferred promote: cumulative over threshold but chain settled; "
                  f"activity={activity or 0:,} < {ACTIVITY_FRACTION*100:.0f}% of {len(changes):,})")

        if promote_reason:
            print(f"Promoting to PNG ({promote_reason}).")
            upload(env, str(snap_path), snap_name)
            timeline.append({"time": new_time, "kind": "png", "src": snap_name,
                             "name": new_time, "bytes": png_size})
        else:
            diff_name = f"wdpdiff_{new_time}.json"
            (tmp / diff_name).write_bytes(encoded)
            print(f"Uploading diff: {diff_name}")
            upload(env, str(tmp / diff_name), diff_name)
            timeline.append({
                "time": new_time, "kind": "diff", "format": fmt,
                "base": base_entry['time'], "src": diff_name,
                "name": new_time, "bytes": len(encoded),
            })

        save_timeline(env, tmp, timeline)
        print(f"Done. Timeline: {len(timeline)} entries.")


if __name__ == '__main__':
    main()
