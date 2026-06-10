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

# Validate essentials
if [[ -z "$START" || -z "$END" || -z "$SPEED" ]]; then
  echo "Missing required fields in $CONFIG_FILE"
  exit 1
fi

# Crop geometry
WIDTH=$(( X2 - X1 ))
HEIGHT=$(( Y2 - Y1 ))
CROP="${WIDTH}x${HEIGHT}+${X1}+${Y1}"

# R2 environment
: "${R2_BUCKET:?R2_BUCKET not set}"
: "${R2_ENDPOINT:?R2_ENDPOINT not set}"
: "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID not set}"
: "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY not set}"

# rclone base flags
RCLONE_BASE=(--s3-provider="Cloudflare" --s3-endpoint="$R2_ENDPOINT"
             --s3-access-key-id="$R2_ACCESS_KEY_ID"
             --s3-secret-access-key="$R2_SECRET_ACCESS_KEY"
             --s3-no-check-bucket)

# -- Fetch snapshot list ------------------------------------------------
echo "Downloading snapshots.json..."
rclone cat ":s3:${R2_BUCKET}/snapshots.json" "${RCLONE_BASE[@]}" > snapshots.json

# Filter and sort filenames within the time range
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

# -- Download and crop each snapshot ------------------------------------
mkdir -p frames
echo "Downloading and cropping ${#SNAPSHOTS[@]} snapshots..."
for fname in "${SNAPSHOTS[@]}"; do
  echo "  $fname"
  rclone copyto ":s3:${R2_BUCKET}/${fname}" "frames/${fname}" "${RCLONE_BASE[@]}"
  magick "frames/${fname}" -crop "$CROP" +repage "frames/crop_${fname}"
done

# -- Compute per-frame delays -------------------------------------------
declare -a DELAYS
prev_ts=0
prev_fname=""
diffs=()

# Build array of time differences
for fname in "${SNAPSHOTS[@]}"; do
  # Extract timestamp again (could cache, but simple re‑extraction is fine)
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

# If only one snapshot, set a minimal diff to avoid division by zero
if [[ ${#diffs[@]} -eq 0 ]]; then
  MIN_DIFF=$(( 1 ))
else
  # Find minimum difference
  MIN_DIFF=${diffs[0]}
  for d in "${diffs[@]}"; do
    (( d < MIN_DIFF )) && MIN_DIFF=$d
  done
fi

# Fallback for last frame: duplicate the previous diff, or use MIN_DIFF
if [[ ${#diffs[@]} -gt 0 ]]; then
  diffs+=("${diffs[-1]}")   # repeat the last interval for the final frame
else
  diffs=("$MIN_DIFF")       # single frame case
fi

# Convert each diff to centiseconds using the speed factor
for diff_sec in "${diffs[@]}"; do
  # delay_seconds = (diff_sec / MIN_DIFF) * (1 / SPEED)
  # Use bc for floating point, then convert to centiseconds (1 s = 100 cs)
  delay_cs=$(echo "scale=2; ($diff_sec / $MIN_DIFF) * (100 / $SPEED)" | bc)
  # Round to nearest integer
  delay_cs=$(printf "%.0f" "$delay_cs")
  # ImageMagick requires a minimum delay of 2 (0.02 s) for GIFs
  if (( delay_cs < 2 )); then
    delay_cs=2
  fi
  DELAYS+=("$delay_cs")
done

# -- Assemble GIF -------------------------------------------------------
echo "Assembling GIF..."
MAGICK_CMD=(magick)

# Add each frame with its specific delay
for i in "${!SNAPSHOTS[@]}"; do
  fname="${SNAPSHOTS[$i]}"
  MAGICK_CMD+=(-delay "${DELAYS[$i]}" "frames/crop_${fname}")
done

# Final options: loop forever (-loop 0), optimize for size
MAGICK_CMD+=(-loop 0 -layers Optimize "$OUTPUT_GIF")

"${MAGICK_CMD[@]}"

# -- Upload result to R2 ------------------------------------------------
echo "Uploading $OUTPUT_GIF to R2..."
rclone copyto "$OUTPUT_GIF" ":s3:${R2_BUCKET}/${OUTPUT_GIF}" "${RCLONE_BASE[@]}" --verbose
echo "Done."
