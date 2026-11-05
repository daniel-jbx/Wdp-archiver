#!/usr/bin/env python3
"""Backfill one day of PNG snapshots into base+diffs."""
import argparse, json, re, subprocess, sys
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


def next_pending(main_timeline):
    png_times = sorted(e['time'] for e in main_timeline if e['kind'] == 'png')
    if not png_times:
        return None
    return png_times[0][:8]


def run_make_diffs(day_dir, out_dir):
    script = Path(__file__).parent / 'make-diffs.py'
    if not script.exists():
        print(f"ERROR: make-diffs.py not found next to {__file__}", file=sys.stderr)
        sys.exit(1)
    result = subprocess.run(
        ['python3', str(script), '--input', str(day_dir), '--output', str(out_dir)],
        check=False,
    )
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
            s = im.size
            sizes[s] = sizes.get(s, 0) + 1
    print(f"Day size composition:")
    for s, n in sorted(sizes.items()):
        print(f"  {n:>3} snapshots of {s[0]}x{s[1]}")
    if len(sizes) > 1:
        print(f"  Mixed sizes detected — expect {len(sizes)} base PNG(s) from size transitions")


def verify_palette_coverage(day_dir, palette):
    palette_set = set(palette)
    pngs = sorted(day_dir.glob('wdpsnapshot_*.png'))
    for p in pngs:
        with Image.open(p) as im:
            arr = np.array(im.convert('RGB'))
            unique = np.unique(arr.reshape(-1, 3), axis=0)
            for c in unique:
                hex_c = '#%02x%02x%02x' % (int(c[0]), int(c[1]), int(c[2]))
                if hex_c not in palette_set:
                    print(f"ERROR: {p.name} contains color {hex_c} not in canonical palette.")
                    sys.exit(1)
    print(f"Palette check: all colors in all {len(pngs)} snapshots found in canonical palette")


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


def compute_orphans(day_dir, day_entries):
    diff_times = {e['time'] for e in day_entries if e['kind'] == 'diff'}
    base_names = {e['src'] for e in day_entries if e['kind'] == 'png'}
    orphans = []
    if not day_dir.exists():
        return orphans
    for p in day_dir.iterdir():
        if not p.name.endswith('.png'):
            continue
        png_time = parse_ts(p.name)
        if png_time and png_time in diff_times and p.name not in base_names:
            orphans.append(p.name)
    return orphans


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--date', help='Specific day (YYYYMMDD) to backfill')
    ap.add_argument('--next-pending', action='store_true',
                    help='Print next pending day and exit (for workflow automation)')
    ap.add_argument('--day-dir', help='Directory containing this day\'s PNGs')
    ap.add_argument('--main-timeline', required=True)
    ap.add_argument('--canonical-palette')
    ap.add_argument('--publish-dir')
    ap.add_argument('--merged-timeline-out')
    ap.add_argument('--files-to-delete-out')
    args = ap.parse_args()

    main_timeline = json.load(open(args.main_timeline))
    print(f"Main timeline: {len(main_timeline)} entries")

    if args.next_pending:
        day = next_pending(main_timeline)
        if day is None:
            print("No pending days", file=sys.stderr)
            sys.exit(1)
        print(day)
        return

    if not args.date or not args.day_dir or not args.canonical_palette \
            or not args.publish_dir or not args.merged_timeline_out \
            or not args.files_to_delete_out:
        print("ERROR: --date, --day-dir, --canonical-palette, --publish-dir, "
              "--merged-timeline-out, --files-to-delete-out are all required "
              "when not using --next-pending", file=sys.stderr)
        sys.exit(1)

    day_dir = Path(args.day_dir)
    publish_dir = Path(args.publish_dir)
    publish_dir.mkdir(parents=True, exist_ok=True)

    day_entries = [e for e in main_timeline if e['time'].startswith(args.date)]
    if not day_entries:
        print(f"ERROR: no entries for {args.date} in main timeline", file=sys.stderr)
        sys.exit(1)

    if any(e['kind'] == 'diff' for e in day_entries):
        print(f"Day {args.date} already has diff entries — nothing to convert.")
        orphans = compute_orphans(day_dir, day_entries)
        with open(args.merged_timeline_out, 'w') as f:
            json.dump(main_timeline, f, indent=2)
        with open(args.files_to_delete_out, 'w') as f:
            for name in orphans:
                f.write(name + '\n')
        if orphans:
            print(f"Found {len(orphans)} orphaned originals to clean up "
                  f"(prior run crashed between timeline update and delete)")
        else:
            print("Prior run completed cleanly — no orphans")
        sys.exit(0)

    print(f"Day {args.date}: {len(day_entries)} entries, all PNGs")
    log_size_composition(day_dir)

    palette = json.load(open(args.canonical_palette))
    print(f"Canonical palette: {len(palette)} colors")
    verify_palette_coverage(day_dir, palette)

    import shutil
    shutil.copy(args.canonical_palette, publish_dir / 'palette.json')

    print(f"Running make-diffs.py on {day_dir}...")
    run_make_diffs(day_dir, publish_dir)

    day_timeline_path = publish_dir / 'timeline.json'
    if not day_timeline_path.exists():
        print(f"ERROR: make-diffs.py did not produce {day_timeline_path}", file=sys.stderr)
        sys.exit(1)
    day_timeline = json.load(open(day_timeline_path))
    n_png = sum(1 for e in day_timeline if e['kind'] == 'png')
    n_diff = sum(1 for e in day_timeline if e['kind'] == 'diff')
    print(f"Day timeline: {len(day_timeline)} entries ({n_png} bases, {n_diff} diffs)")

    merged = merge_timelines(main_timeline, day_timeline, args.date)
    if not validate(main_timeline, merged, args.date):
        print("ERROR: merge validation failed", file=sys.stderr)
        sys.exit(1)
    print(f"Merged timeline: {len(merged)} entries (was {len(main_timeline)})")

    bases = set(p.name for p in publish_dir.iterdir() if p.suffix == '.png')
    to_delete = [p.name for p in day_dir.iterdir()
                 if p.suffix == '.png' and p.name not in bases]
    print(f"PNGs to delete from R2: {len(to_delete)} (keeping {len(bases)} bases)")

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
