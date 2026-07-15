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
INTERVAL_MIN=$(jq -r '.interval_minutes // 0' "$CONFIG_FILE")   # NEW
SCALE_FACTOR=$(jq -r '.scale_factor // 1.0' "$CONFIG_FILE")     # NEW

# Validate required fields
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

# Convert start/end to epoch
START_EPOCH=$(date -d"$START" +%s)
END_EPOCH=$(date -d"$END" +%s)

# ----------------------------------------------------------------------
# 1) Collect every snapshot inside the requested time range
# ----------------------------------------------------------------------
declare -a ALL_FNAMES
declare -a ALL_TS
while IFS= read -r fname; do
    if [[ $fname =~ wdpsnapshot_([0-9]{8})_([0-9]{6})\.png$ ]]; then
        datestr="${BASH_REMATCH[1]}"
        timestr="${BASH_REMATCH[2]}"
        ts=$(date -d"${datestr:0:4}-${datestr:4:2}-${datestr:6:2}T${timestr:0:2}:${timestr:2:2}:${timestr:4:2}Z" +%s 2>/dev/null) || continue
        if (( ts >= START_EPOCH && ts <= END_EPOCH )); then
            ALL_FNAMES+=("$fname")
            ALL_TS+=("$ts")
        fi
    fi
done < <(jq -r '.[]' snapshots.json | sort)

if [[ ${#ALL_FNAMES[@]} -eq 0 ]]; then
    echo "No snapshots found in the given time range."
    exit 1
fi

# ----------------------------------------------------------------------
# 2) Thin to one snapshot per interval (closest to each boundary)
# ----------------------------------------------------------------------
if [[ -n "$INTERVAL_MIN" && "$INTERVAL_MIN" -gt 0 ]]; then
    interval_sec=$(( INTERVAL_MIN * 60 ))
    declare -a TARGET_EPOCHS
    for ((t = START_EPOCH; t <= END_EPOCH; t += interval_sec)); do
        TARGET_EPOCHS+=($t)
    done

    declare -a SELECTED_FNAMES
    for target in "${TARGET_EPOCHS[@]}"; do
        best_idx=-1
        best_dist=999999999
        for i in "${!ALL_TS[@]}"; do
            diff=$(( target - ALL_TS[i] ))
            (( diff < 0 )) && diff=$(( -diff ))   # absolute value
            if (( diff < best_dist )); then
                best_dist=$diff
                best_idx=$i
            fi
        done
        if (( best_idx >= 0 )); then
            selected_fname="${ALL_FNAMES[$best_idx]}"
            # Prevent the same snapshot from being used twice
            if [[ ! " ${SELECTED_FNAMES[@]} " =~ " ${selected_fname} " ]]; then
                SELECTED_FNAMES+=("$selected_fname")
            fi
        fi
    done
    SNAPSHOTS=("${SELECTED_FNAMES[@]}")
else
    SNAPSHOTS=("${ALL_FNAMES[@]}")
fi

if [[ ${#SNAPSHOTS[@]} -eq 0 ]]; then
    echo "No snapshots after thinning – check time range and interval."
    exit 1
fi

# -- Download, crop, add timestamp banner, and optionally scale --------
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

# Helper function to process one frame
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

# -- Early estimate using the first snapshot (with scaling) ------------
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
# Apply scaling to the first frame if needed
if [[ "$SCALE_FACTOR" != "1.0" ]]; then
  convert "processed/frame_0000.png" \
          -resize "$(awk "BEGIN {printf \"%.0f\", $WIDTH * $SCALE_FACTOR}")"x"$(awk "BEGIN {printf \"%.0f\", $HEIGHT * $SCALE_FACTOR}")"! \
          "processed/frame_0000.png"
fi

first_size=$(stat -c%s "processed/frame_0000.png")
estimated_total=$(( first_size * total_snapshots ))
estimated_mb=$(echo "scale=1; $estimated_total / 1048576" | bc)

if [[ $estimated_total -gt 104857600 ]]; then
  echo "ERROR: Estimated total size of ${total_snapshots} frames is ~${estimated_mb} MB – exceeds 100 MB limit. Aborting."
  exit 1
fi
echo "Estimated total size: ~${estimated_mb} MB – processing remaining frames."

# -- Process the rest of the snapshots ---------------------------------
i=1
for fname in "${SNAPSHOTS[@]:1}"; do
  if [[ $fname =~ wdpsnapshot_([0-9]{8})_([0-9]{6})\.png$ ]]; then
    datestr="${BASH_REMATCH[1]}"
    timestr="${BASH_REMATCH[2]}"
    ts_display="${datestr:0:4}-${datestr:4:2}-${datestr:6:2} ${timestr:0:2}:${timestr:2:2}:${timestr:4:2}"
  else
    ts_display="unknown"
  fi
  idx_pad=$(printf "%04d" $i)
  echo "  $fname  ->  frame_${idx_pad}.png"
  process_frame "$fname" "$idx_pad" "$ts_display"
  # Apply scaling if requested
  if [[ "$SCALE_FACTOR" != "1.0" ]]; then
    convert "processed/frame_${idx_pad}.png" \
            -resize "$(awk "BEGIN {printf \"%.0f\", $WIDTH * $SCALE_FACTOR}")"x"$(awk "BEGIN {printf \"%.0f\", $HEIGHT * $SCALE_FACTOR}")"! \
            "processed/frame_${idx_pad}.png"
  fi
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

# Total size check (already roughly checked, but final validation)
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

# Final GIF
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
