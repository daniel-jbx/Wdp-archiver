#!/usr/bin/env python3
"""Backfill one day of PNG snapshots into base+diffs (chain-continuous, race-safe)."""
import argparse, json, os, subprocess, sys
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
         '--s3-no-check-bucket', *args],
        check=True,
    )


def next_pending(main_timeline):
    """Return earliest YYYYMMDD that still has PNG entries but no diffs.
    Days already backfilled have a base PNG + diffs, so they're skipped."""
    by_day = {}
    for e in main_timeline:
        day = e['time'][:8]
        by_day.setdefault(day, []).append(e)
    for day in sorted(by_day.keys()):
        entries = by_day[day]
        has_png  = any(e['kind'] == 'png'  for e in entries)
        has_diff = any(e['kind'] == 'diff' for e in entries)
        if has_png and not has_diff:
            return day
    return None


def run_make_diffs(day_dir, out_dir, chain_state_path=None):
    script = Path(__file__).parent / 'make-diffs.py'
    if not script.exists():
        print(f"ERROR: make-diffs.py not found next to {__file__}", file=sys.stderr)
        sys.exit(1)
    cmd = ['python3', str(script), '--input', str(day_dir), '--output', str(out_dir)]
    if chain_state_path:
        cmd.extend(['--chain-state', str(chain_state_path)])
    result = subprocess.run(cmd, check=False)
    if result.returncode != 0:
        print(f"ERROR: make-diffs.py failed with exit {result.returncode}", file=sys.stderr)
        sys.exit(1)


def log_size_composition(day_dir):
    pngs = sorted(day_dir.glob('wdpsnapshot_*.png'))
    if not pngs:
        return
    sizes = {}
    for p in pngs:
        with Image.open(p) as im:
            sizes[im.size] = sizes.get(im.size, 0) + 1
    print("Day size composition:")
    for s, n in sorted(sizes.items()):
        print(f"  {n:>3} snapshots of {s[0]}x{s[1]}")
    if len(sizes) > 1:
        print(f"  Mixed sizes detected — expect {len(sizes)} base PNG(s) from size transitions")


def verify_palette_coverage(day_dir, palette):
    pngs = sorted(day_dir.glob('wdpsnapshot_*.png'))
    if not pngs:
        return
    sample = pngs[0]
    palette_set = set(palette)
    with Image.open(sample) as im:
        arr = np.array(im.convert('RGB'))
        unique = np.unique(arr.reshape(-1, 3), axis=0)
        for c in unique:
            hex_c = '#%02x%02x%02x' % (int(c[0]), int(c[1]), int(c[2]))
            if hex_c not in palette_set:
                print(f"ERROR: {sample.name} contains color {hex_c} not in canonical palette.")
                sys.exit(1)
    print(f"Palette check: {sample.name} verified against canonical palette "
          f"(spot-check of 1 of {len(pngs)} snapshots)")


def find_chain_state(main_timeline, date):
    day_start = date + '_000000'
    prior = [e for e in main_timeline if e['time'] < day_start]
    if not prior:
        return None
    base_entry = None
    for e in reversed(prior):
        if e['kind'] == 'png':
            base_entry = e
            break
    if base_entry is None:
        return None
    base_idx = next(i for i, e in enumerate(main_timeline)
                    if e['time'] == base_entry['time'] and e['kind'] == 'png')
    diffs_since_base = [e for e in main_timeline[base_idx+1:]
                        if e['kind'] == 'diff' and e.get('base') == base_entry['time']]
    cumulative = sum(e.get('bytes', 0) for e in diffs_since_base)
    last_diff_src = None
    for e in reversed(prior):
        if e['kind'] == 'diff':
            last_diff_src = e['src']
            break
    return {
        'base_time': base_entry['time'],
        'base_png_src': base_entry['src'],
        'cumulative_bytes': cumulative,
        'last_diff_src': last_diff_src,
    }


def merge_timelines(main_timeline, day_timeline, date):
    kept = [e for e in main_timeline if not e['time'].startswith(date)]
    merged = kept + day_timeline
    merged.sort(key=lambda e: e['time'])
    return merged


def validate(old_timeline, new_timeline, date):
    old_day = [e for e in old_timeline if e['time'].startswith(date)]
    new_day = [e for e in new_timeline if e['time'].startswith(date)]
    if set(e['time'] for e in old_day) != set(e['time'] for e in new_day):
        print("ERROR: timestamp set mismatch after merge", file=sys.stderr)
        return False
    if len(old_timeline) - len(old_day) != len(new_timeline) - len(new_day):
        print("ERROR: non-day entries count changed", file=sys.stderr)
        return False
    return True


