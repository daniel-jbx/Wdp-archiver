#!/bin/bash
# ----------------------------------------------------------------------
# Generate a proportional‑timing GIF from wplace.live snapshots
# Uses the public snapshots.json manifest (no R2 credentials required)
# Configuration: gif-config.txt
# ----------------------------------------------------------------------

set -euo pipefail

# --- 1. Parse configuration -------------------------------------------------
CONFIG_FILE="gif-config.txt"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: $CONFIG_FILE not found."
    exit 1
fi

date_from=$(grep -E '^date_from=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')
date_to=$(grep -E '^date_to=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')
x_start=$(grep -E '^x_start=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')
x_end=$(grep -E '^x_end=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')
y_start=$(grep -E '^y_start=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')
y_end=$(grep -E '^y_end=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')
max_fps=$(grep -E '^max_fps=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')
output=$(grep -E '^output=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')
bucket_url=$(grep -E '^bucket_url=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')

if [ -z "$bucket_url" ]; then
    bucket_url="https://pub-e0766eb5f5114fc097a10215d5e6081b.r2.dev"
fi

if [ -z "$date_from" ] || [ -z "$date_to" ] || [ -z "$max_fps" ]; then
    echo "ERROR: date_from, date_to, and max_fps must be set in $CONFIG_FILE"
    exit 1
fi

echo "=== GIF generation (using snapshots.json) ==="
echo "Date range: $date_from  to  $date_to"
echo "Crop: x=$x_start..$x_end  y=$y_start..$y_end"
echo "Max FPS (shortest interval): $max_fps"
echo "Output: $output"
echo "Bucket URL: $bucket_url"

# --- 2. Install dependencies ------------------------------------------------
sudo apt-get update -qq
sudo apt-get install -y -qq jq ffmpeg bc curl imagemagick

# --- 3. Date conversion ----------------------------------------------------
if command -v gdate &>/dev/null; then
    DATE_CMD="gdate"
else
    DATE_CMD="date"
fi

from_epoch=$($DATE_CMD -d "$date_from" +%s 2>/dev/null)
to_epoch=$($DATE_CMD -d "$date_to" +%s 2>/dev/null)
if [ -z "$from_epoch" ] || [ -z "$to_epoch" ]; then
    echo "ERROR: Invalid date format. Use 'YYYY-MM-DD HH:MM:SS'."
    exit 1
fi

# --- 4. Fetch snapshots.json (public) --------------------------------------
MANIFEST_URL="$bucket_url/snapshots.json"
echo "Fetching manifest from $MANIFEST_URL"
curl -s -o snapshots.json "$MANIFEST_URL"
if [ ! -s snapshots.json ]; then
    echo "ERROR: snapshots.json empty or not found."
    exit 1
fi

if ! jq -e 'type == "array"' snapshots.json >/dev/null; then
    echo "ERROR: snapshots.json is not a JSON array."
    exit 1
fi

count=$(jq length snapshots.json)
echo "Manifest contains $count snapshots."

if [ "$count" -eq 0 ]; then
    echo "ERROR: No snapshots available. Run the update-map.yml workflow first."
    exit 1
fi

# --- 5. Filter snapshots by date range -------------------------------------
filtered=()   # array of "filename:epoch"
while IFS= read -r file; do
    ts=$(echo "$file" | sed -n 's/.*wdpsnapshot_\([0-9]\{8\}_[0-9]\{6\}\)\.png/\1/p')
    if [ -z "$ts" ]; then
        echo "WARNING: Skipping unexpected filename: $file"
        continue
    fi
    epoch=$($DATE_CMD -d "${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:9:2}:${ts:11:2}:${ts:13:2}" +%s 2>/dev/null || true)
    if [ -n "$epoch" ] && [ "$epoch" -ge "$from_epoch" ] && [ "$epoch" -le "$to_epoch" ]; then
        filtered+=("$file:$epoch")
    fi
done < <(jq -r '.[]' snapshots.json)

