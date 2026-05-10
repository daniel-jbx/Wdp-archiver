#!/bin/bash
set -euo pipefail

CROPS_FILE="crops.txt"

if [ ! -f "$CROPS_FILE" ]; then
  echo "Error: $CROPS_FILE not found"
  exit 1
fi

# Collect all potential snapshots (any .png with "snapshot" in the name)
ALL_SNAPS=( *snapshot*.png )
if [ ${#ALL_SNAPS[@]} -eq 0 ]; then
  echo "No snapshot files found at all."
  exit 1
fi

# Current time in seconds since epoch
NOW_EPOCH=$(date +%s)

# Filter to only snapshots from the last 24 hours
SNAPSHOTS=()
for s in "${ALL_SNAPS[@]}"; do
  # Extract timestamp part from filename, e.g., wdpsnapshot_20260509_223954.png -> 20260509_223954
  ts_part="${s#*snapshot_}"   # remove everything up to and including "snapshot_"
  ts_part="${ts_part%_crop}"  # safety if cropped frame sneaks in (not needed but harmless)
  ts_part="${ts_part%.png}"   # remove extension

  # Reformat to YYYY-MM-DD HH:MM:SS (needed for date command)
  ts_fmt="${ts_part:0:4}-${ts_part:4:2}-${ts_part:6:2} ${ts_part:9:2}:${ts_part:11:2}:${ts_part:13:2}"

  # Convert to epoch (ignoring timezone, UTC is fine)
  file_epoch=$(date -d "$ts_fmt" +%s 2>/dev/null || echo "0")
  if [ "$file_epoch" -eq 0 ]; then
    echo "  Skipping $s (could not parse date)" >&2
    continue
  fi

  # Include if less than 24 hours old (86400 seconds)
  if [ $(( NOW_EPOCH - file_epoch )) -le 86400 ]; then
    SNAPSHOTS+=("$s")
  fi
done

if [ ${#SNAPSHOTS[@]} -eq 0 ]; then
  echo "No snapshots from the last 24 hours found. Nothing to do."
  exit 0
fi

echo "Using ${#SNAPSHOTS[@]} snapshots from the last 24 hours."

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

  # Determine font size proportional to crop height (minimum 10px)
  FONT_SIZE=$(( h / 20 ))
  [ "$FONT_SIZE" -lt 10 ] && FONT_SIZE=10

  i=0
  for snap in "${SNAPSHOTS[@]}"; do
    # Extract timestamp for the overlay
    ts_part="${snap#*snapshot_}"
    ts_part="${ts_part%.png}"
    ts_fmt="${ts_part:0:4}-${ts_part:4:2}-${ts_part:6:2} ${ts_part:9:2}:${ts_part:11:2}:${ts_part:13:2}"

    outframe="${tmpdir}/frame_$(printf "%04d" $i).png"
    echo "  cropping & annotating $snap (${x},${y} ${w}x${h}) – $ts_fmt"

    # Crop and overlay timestamp with dynamic font size
    convert "$snap" \
      -crop "${w}x${h}+${x}+${y}" +repage \
      -gravity SouthEast \
      -pointsize "$FONT_SIZE" \
      -fill white \
      -undercolor '#00000080' \
      -annotate +10+10 "$ts_fmt" \
      "$outframe"
    i=$((i+1))
  done

  # Build GIF with end pause
  frame_files=("${tmpdir}"/*.png)
  last_frame="${tmpdir}/last_hold.png"
  cp "${frame_files[-1]}" "$last_frame"

  convert \
    -delay $NORMAL_DELAY "${frame_files[@]}" \
    -delay $END_DELAY "$last_frame" \
    -loop 0 \
    "$outfile"

  echo "  GIF saved: $outfile (${#frame_files[@]} frames + end pause)"

  rm -rf "$tmpdir"
done < "$CROPS_FILE"

echo "All crops processed."
