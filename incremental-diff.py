#!/usr/bin/env python3
import argparse, brotli, json, os, re, subprocess, sys, tempfile
from pathlib import Path

try:
    import numpy as np
    from PIL import Image
except ImportError:
    print("ERROR: needs Pillow and numpy", file=sys.stderr, flush=True)
    sys.exit(1)

SINGLE_DIFF_MULTIPLIER   = 1.0
CUMULATIVE_MULTIPLIER    = 1.0
BROTLI_QUALITY           = 11


def rclone(env, *args):
    return subprocess.run(
        ['rclone',
         '--s3-provider=Cloudflare',
         f'--s3-endpoint={env["R2_ENDPOINT"]}',
         f'--s3-access-key-id={env["R2_ACCESS_KEY_ID"]}',
         f'--s3-secret-access-key={env["R2_SECRET_ACCESS_KEY"]}',
         '--s3-no-check-bucket',
         '--log-level', 'ERROR',
         '--timeout', '15s',
         '--contimeout', '15s',
         '--retries', '3',
         *args],
        check=True,
    )


def download(env, remote, local):
    rclone(env, 'copyto', f':s3:{env["R2_BUCKET"]}/{remote}', local)


def upload(env, local, remote):
    rclone(env, 'copyto', local, f':s3:{env["R2_BUCKET"]}/{remote}')


def upload_brotli(env, compressed_bytes, remote):
    with tempfile.NamedTemporaryFile(delete=False, suffix='.json') as tmp:
        tmp.write(compressed_bytes)
        tmp_path = tmp.name
    try:
        rclone(env, 'copyto', tmp_path, f':s3:{env["R2_BUCKET"]}/{remote}',
               '--header-upload', 'Content-Encoding: br')
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


def read_diff(path):
    raw = path.read_bytes()
    try:
        return json.loads(brotli.decompress(raw))
    except Exception:
        return json.loads(raw)


def recheck_or_abort(env, tmp, timeline):
    recheck_path = tmp / 'timeline-recheck.json'
    try:
        download(env, 'timeline.json', str(recheck_path))
        fresh = json.load(open(recheck_path))
        if len(fresh) != len(timeline) or (fresh and timeline and fresh[-1]['time'] != timeline[-1]['time']):
            print(f"ABORT: timeline modified by concurrent writer "
                  f"({len(timeline)}→{len(fresh)} entries). "
                  f"Snapshot will be captured on next run.", flush=True)
            sys.exit(0)
    except subprocess.CalledProcessError:
        pass


def load_image(path):
    with Image.open(path) as im:
        arr_rgba = np.array(im.convert('RGBA'))
        has_transparency = np.any(arr_rgba[:, :, 3] == 0)
        arr_rgb = arr_rgba[:, :, :3].copy()
    return arr_rgb, has_transparency


def ensure_palette(env, sample_arr, tmp):
    local = tmp / 'palette.json'
    try:
        download(env, 'palette.json', str(local))
    except subprocess.CalledProcessError:
        pass
    if local.exists():
        palette = json.load(open(local))
        print(f"Palette: loaded {len(palette)} colors from R2", flush=True)
        return palette
    unique = np.unique(sample_arr.reshape(-1, 3), axis=0)
    palette = ['#%02x%02x%02x' % tuple(int(v) for v in c) for c in unique]
    with open(local, 'w') as f:
        json.dump(palette, f)
    upload(env, str(local), 'palette.json')
    print(f"Palette: generated {len(palette)} colors and uploaded to R2", flush=True)
    return palette


def compute_changes_np(base_arr, new_arr, palette):
    mask = np.any(base_arr != new_arr, axis=2)
    ys, xs = np.where(mask)
    if len(xs) == 0:
        return xs, ys, np.zeros(0, dtype=np.uint8)
    colors = new_arr[ys, xs]
    packed = (colors[:, 0].astype(np.uint32) << 16) | \
             (colors[:, 1].astype(np.uint32) << 8) | \
             colors[:, 2].astype(np.uint32)
    lookup = np.zeros(1 << 24, dtype=np.uint8)
    for i, hex_c in enumerate(palette):
        r = int(hex_c[1:3], 16); g = int(hex_c[3:5], 16); b = int(hex_c[5:7], 16)
        lookup[(r << 16) | (g << 8) | b] = i
    return xs, ys, lookup[packed]


