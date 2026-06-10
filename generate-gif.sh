#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${1:-gif-config.json}"

# -- Read configuration ------------------------------------------------
START=$(jq -r '.start' "$CONFIG_FILE")
END=$(jq -r '.end' "$CONFIG_FILE")
X1=$(jq -r '.x[0]' "$CONFIG_FILE")
X2=$(jq -r '.x[1]' "$CONFIG_FILE")
Y1=$(jq -r '.y[0]' "$CONFIG_FILE")
Y2=$(jq -r '.y[1]' "$CONFIG_FILE")
SPEED=$(jq -r '.speed' "$CONFIG_FILE")
OUTPUT_GIF=$(jq -r '.output_gif' "$CONFIG_FILE")

# Validate
if [[ -z "$START" || -z "$END" || -z "$SPEED" || -z "$OUTPUT_GIF" ]]; then
  echo "Missing required fields in $CONFIG_FILE"
  exit 1
fi

# Crop dimensions (inclusive start, exclusive end)
WIDTH=$(( X2 - X1 ))
HEIGHT=$(( Y2 - Y1 ))
CROP="${WIDTH}x${HEIGHT}+${X1}+${Y1}"

# R2 environment
: "${R2_BUCKET:?R2_BUCKET not set}"
: "${R2_ENDPOINT:?R2_ENDPOINT not set}"
: "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID not set}"
: "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY not set}"

RCLONE_BASE=(
  --s3-provider="Cloudflare"
  --s3-endpoint="$R2_ENDPOINT"
  --s3-access-key-id="$R2_ACCESS_KEY_ID"
  --s3-secret-access-key="$R2_SECRET_ACCESS_KEY"
  --s3-no-check-bucket
  --log-level ERROR
)

# -- Fetch snapshot list from R2 ---------------------------------------
echo "Downloading snapshots.json..."
rclone cat ":s3:${R2_BUCKET}/snapshots.json" "${RCLONE_BASE[@]}" > snapshots.json

# Filter and sort snapshots by timestamp
START_EPOCH=$(date -d"$START" +%s)
END_EPOCH=$(date -d"$END" +%s)

mapfile -t SNAPSHOTS < <(
  jq -r '.[]' snapshots.json | \
  while IFS= read -r fname; do
    # Filename pattern: wdpsnapshot_YYYYMMDD_HHMMSS.png
    if [[ $fname =~ wdpsnapshot_([0-9]{8})_([0-9]{6})\.png$ ]]; then
      datestr="${BASH_REMATCH[1]}"
      timestr="${BASH_REMATCH[2]}"
      ts=$(date -d"${datestr:0:4}-${datestr:4:2}-${datestr:6:2}T${timestr:0:2}:${timestr:2:2}:${timestr:4:2}Z" +%s 2>/dev/null) || continue
      if (( ts >= START_EPOCH && ts <= END_EPOCH )); then
        echo "$fname"
      fi
    fi
  done | sort
)

