#!/bin/bash
set -euo pipefail

CROPS_FILE="crops.txt"

if [ ! -f "$CROPS_FILE" ]; then
  echo "Error: $CROPS_FILE not found"
  exit 1
fi

# Collect snapshots (matches any .png with "snapshot" in the name)
SNAPSHOTS=( *snapshot*.png )
if [ ${#SNAPSHOTS[@]} -eq 0 ]; then
  echo "No snapshot files found."
  exit 1
fi

echo "Found ${#SNAPSHOTS[@]} snapshots."

# Normal delay between frames (1/100 sec)
NORMAL_DELAY=20
# Extra delay for the last frame (larger -> longer pause)
END_DELAY=100

# Read each crop definition
while read -r name x y w h outfile; do
  [[ -z "$name" || "$name" == \#* ]] && continue

  echo "--- Processing crop: $name -> $outfile ---"

  tmpdir="tmp_${name}"
  mkdir -p "$tmpdir"

  # We'll create annotated cropped frames
  i=0
  for snap in "${SNAPSHOTS[@]}"; do
    # Extract timestamp from filename (e.g., wdpsnapshot_20260509_223954.png -> 2026-05-09 22:39:54)
    ts_raw="${snap##*snapshot_}"       # remove everything before 'snapshot_'
    ts_raw="${ts_raw%.png}"            # strip extension
    # Reformat to a human-readable date (YYYY-MM-DD HH:MM:SS)
    ts_fmt="${ts_raw:0:4}-${ts_raw:4:2}-${ts_raw:6:2} ${ts_raw:9:2}:${ts_raw:11:2}:${ts_raw:13:2}"

    outframe="${tmpdir}/frame_$(printf "%04d" $i).png"
    echo "  cropping & annotating $snap (${x},${y} ${w}x${h}) – $ts_fmt"

    # Crop the full snapshot, then overlay the timestamp in the bottom-right corner
    convert "$snap" \
      -crop "${w}x${h}+${x}+${y}" +repage \
      -gravity SouthEast \
      -pointsize 24 \
      -fill white \
      -undercolor '#00000080' \
      -annotate +10+10 "$ts_fmt" \
      "$outframe"
    i=$((i+1))
  done

  # Build the GIF: all frames with normal delay, then copy last frame with a longer delay
  # Use a list of files with -delay options
  frame_files=("${tmpdir}"/*.png)
  last_frame="${tmpdir}/last_hold.png"
  cp "${frame_files[-1]}" "$last_frame"

  # Construct convert command
  # Syntax: convert -delay NORMAL file1 ... -delay END file_hold -loop 0 output.gif
  convert \
    -delay $NORMAL_DELAY "${frame_files[@]}" \
    -delay $END_DELAY "$last_frame" \
    -loop 0 \
    "$outfile"

  echo "  GIF saved: $outfile (${#frame_files[@]} frames + end pause)"

  # Clean up
  rm -rf "$tmpdir"
done < "$CROPS_FILE"

echo "All crops processed."
