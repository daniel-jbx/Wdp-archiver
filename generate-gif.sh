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
INTERVAL_MIN=$(jq -r '.interval_minutes // 0' "$CONFIG_FILE")
SCALE_FACTOR=$(jq -r '.scale_factor // 1.0' "$CONFIG_FILE")
OUTPUT_FORMAT=$(jq -r '.output_format // "gif"' "$CONFIG_FILE")
VIDEO_FPS=$(jq -r '.video_fps // 0' "$CONFIG_FILE")   # 0 means "auto‑derive from SPEED"

# Validate required fields
if [[ -z "$START" || -z "$END" || -z "$SPEED" || -z "$OUTPUT_GIF" ]]; then
  echo "Missing required fields in $CONFIG_FILE"
  exit 1
fi

# Crop dimensions (inclusive start, exclusive end)
WIDTH=$(( X2 - X1 ))
HEIGHT=$(( Y2 - Y1 ))
CROP="${WIDTH}x${HEIGHT}+${X1}+${Y1}"

# Max allowed total size (1 GiB – still checked on PNGs before final output)
MAX_TOTAL_SIZE=1073741824

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

BANNER_HEIGHT=$(echo "$FONT_SIZE * 1.2" | bc | cut -d'.' -f1 2>/dev/null || echo "$(( (FONT_SIZE * 12) / 10 ))")
if [[ $BANNER_HEIGHT -lt $(( FONT_SIZE + 4 )) ]]; then
  BANNER_HEIGHT=$(( FONT_SIZE + 4 ))
fi

process_frame() {
  local fname="$1"
  local idx="$2"
  local ts_display="$3"
  rclone copyto ":s3:${R2_BUCKET}/${fname}" "frames/${fname}" "${RCLONE_BASE[@]}" --timeout 30s
  convert "frames/${fname}" -crop "$CROP" +repage "processed/cropped_${idx}.png"
  convert "processed/cropped_${idx}.png" -background "#A0BDFF" -alpha remove -alpha off "processed/cropped_${idx}.png"
  convert -size "${WIDTH}x${BANNER_HEIGHT}" xc:black \
    -gravity Center -pointsize "$FONT_SIZE" -fill white -annotate +0+0 "$ts_display" \
    "processed/banner_${idx}.png"
  convert "processed/banner_${idx}.png" "processed/cropped_${idx}.png" -append +repage "processed/frame_${idx}.png"
}

# -- Early estimate (only for GIF, not needed for video) ---------------
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

if [[ "$SCALE_FACTOR" != "1.0" ]]; then
  convert "processed/frame_0000.png" \
          -resize "$(awk "BEGIN {printf \"%.0f\", $WIDTH * $SCALE_FACTOR}")"x"$(awk "BEGIN {printf \"%.0f\", $HEIGHT * $SCALE_FACTOR}")"! \
          "processed/frame_0000.png"
fi

# For GIF, do the test conversion to estimate size; for MP4 we skip
if [[ "$OUTPUT_FORMAT" == "gif" ]]; then
  convert "processed/frame_0000.png" "processed/_est_test.gif"
  first_gif_size=$(stat -c%s "processed/_est_test.gif")
  rm -f "processed/_est_test.gif"
  estimated_total=$(( first_gif_size * total_snapshots ))
  estimated_mb=$(echo "scale=1; $estimated_total / 1048576" | bc)
  if [[ $estimated_total -gt $MAX_TOTAL_SIZE ]]; then
    echo "ERROR: Estimated final GIF size is ~${estimated_mb} MB – exceeds 1 GB limit. Aborting."
    exit 1
  fi
  echo "Estimated final GIF size: ~${estimated_mb} MB – processing remaining frames."
else
  echo "Output format: MP4 – no size estimate needed (video will be highly compressed)."
fi

# -- Process remaining frames ------------------------------------------
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
  if [[ "$SCALE_FACTOR" != "1.0" ]]; then
    convert "processed/frame_${idx_pad}.png" \
            -resize "$(awk "BEGIN {printf \"%.0f\", $WIDTH * $SCALE_FACTOR}")"x"$(awk "BEGIN {printf \"%.0f\", $HEIGHT * $SCALE_FACTOR}")"! \
            "processed/frame_${idx_pad}.png"
  fi
  i=$(( i + 1 ))