def encode_rle_rows_np(xs, ys, idxs):
    if len(xs) == 0:
        return []
    order = np.lexsort((xs, ys))
    xs, ys, idxs = xs[order], ys[order], idxs[order]
    new_segment = np.ones(len(xs), dtype=bool)
    new_segment[1:] = (ys[1:] != ys[:-1]) | (xs[1:] != xs[:-1] + 1)
    segment_starts = np.where(new_segment)[0]
    rows = []
    for i, start_idx in enumerate(segment_starts):
        y = int(ys[start_idx]); x_start = int(xs[start_idx])
        end_idx = segment_starts[i+1] if i+1 < len(segment_starts) else len(xs)
        seg_idxs = idxs[start_idx:end_idx]
        idx_changes = np.ones(len(seg_idxs), dtype=bool)
        idx_changes[1:] = (seg_idxs[1:] != seg_idxs[:-1])
        run_starts = np.where(idx_changes)[0]
        run_lengths = np.diff(np.append(run_starts, len(seg_idxs)))
        runs = [[int(seg_idxs[r]), int(run_lengths[j])] for j, r in enumerate(run_starts)]
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
    if diff.get('format') == 'v1':
        return None
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


def pack_change_set(xs, ys, idxs):
    if len(xs) == 0:
        return set()
    packed = (ys.astype(np.int64) << 32) | (xs.astype(np.int64) << 16) | idxs.astype(np.int64)
    return set(packed.tolist())


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
        print(f"ERROR: snapshot not found: {snap_path}", file=sys.stderr, flush=True)
        sys.exit(1)
    snap_name = snap_path.name
    new_time = parse_ts(snap_name)
    if not new_time:
        print(f"ERROR: cannot parse timestamp from {snap_name}", file=sys.stderr, flush=True)
        sys.exit(1)
    png_size = snap_path.stat().st_size

    print(f"New snapshot: {snap_name} ({png_size/1024/1024:.2f} MB)", flush=True)
    print(f"Timestamp:    {new_time}", flush=True)

    new_arr, has_trans = load_image(snap_path)
    if not has_trans:
        print(f"{new_time}: WARNING: Image has zero transparency (flattened)", flush=True)
        print(f"  Snapshot will NOT be uploaded and NOT added to timeline", flush=True)
        sys.exit(0)

    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = Path(tmpdir)
        palette = ensure_palette(env, new_arr, tmp)

        timeline_path = tmp / 'timeline.json'
        try:
            download(env, 'timeline.json', str(timeline_path))
        except subprocess.CalledProcessError:
            pass
        if not timeline_path.exists():
            print("No existing timeline.json; initializing with this snapshot as base.", flush=True)
            upload(env, str(snap_path), snap_name)
            timeline = [{"time": new_time, "kind": "png", "src": snap_name,
                         "name": new_time, "bytes": png_size}]
            save_timeline(env, tmp, timeline)
            print("Done (first entry).", flush=True)
            return
        timeline = json.load(open(timeline_path))
        print(f"Loaded timeline: {len(timeline)} entries", flush=True)

        if not timeline:
            print("ERROR: timeline.json is empty", file=sys.stderr, flush=True)
            sys.exit(1)

        last = timeline[-1]
        if last['time'] >= new_time:
            print(f"ERROR: {new_time} not newer than {last['time']}", file=sys.stderr, flush=True)
            sys.exit(1)
        print(f"Previous tip: {last['time']} ({last['kind']})", flush=True)

        base_entry = None
        for entry in reversed(timeline):
            if entry['kind'] == 'png':
                base_entry = entry
                break
        if not base_entry:
            print("ERROR: no PNG base in timeline", file=sys.stderr, flush=True)
            sys.exit(1)

        base_path = tmp / base_entry['src']
        print(f"Downloading base: {base_entry['src']}", flush=True)
        download(env, base_entry['src'], str(base_path))
        base_arr, _ = load_image(base_path)

        if base_arr.shape != new_arr.shape:
            print(f"Size change {base_arr.shape} -> {new_arr.shape}; uploading as new base PNG.", flush=True)
            upload(env, str(snap_path), snap_name)
            timeline.append({"time": new_time, "kind": "png", "src": snap_name,
                             "name": new_time, "bytes": png_size})
            save_timeline(env, tmp, timeline)
            print(f"Done. Timeline: {len(timeline)} entries.", flush=True)
            return

        xs, ys, idxs = compute_changes_np(base_arr, new_arr, palette)
        print(f"Changes vs base: {len(xs):,}", flush=True)
        curr_set = pack_change_set(xs, ys, idxs)

        activity = None
        prev_diff_set = None
        if last['kind'] == 'diff' and last.get('base') == base_entry['time']:
            try:
                prev_path = tmp / last['src']
                download(env, last['src'], str(prev_path))
                prev_diff = read_diff(prev_path)
                prev_diff_set = diff_content_set(prev_diff)
                if prev_diff_set is not None:
                    activity = len(curr_set ^ prev_diff_set)
                else:
                    print("Prior diff is v1 format — dedupe disabled for this run", flush=True)
            except Exception as e:
                print(f"Warning: activity check skipped ({e})", flush=True)
        if activity is not None:
            print(f"Activity: {activity:,} pixels changed since previous snapshot", flush=True)

        if prev_diff_set is not None and activity == 0:
            print(f"Identical to previous snapshot; reusing {last['src']}", flush=True)
            recheck_or_abort(env, tmp, timeline)
            reused = {
                "time": new_time, "kind": "diff",
                "format": last.get('format', 'v1'),
                "base": base_entry['time'], "src": last['src'],
                "name": new_time, "bytes": 0,
            }
            if "codec" in last:
                reused["codec"] = last["codec"]
            timeline.append(reused)
            save_timeline(env, tmp, timeline)
            print(f"Done (reused). Timeline: {len(timeline)} entries.", flush=True)
            return

        payload, encoded_raw, fmt = build_diff_payload(
            base_entry['time'], new_time, xs, ys, idxs)
        encoded = brotli.compress(encoded_raw, quality=BROTLI_QUALITY)
        print(f"Encoded: {fmt}, {len(encoded)/1024:.1f} KB (br from {len(encoded_raw)/1024:.1f} KB)", flush=True)

        cumulative = sum(e.get('bytes', 0) for e in timeline
                         if e['kind'] == 'diff' and e.get('base') == base_entry['time'])
        cumulative += len(encoded)
        print(f"Cumulative chain: {cumulative/1024/1024:.2f} MB "
              f"(PNG size {png_size/1024/1024:.2f} MB, threshold {CUMULATIVE_MULTIPLIER:.1f}x)", flush=True)

        single_exceeded     = len(encoded) > SINGLE_DIFF_MULTIPLIER * png_size
        cumulative_exceeded = cumulative    > CUMULATIVE_MULTIPLIER * png_size

        promote_reason = None
        if single_exceeded:
            promote_reason = 'single-diff'
        elif cumulative_exceeded:
            promote_reason = 'cumulative'

        recheck_or_abort(env, tmp, timeline)

        if promote_reason:
            print(f"Promoting to PNG ({promote_reason}).", flush=True)
            upload(env, str(snap_path), snap_name)
            timeline.append({"time": new_time, "kind": "png", "src": snap_name,
                             "name": new_time, "bytes": png_size})
        else:
            diff_name = f"wdpdiff_{new_time}.json"
            print(f"Uploading diff: {diff_name}", flush=True)
            upload_brotli(env, encoded, diff_name)
            timeline.append({
                "time": new_time, "kind": "diff", "format": fmt, "codec": "br",
                "base": base_entry['time'], "src": diff_name,
                "name": new_time, "bytes": len(encoded),
            })

        save_timeline(env, tmp, timeline)
        print(f"Done. Timeline: {len(timeline)} entries.", flush=True)


if __name__ == '__main__':
    main()