def recheck_timeline(env, publish_dir, date, main_timeline):
    print("Re-checking timeline from R2 before merge (race guard)...")
    fresh_path = publish_dir / 'fresh-timeline.json'
    rclone(env, 'copyto', f':s3:{env["R2_BUCKET"]}/timeline.json', str(fresh_path))
    fresh = json.load(open(fresh_path))
    print(f"  Fresh: {len(fresh)} entries (started with {len(main_timeline)})")
    fresh_day = [e for e in fresh if e['time'].startswith(date)]
    if any(e['kind'] == 'diff' for e in fresh_day):
        print(f"Day {date} was backfilled by a concurrent run. Aborting to avoid clobber.")
        return None
    return fresh


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--next-pending', action='store_true',
                    help='Print next pending day (YYYYMMDD) and exit')
    ap.add_argument('--main-timeline', required=True)
    ap.add_argument('--date', default=None)
    ap.add_argument('--day-dir', default=None)
    ap.add_argument('--canonical-palette', default=None)
    ap.add_argument('--publish-dir', default=None)
    ap.add_argument('--merged-timeline-out', default=None)
    ap.add_argument('--files-to-delete-out', default=None)
    ap.add_argument('--prior-base-dir', default=None)
    ap.add_argument('--recheck-timeline', action='store_true')
    args = ap.parse_args()

    # next-pending mode: exit 0 with no output = nothing to do
    #                    exit 0 with day    = work to do
    #                    exit != 0          = error
    if args.next_pending:
        main_timeline = json.load(open(args.main_timeline))
        day = next_pending(main_timeline)
        if day is None:
            sys.exit(0)   # silent success, no output
        print(day)
        sys.exit(0)

    missing = [f.replace('_', '-') for f in
               ['date', 'day_dir', 'canonical_palette', 'publish_dir',
                'merged_timeline_out', 'files_to_delete_out', 'prior_base_dir']
               if not getattr(args, f)]
    if missing:
        print(f"ERROR: missing required args: --{', --'.join(missing)}", file=sys.stderr)
        sys.exit(2)

    day_dir = Path(args.day_dir)
    publish_dir = Path(args.publish_dir)
    prior_base_dir = Path(args.prior_base_dir)
    publish_dir.mkdir(parents=True, exist_ok=True)

    env = None
    if args.recheck_timeline:
        env = {k: os.environ[k] for k in (
            'R2_ENDPOINT', 'R2_ACCESS_KEY_ID', 'R2_SECRET_ACCESS_KEY', 'R2_BUCKET')}

    main_timeline = json.load(open(args.main_timeline))
    print(f"Main timeline: {len(main_timeline)} entries")

    day_entries = [e for e in main_timeline if e['time'].startswith(args.date)]
    if not day_entries:
        print(f"ERROR: no entries for {args.date} in main timeline", file=sys.stderr)
        sys.exit(1)
    if any(e['kind'] == 'diff' for e in day_entries):
        print(f"Day {args.date} already has diff entries — nothing to do.")
        sys.exit(0)
    print(f"Day {args.date}: {len(day_entries)} entries, all PNGs")

    log_size_composition(day_dir)

    palette = json.load(open(args.canonical_palette))
    print(f"Canonical palette: {len(palette)} colors")
    verify_palette_coverage(day_dir, palette)

    import shutil
    shutil.copy(args.canonical_palette, publish_dir / 'palette.json')

    chain_state = find_chain_state(main_timeline, args.date)
    chain_state_path = None
    if chain_state:
        print(f"Chain state from prior days:")
        print(f"  base:       {chain_state['base_time']} ({chain_state['base_png_src']})")
        print(f"  cumulative: {chain_state['cumulative_bytes']/1024:.1f} KB")
        print(f"  last diff:  {chain_state['last_diff_src']}")
        base_local = prior_base_dir / chain_state['base_png_src']
        if not base_local.exists():
            print(f"ERROR: prior base PNG not pre-downloaded: {base_local}", file=sys.stderr)
            sys.exit(1)
        last_diff_local = None
        if chain_state['last_diff_src']:
            last_diff_local = prior_base_dir / chain_state['last_diff_src']
            if not last_diff_local.exists():
                print(f"ERROR: prior last diff not pre-downloaded: {last_diff_local}",
                      file=sys.stderr)
                sys.exit(1)
        chain_state['base_png_local'] = str(base_local)
        chain_state['last_diff_local'] = str(last_diff_local) if last_diff_local else None
        chain_state_path = publish_dir / 'chain_state.json'
        with open(chain_state_path, 'w') as f:
            json.dump(chain_state, f)
    else:
        print("No prior chain — this will start a new base")

    print(f"Running make-diffs.py on {day_dir}...")
    run_make_diffs(day_dir, publish_dir, chain_state_path)

    day_timeline_path = publish_dir / 'timeline.json'
    if not day_timeline_path.exists():
        print(f"ERROR: make-diffs.py did not produce {day_timeline_path}", file=sys.stderr)
        sys.exit(1)
    day_timeline = json.load(open(day_timeline_path))
    n_png = sum(1 for e in day_timeline if e['kind'] == 'png')
    n_diff = sum(1 for e in day_timeline if e['kind'] == 'diff')
    print(f"Day timeline: {len(day_timeline)} entries ({n_png} bases, {n_diff} diffs)")

    if args.recheck_timeline:
        fresh = recheck_timeline(env, publish_dir, args.date, main_timeline)
        if fresh is None:
            sys.exit(0)
        main_timeline = fresh

    merged = merge_timelines(main_timeline, day_timeline, args.date)
    if not validate(main_timeline, merged, args.date):
        print("ERROR: merge validation failed", file=sys.stderr)
        sys.exit(1)
    print(f"Merged timeline: {len(merged)} entries (was {len(main_timeline)})")

    bases = set(p.name for p in publish_dir.iterdir() if p.suffix == '.png')
    to_delete = [p.name for p in day_dir.iterdir()
                 if p.suffix == '.png' and p.name not in bases]
    print(f"PNGs to delete from R2: {len(to_delete)} (keeping {len(bases)} today's bases)")

    with open(args.merged_timeline_out, 'w') as f:
        json.dump(merged, f, indent=2)
    with open(args.files_to_delete_out, 'w') as f:
        for name in to_delete:
            f.write(name + '\n')

    print()
    print("=== Summary ===")
    print(f"Original: {len(day_entries)} PNGs")
    print(f"New:      {n_png} base PNG(s) + {n_diff} diff(s)")
    print(f"Delete:   {len(to_delete)} original PNGs")


if __name__ == '__main__':
    main()
