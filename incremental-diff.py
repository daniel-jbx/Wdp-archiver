#!/usr/bin/env python3
"""Incremental diff for a single new snapshot.

Called by the daily pipeline after stitching. Reads current timeline.json
from R2, computes diff against the current base, uploads either a diff file
or a promoted PNG, and appends to timeline.json.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import numpy as np
    from PIL import Image
except ImportError:
    print("ERROR: needs Pillow and numpy", file=sys.stderr)
    sys.exit(1)


def rclone(env, *args):
    return subprocess.run(
        ['rclone',
         '--s3-provider=Cloudflare',
         f'--s3-endpoint={env["R2_ENDPOINT"]}',
         f'--s3-access-key-id={env["R2_ACCESS_KEY_ID"]}',
         f'--s3-secret-access-key={env["R2_SECRET_ACCESS_KEY"]}',
         '--s3-no-check-bucket',
         *args],
        check=True,
    )


def download(env, remote, local):
    rclone(env, 'copyto', f':s3:{env["R2_BUCKET"]}/{remote}', local)


def upload(env, local, remote):
    rclone(env, 'copyto', local, f':s3:{env["R2_BUCKET"]}/{remote}')


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


def parse_ts(name):
    m = re.search(r'(\d{8})_(\d{6})', name)
    return f"{m.group(1)}_{m.group(2)}" if m else None


def save_timeline(env, tmp, timeline):
    path = Path(tmp) / 'timeline.json'
    with open(path, 'w') as f:
        json.dump(timeline, f, indent=2)
    upload(env, str(path), 'timeline.json')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--snapshot', required=True, help='Path to new snapshot PNG')
    ap.add_argument('--promote-threshold-bytes', type=int, default=500_000)
    args = ap.parse_args()

    env = {k: os.environ[k] for k in (
        'R2_ENDPOINT', 'R2_ACCESS_KEY_ID', 'R2_SECRET_ACCESS_KEY', 'R2_BUCKET'
    )}

    snap_path = Path(args.snapshot)
    if not snap_path.exists():
        print(f"ERROR: snapshot not found: {snap_path}", file=sys.stderr)
        sys.exit(1)
    snap_name = snap_path.name
    if not (snap_name.startswith('wdpsnapshot_') and snap_name.endswith('.png')):
        print(f"ERROR: unexpected filename: {snap_name}", file=sys.stderr)
        sys.exit(1)
    new_time = parse_ts(snap_name)
    if not new_time:
        print(f"ERROR: cannot parse timestamp from {snap_name}", file=sys.stderr)
        sys.exit(1)

    print(f"New snapshot: {snap_name}")
    print(f"Timestamp:    {new_time}")

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        timeline_path = tmp / 'timeline.json'
        try:
            download(env, 'timeline.json', str(timeline_path))
            with open(timeline_path) as f:
                timeline = json.load(f)
            print(f"Loaded timeline: {len(timeline)} entries")
        except subprocess.CalledProcessError:
            print("No existing timeline.json; initializing with this snapshot as base.")
            upload(env, str(snap_path), snap_name)
            timeline = [{"time": new_time, "kind": "png", "src": snap_name, "name": new_time}]
            save_timeline(env, tmp, timeline)
            print("Done (first entry).")
            return

        if not timeline:
            print("ERROR: timeline.json is empty", file=sys.stderr)
            sys.exit(1)

        last = timeline[-1]
        if last['time'] >= new_time:
            print(f"ERROR: new snapshot {new_time} is not newer than last entry {last['time']}",
                  file=sys.stderr)
            sys.exit(1)
        print(f"Previous tip: {last['time']} ({last['kind']})")

        # Find the most recent PNG entry as the current base
        base_entry = None
        for entry in reversed(timeline):
            if entry['kind'] == 'png':
                base_entry = entry
                break
        if not base_entry:
            print("ERROR: no PNG entry in timeline to serve as base", file=sys.stderr)
            sys.exit(1)

        base_path = tmp / base_entry['src']
        print(f"Downloading base: {base_entry['src']}")
        download(env, base_entry['src'], str(base_path))
        base_arr = load_rgb(base_path)
        new_arr = load_rgb(snap_path)

        if base_arr.shape != new_arr.shape:
            print(f"Size change {base_arr.shape} -> {new_arr.shape}; uploading as new base PNG.")
            upload(env, str(snap_path), snap_name)
            timeline.append({"time": new_time, "kind": "png", "src": snap_name, "name": new_time})
            save_timeline(env, tmp, timeline)
            print(f"Done (size-change base). Timeline: {len(timeline)} entries.")
            return

        changes = compute_changes(base_arr, new_arr)
        print(f"Changes vs base: {len(changes):,}")

        # Dedupe: if identical to previous snapshot AND same base, reuse its diff file
        if last['kind'] == 'diff' and last.get('base') == base_entry['time']:
            prev_diff_path = tmp / last['src']
            try:
                download(env, last['src'], str(prev_diff_path))
                with open(prev_diff_path) as f:
                    prev_diff = json.load(f)
                if prev_diff.get('changes') == changes:
                    print(f"Identical to previous snapshot; reusing {last['src']}")
                    timeline.append({
                        "time": new_time, "kind": "diff",
                        "base": base_entry['time'], "src": last['src'], "name": new_time,
                    })
                    save_timeline(env, tmp, timeline)
                    print(f"Done (reused). Timeline: {len(timeline)} entries.")
                    return
            except Exception as e:
                print(f"Warning: dedupe check skipped ({e})")

        payload = json.dumps(
            {"base": base_entry['time'], "timestamp": new_time, "changes": changes},
            separators=(',', ':')
        ).encode('utf-8')
        print(f"Serialized diff: {len(payload)/1024:.1f} KB")

        if len(payload) > args.promote_threshold_bytes:
            print(f"Promoting to PNG (> {args.promote_threshold_bytes} bytes).")
            upload(env, str(snap_path), snap_name)
            timeline.append({"time": new_time, "kind": "png", "src": snap_name, "name": new_time})
        else:
            diff_name = f"wdpdiff_{new_time}.json"
            diff_path = tmp / diff_name
            diff_path.write_bytes(payload)
            print(f"Uploading diff: {diff_name}")
            upload(env, str(diff_path), diff_name)
            timeline.append({
                "time": new_time, "kind": "diff",
                "base": base_entry['time'], "src": diff_name, "name": new_time,
            })

        save_timeline(env, tmp, timeline)
        print(f"Done. Timeline: {len(timeline)} entries.")


if __name__ == '__main__':
    main()