done

# ----------------------------------------------------------------------
# Output generation – GIF or MP4
# ----------------------------------------------------------------------
if [[ "$OUTPUT_FORMAT" == "mp4" ]]; then
  # Determine FPS
  if [[ "$VIDEO_FPS" =~ ^[0-9]+$ && "$VIDEO_FPS" -gt 0 ]]; then
    FPS=$VIDEO_FPS
  else
    # Auto: use SPEED (capped at 60) – mirrors the original GIF timing
    FPS=$SPEED
    if [[ $FPS -gt 60 ]]; then
      FPS=60
    fi
  fi
  echo "Creating MP4 at ${FPS} fps..."

  # Build ffmpeg command from numbered frames
  # frame_0000.png … frame_NNNN.png
  # Use a concat file list (safest for non-contiguous numbering, but we have contiguous)
  # Simpler: pattern glob (requires -start_number 0 if we use printf %04d)
  ffmpeg -y -framerate "$FPS" -i processed/frame_%04d.png \
         -vf "format=yuv420p" \
         -c:v libx264 -preset medium -crf 23 \
         -pix_fmt yuv420p -movflags +faststart \
         "$OUTPUT_GIF"

  echo "MP4 created: $OUTPUT_GIF"
else
  # Original GIF path
  echo "Assembling GIF..."

  # Compute per-frame delays (unchanged)
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

  if [[ ${#diffs[@]} -eq 0 ]]; then
    MIN_DIFF=1
    diffs=(1)
  else
    MIN_DIFF=${diffs[0]}
    for d in "${diffs[@]}"; do
      (( d < MIN_DIFF )) && MIN_DIFF=$d
    done
    diffs+=("${diffs[-1]}")
  fi

  DELAYS=()
  for diff_sec in "${diffs[@]}"; do
    delay_cs=$(echo "scale=2; ($diff_sec / $MIN_DIFF) * (100 / $SPEED)" | bc)
    delay_cs=$(printf "%.0f" "$delay_cs")
    [[ $delay_cs -lt 2 ]] && delay_cs=2
    DELAYS+=("$delay_cs")
  done

  MAX_DELAY=0
  for d in "${DELAYS[@]}"; do
    (( d > MAX_DELAY )) && MAX_DELAY=$d
  done
  END_DELAY=$(( 2 * MAX_DELAY ))
  [[ $END_DELAY -lt 100 ]] && END_DELAY=100

  FRAME_COUNT=${#SNAPSHOTS[@]}
  TOTAL_PNG_SIZE=0
  for f in processed/frame_*.png; do
    SIZE=$(stat -c%s "$f")
    TOTAL_PNG_SIZE=$(( TOTAL_PNG_SIZE + SIZE ))
  done
  if [[ $TOTAL_PNG_SIZE -gt $MAX_TOTAL_SIZE ]]; then
    echo "WARNING: Total PNG frame size is large ($(echo "scale=1; $TOTAL_PNG_SIZE/1048576" | bc) MB), but final GIF may be smaller. Proceeding..."
  fi

  ARGS=()
  for i in $(seq 0 $(( FRAME_COUNT - 1 ))); do
    idx=$(printf "%04d" $i)
    ARGS+=(-delay "${DELAYS[$i]}" "processed/frame_${idx}.png")
  done

  LAST_IDX=$(printf "%04d" $(( FRAME_COUNT - 1 )))
  cp "processed/frame_${LAST_IDX}.png" "processed/last_hold.png"
  ARGS+=(-delay "$END_DELAY" "processed/last_hold.png")

  convert "${ARGS[@]}" -loop 0 "$OUTPUT_GIF"
  if command -v gifsicle &>/dev/null; then
    gifsicle --batch -O3 "$OUTPUT_GIF"
  fi
  echo "GIF created: $OUTPUT_GIF"
fi

# -- Rename to avoid overwriting (common for both formats) ------------
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
  echo "Renamed to avoid overwriting: $FINAL_NAME"
fi

echo "Done. Output: $FINAL_NAME"