if [[ ${#SNAPSHOTS[@]} -eq 0 ]]; then
  echo "No snapshots found in the given time range."
  exit 1
fi

# -- Download, crop, and add timestamp banner --------------------------
mkdir -p frames processed
echo "Downloading and processing ${#SNAPSHOTS[@]} snapshots..."

# Font size proportional to crop height (minimum 10px)
FONT_SIZE=$(( HEIGHT / 20 ))
if [[ $FONT_SIZE -lt 10 ]]; then
  FONT_SIZE=10
fi

# Banner height: FONT_SIZE * 1.2 (integer part) with a minimum of FONT_SIZE+4
BANNER_HEIGHT=$(echo "$FONT_SIZE * 1.2" | bc | cut -d'.' -f1 2>/dev/null || echo "$(( (FONT_SIZE * 12) / 10 ))")
if [[ $BANNER_HEIGHT -lt $(( FONT_SIZE + 4 )) ]]; then
  BANNER_HEIGHT=$(( FONT_SIZE + 4 ))
fi

# Helper function to process one frame (avoids duplication)
process_frame() {
  local fname="$1"
  local idx="$2"
  local ts_display="$3"
  rclone copyto ":s3:${R2_BUCKET}/${fname}" "frames/${fname}" "${RCLONE_BASE[@]}"
  convert "frames/${fname}" -crop "$CROP" +repage "processed/cropped_${idx}.png"
  convert "processed/cropped_${idx}.png" -background "#A0BDFF" -alpha remove -alpha off "processed/cropped_${idx}.png"
  convert -size "${WIDTH}x${BANNER_HEIGHT}" xc:black \
    -gravity Center -pointsize "$FONT_SIZE" -fill white -annotate +0+0 "$ts_display" \
    "processed/banner_${idx}.png"
  convert "processed/banner_${idx}.png" "processed/cropped_${idx}.png" -append +repage "processed/frame_${idx}.png"
}

# Early estimate: process first snapshot and project total size
total_snapshots=${#SNAPSHOTS[@]}
first_fname="${SNAPSHOTS[0]}"
if [[ $first_fname =~ wdpsnapshot_([0-9]{8})_([0-9]{6})\.png$ ]]; then
  datestr="${BASH_REMATCH[1]}"
  timestr="${BASH_REMATCH[2]}"
  first_ts="${datestr:0:4}-${datestr:4:2}-${datestr:6:2} ${timestr:0:2}:${timestr:2:2}:${timestr:4:2}"
else
  first_ts="unknown"
fi

process_frame "$first_fname" "0000" "$first_ts"
first_size=$(stat -c%s "processed/frame_0000.png")
estimated_total=$(( first_size * total_snapshots ))
estimated_mb=$(echo "scale=1; $estimated_total / 1048576" | bc)

if [[ $estimated_total -gt 104857600 ]]; then
  echo "ERROR: Estimated total size of ${total_snapshots} frames is ~${estimated_mb} MB – exceeds 100 MB limit. Aborting."
  exit 1
fi
echo "Estimated total size: ~${estimated_mb} MB – processing remaining frames."

# Process the rest of the snapshots
i=1
for fname in "${SNAPSHOTS[@]:1}"; do
  if [[ $fname =~ wdpsnapshot_([0-9]{8})_([0-9]{6})\.png$ ]]; then
    datestr="${BASH_REMATCH[1]}"
    timestr="${BASH_REMATCH[2]}"
    ts_display="${datestr:0:4}-${datestr:4:2}-${datestr:6:2} ${timestr:0:2}:${timestr:2:2}:${timestr:4:2}"
  else
    ts_display="unknown"
  fi
  echo "  $fname  ->  frame_$(printf "%04d" $i).png"
  process_frame "$fname" "$(printf "%04d" $i)" "$ts_display"
  i=$(( i + 1 ))
done

# -- Compute per-frame delays from time gaps ---------------------------
prev_ts=0
prev_fname=""
diffs=()

for fname in "${SNAPSHOTS[@]}"; do
  if [[ $fname =~ wdpsnapshot_([0-9]{8})_([0-9]{6})\.png$ ]]; then
    datestr="${BASH_REMATCH[1]}"
    timestr="${BASH_REMATCH[2]}"
    ts=$(date -d"${datestr:0:4}-${datestr:4:2}-${datestr:6:2}T${timestr:0:2}:${timestr:2:2}:${timestr:4:2}Z" +%s)
    if [[ -n $prev_fname ]]; then
      diff_sec=$(( ts - prev_ts ))
      diffs+=("$diff_sec")
    fi
    prev_ts=$ts
    prev_fname=$fname
  fi
done

# Handle single snapshot
if [[ ${#diffs[@]} -eq 0 ]]; then
  MIN_DIFF=1
  diffs=(1)
else
  # Find minimum difference
  MIN_DIFF=${diffs[0]}
  for d in "${diffs[@]}"; do
    (( d < MIN_DIFF )) && MIN_DIFF=$d
  done

  # Add a duplicate of the last interval for the final frame (end pause)
  diffs+=("${diffs[-1]}")
fi

# Convert each diff to centiseconds: delay_cs = (diff / MIN_DIFF) * (100 / SPEED)
DELAYS=()
for diff_sec in "${diffs[@]}"; do
  delay_cs=$(echo "scale=2; ($diff_sec / $MIN_DIFF) * (100 / $SPEED)" | bc)
  delay_cs=$(printf "%.0f" "$delay_cs")
  # Minimum GIF delay is 2 centiseconds
  if [[ $delay_cs -lt 2 ]]; then
    delay_cs=2
  fi
  DELAYS+=("$delay_cs")
done

# -- End pause: 2× max delay or 100 cs, whichever is larger ------------
MAX_DELAY=0
for d in "${DELAYS[@]}"; do
  (( d > MAX_DELAY )) && MAX_DELAY=$d
done
END_DELAY=$(( 2 * MAX_DELAY ))
[[ $END_DELAY -lt 100 ]] && END_DELAY=100

# -- Assemble GIF with per-frame delays and a final extended frame -----
echo "Assembling GIF..."

FRAME_COUNT=${#SNAPSHOTS[@]}

# -- Check total size of frames (limit 100 MB) ---------------------------
TOTAL_SIZE=0
for f in processed/frame_*.png; do
  SIZE=$(stat -c%s "$f")
  TOTAL_SIZE=$(( TOTAL_SIZE + SIZE ))
done

if [[ $TOTAL_SIZE -gt 104857600 ]]; then
  MB=$(echo "scale=1; $TOTAL_SIZE / 1048576" | bc)
  echo "ERROR: Total size of ${FRAME_COUNT} frames is ${MB} MB – exceeds 100 MB limit. Aborting."
  exit 1
fi

# Prepare arguments for the final convert command
ARGS=()
for i in $(seq 0 $(( FRAME_COUNT - 1 ))); do
  idx=$(printf "%04d" $i)
  ARGS+=(-delay "${DELAYS[$i]}" "processed/frame_${idx}.png")
done

# Duplicate last frame for the end pause
LAST_IDX=$(printf "%04d" $(( FRAME_COUNT - 1 )))
cp "processed/frame_${LAST_IDX}.png" "processed/last_hold.png"
ARGS+=(-delay "$END_DELAY" "processed/last_hold.png")

# Final GIF (use convert, not magick)
convert "${ARGS[@]}" -loop 0 "$OUTPUT_GIF"
if command -v gifsicle &>/dev/null; then
  gifsicle --batch -O3 "$OUTPUT_GIF"
else
  echo "gifsicle not found – skipping optimisation (file may be larger)"
fi

# -- Resolve filename collision (rename if file already exists) -------
FINAL_NAME="$OUTPUT_GIF"
if [[ -f "$FINAL_NAME" ]]; then
  base="${OUTPUT_GIF%.*}"
  ext="${OUTPUT_GIF##*.}"
  counter=1
  while [[ -f "${base}_${counter}.${ext}" ]]; do
    counter=$(( counter + 1 ))
  done
  FINAL_NAME="${base}_${counter}.${ext}"
  mv "$OUTPUT_GIF" "$FINAL_NAME"
  echo "Renamed GIF to avoid overwriting: $FINAL_NAME"
fi

echo "GIF saved to $FINAL_NAME"