echo "Found ${#filtered[@]} snapshots in date range."
if [ ${#filtered[@]} -lt 2 ]; then
    echo "ERROR: Need at least 2 snapshots, only ${#filtered[@]} found."
    exit 1
fi

# Sort by epoch (oldest first)
IFS=$'\n' filtered=($(sort -t: -k2 -n <<<"${filtered[*]}"))
unset IFS

# --- 6. Size check – exit if too many frames -------------------------------
MAX_FRAMES=500   # adjust as needed
if [ ${#filtered[@]} -gt $MAX_FRAMES ]; then
    echo "ERROR: Too many frames (${#filtered[@]} > $MAX_FRAMES)."
    echo "Narrow your date range or increase MAX_FRAMES in the script."
    exit 1
fi

# --- 7. Compute proportional durations (in seconds) ------------------------
min_interval=999999999
prev_epoch=0
for entry in "${filtered[@]}"; do
    epoch="${entry#*:}"
    if [ $prev_epoch -eq 0 ]; then
        prev_epoch=$epoch
        continue
    fi
    interval=$((epoch - prev_epoch))
    if [ $interval -lt $min_interval ]; then
        min_interval=$interval
    fi
    prev_epoch=$epoch
done

if [ $min_interval -eq 0 ]; then
    echo "ERROR: Minimum interval is zero (duplicate timestamps)."
    exit 1
fi

base_duration_sec=$(echo "scale=6; 1 / $max_fps" | bc)
echo "Shortest interval = ${min_interval}s → base duration = ${base_duration_sec}s"

# Convert each frame duration to hundredths of a second (for ImageMagick)
declare -a delays_hundredths
prev_epoch=0
for entry in "${filtered[@]}"; do
    epoch="${entry#*:}"
    if [ $prev_epoch -eq 0 ]; then
        prev_epoch=$epoch
        continue
    fi
    interval=$((epoch - prev_epoch))
    duration_sec=$(echo "scale=6; ($interval / $min_interval) * $base_duration_sec" | bc)
    delay=$(printf "%.0f" "$(echo "$duration_sec * 100" | bc)")
    [ $delay -lt 1 ] && delay=1
    delays_hundredths+=($delay)
    prev_epoch=$epoch
done
end_pause=100   # 1 second at the end

# --- 8. Download, crop, add timestamp banner, and assemble frames ---------
TMP_DIR="frames_$$"
mkdir -p "$TMP_DIR"

crop_width=$((x_end - x_start))
crop_height=$((y_end - y_start))
if [ $crop_width -le 0 ] || [ $crop_height -le 0 ]; then
    echo "ERROR: Invalid crop dimensions (width=$crop_width, height=$crop_height)."
    exit 1
fi

# Dynamic font size: 6% of crop height (minimum 12px)
font_size=$(echo "$crop_height * 0.06" | bc | cut -d'.' -f1)
[ $font_size -lt 12 ] && font_size=12
banner_height=$((font_size * 3 / 2))

echo "Crop size = ${crop_width}x${crop_height}, font size = ${font_size}px, banner height = ${banner_height}px"

frame_index=0
for entry in "${filtered[@]}"; do
    file="${entry%:*}"
    # Extract human‑readable timestamp
    ts=$(echo "$file" | sed -n 's/.*wdpsnapshot_\([0-9]\{8\}_[0-9]\{6\}\)\.png/\1/p')
    readable_ts="${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:9:2}:${ts:11:2}:${ts:13:2}"
    
    echo "Processing frame $frame_index: $file ($readable_ts)"
    
    # Download from public bucket
    public_url="$bucket_url/$file"
    curl -f -s -o "$TMP_DIR/$file" "$public_url" || { echo "Failed to download $file"; exit 1; }
    
    # Crop
    cropped="$TMP_DIR/cropped_${frame_index}.png"
    convert "$TMP_DIR/$file" -crop "${crop_width}x${crop_height}+${x_start}+${y_start}" +repage "$cropped"
    
    # Create banner
    banner="$TMP_DIR/banner_${frame_index}.png"
    convert -size "${crop_width}x${banner_height}" xc:black \
        -gravity Center \
        -pointsize "$font_size" \
        -fill white \
        -annotate +0+0 "$readable_ts" \
        "$banner"
    
    # Stack banner on top
    final_frame="$TMP_DIR/frame_$(printf "%04d" $frame_index).png"
    convert "$banner" "$cropped" -append +repage "$final_frame"
    
    rm -f "$TMP_DIR/$file" "$cropped" "$banner"
    frame_index=$((frame_index + 1))
done

# --- 9. Assemble GIF with proportional delays ------------------------------
echo "Assembling GIF with ${#filtered[@]} frames..."

convert_cmd="convert -delay ${delays_hundredths[0]}"
for i in $(seq 1 $((${#delays_hundredths[@]} - 1))); do
    convert_cmd+=" -delay ${delays_hundredths[$i]}"
done
convert_cmd+=" \"$TMP_DIR\"/frame_*.png -delay $end_pause \"$TMP_DIR/frame_$(printf "%04d" $((frame_index-1))).png\" -loop 0 \"$output\""

eval "$convert_cmd"

echo "GIF created: $output ($(du -h "$output" | cut -f1))"

# Cleanup
rm -rf "$TMP_DIR" snapshots.json

# --- 10. Commit GIF to repository (if in GitHub Actions) -------------------
if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "Committing $output to repository root..."
    git config user.name "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
    git add "$output"
    git commit -m "Generate timelapse GIF: $date_from to $date_to" || echo "No changes to commit."
    git push
else
    echo "Not in GitHub Actions – skipping git commit."
fi
