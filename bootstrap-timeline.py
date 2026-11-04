#!/usr/bin/env python3
"""One-shot: build timeline.json from the existing snapshots.json manifest.

Every entry is recorded as kind='png' pointing at the existing file, so the
viewer's new timeline-aware code path renders identically to the old fallback.
"""
import json
import sys
from pathlib import Path


def main():
    input_path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('snapshots.json')
    output_path = Path(sys.argv[2]) if len(sys.argv) > 2 else Path('timeline.json')

    if not input_path.exists():
        print(f"ERROR: {input_path} not found", file=sys.stderr)
        sys.exit(1)

    with open(input_path) as f:
        files = json.load(f)

    entries = []
    skipped = []
    for name in files:
        # Expected: "wdpsnapshot_YYYYMMDD_HHMMSS.png"
        if not (name.startswith('wdpsnapshot_') and name.endswith('.png')):
            skipped.append(name)
            continue
        stem = name[len('wdpsnapshot_'):-len('.png')]
        entries.append({
            "time": stem,
            "kind": "png",
            "src":  name,
            "name": stem,
        })

    entries.sort(key=lambda e: e["time"])

    if skipped:
        print(f"Skipped {len(skipped)} non-matching entries:")
        for s in skipped[:10]:
            print(f"  {s}")
        if len(skipped) > 10:
            print(f"  ... and {len(skipped) - 10} more")

    with open(output_path, 'w') as f:
        json.dump(entries, f, indent=2)

    print(f"Input snapshots:  {len(files)}")
    print(f"Written entries:  {len(entries)}")
    print(f"Output size:      {output_path.stat().st_size / 1024:.1f} KB")
    print(f"First entry:      {entries[0]['time'] if entries else '(none)'}")
    print(f"Last entry:       {entries[-1]['time'] if entries else '(none)'}")

    if not entries:
        print("ERROR: no entries produced", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
