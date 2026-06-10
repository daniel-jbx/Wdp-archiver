#!/bin/bash
# ----------------------------------------------------------------------
# Generate a proportional‑timing GIF from wplace.live snapshots
# - Direct bucket listing (no snapshots.json)
# - Timestamp banner on every frame (dynamic font size)
# - Exits if frame count > 500 (adjustable)
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

# R2 credentials from environment (GitHub secrets)
R2_ACCESS_KEY_ID=${R2_ACCESS_KEY_ID:-}
R2_SECRET_ACCESS_KEY=${R2_SECRET_ACCESS_KEY:-}
R2_ENDPOINT=${R2_ENDPOINT:-}
BUCKET_NAME="wdp-archiver"

if [ -z "$R2_ACCESS_KEY_ID" ] || [ -z "$R2_SECRET_ACCESS_KEY" ] || [ -z "$R2_ENDPOINT" ]; then
    echo "ERROR: R2 credentials not set (R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ENDPOINT)."
    exit 1
fi

if [ -z "$date_from" ] || [ -z "$date_to" ] || [ -z "$max_fps" ]; then
    echo "ERROR: date_from, date_to, and max_fps must be set in $CONFIG_FILE"
    exit 1
fi

echo "=== GIF generation (direct bucket listing) ==="
echo "Date range: $date_from  to  $date_to"
echo "Crop: x=$x_start..$x_end  y=$y_start..$y_end"
echo "Max FPS: $max_fps"
echo "Output: $output"

# --- 2. Install dependencies ------------------------------------------------
sudo apt-get update -qq
sudo apt-get install -y -qq jq ffmpeg bc curl imagemagick

if ! command -v rclone &>/dev/null; then
    echo "Installing rclone..."
    curl -s https://rclone.org/install.sh | sudo bash
fi

# --- 3. Configure rclone ----------------------------------------------------
rclone config create r2 s3 \
    provider=Cloudflare \
    access_key_id="$R2_ACCESS_KEY_ID" \
    secret_access_key="$R2_SECRET_ACCESS_KEY" \
    endpoint="$R2_ENDPOINT" \
    acl=public-read 2>/dev/null || true

# --- 4. List snapshot files -------------------------------------------------
echo "Listing snapshots from r2:$BUCKET_NAME ..."
rclone lsjson "r2:$BUCKET_NAME" --include "wdpsnapshot_*.png" > raw_snapshots.json

if [ ! -s raw_snapshots.json ]; then
    echo "ERROR: No snapshot files found in bucket."
    exit 1
fi

jq -r '.[].Name' raw_snapshots.json > snapshot_files.txt
count=$(wc -l < snapshot_files.txt)
echo "Found $count snapshot files."

# --- 5. Date conversion ----------------------------------------------------
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

# --- 6. Filter by date range (from filename timestamps) --------------------
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
done < snapshot_files.txt

echo "Found ${#filtered[@]} snapshots in date range."
if [ ${#filtered[@]} -lt 2 ]; then
    echo "ERROR: Need at least 2 snapshots, only ${#filtered[@]} found."
    exit 1
fi

# Sort by epoch (oldest first)
IFS=$'\n' filtered=($(sort -t: -k2 -n <<<"${filtered[*]}"))
unset IFS

# --- 7. Size check – exit if too many frames (prevents huge GIF) ----------
MAX_FRAMES=500   # adjust as needed (500 frames ~ 50-100 MB depending on resolution)
if [ ${#filtered[@]} -gt $MAX_FRAMES ]; then
    echo "ERROR: Too many frames (${#filtered[@]} > $MAX_FRAMES)."
    echo "Narrow your date range or increase MAX_FRAMES in the script."
    exit 1
fi

# --- 8. Compute proportional durations (in seconds) ------------------------
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
    # Convert to hundredths, round to nearest integer, minimum 1
    delay=$(printf "%.0f" "$(echo "$duration_sec * 100" | bc)")
    [ $delay -lt 1 ] && delay=1
    delays_hundredths+=($delay)
    prev_epoch=$epoch
done
# The last frame's duration will be applied via the end pause (we reuse its delay)
# We'll set a fixed end pause of 1 second (100 hundredths)
end_pause=100

# --- 9. Download, crop, add timestamp banner, and assemble frames ---------
TMP_DIR="frames_$$"
mkdir -p "$TMP_DIR"

# Determine dynamic font size: 6% of crop height (minimum 12px)
crop_height=$((y_end - y_start))
font_size=$(echo "$crop_height * 0.06" | bc | cut -d'.' -f1)
[ $font_size -lt 12 ] && font_size=12

# Banner height = font_size * 1.5 (gives comfortable padding)
banner_height=$((font_size * 3 / 2))

echo "Crop height = ${crop_height}px, font size = ${font_size}px, banner height = ${banner_height}px"

frame_index=0
for entry in "${filtered[@]}"; do
    file="${entry%:*}"
    epoch="${entry#*:}"
    # Extract human‑readable timestamp from filename
    ts=$(echo "$file" | sed -n 's/.*wdpsnapshot_\([0-9]\{8\}_[0-9]\{6\}\)\.png/\1/p')
    # Format as "YYYY-MM-DD HH:MM:SS"
    readable_ts="${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:9:2}:${ts:11:2}:${ts:13:2}"
    
    echo "Processing frame $frame_index: $file ($readable_ts)"
    
    # Download the snapshot (public URL)
    public_url="${R2_ENDPOINT}/${BUCKET_NAME}/${file}"
    curl -f -s -o "$TMP_DIR/$file" "$public_url" || { echo "Failed to download $file"; exit 1; }
    
    # Crop the region
    cropped="$TMP_DIR/cropped_${frame_index}.png"
    convert "$TMP_DIR/$file" -crop "${crop_width}x${crop_height}+${x_start}+${y_start}" +repage "$cropped"
    
    # Create banner image (black background with white text, centered)
    banner="$TMP_DIR/banner_${frame_index}.png"
    convert -size "${crop_width}x${banner_height}" xc:black \
        -gravity Center \
        -pointsize "$font_size" \
        -fill white \
        -annotate +0+0 "$readable_ts" \
        "$banner"
    
    # Stack banner on top of cropped image
    final_frame="$TMP_DIR/frame_$(printf "%04d" $frame_index).png"
    convert "$banner" "$cropped" -append +repage "$final_frame"
    
    # Cleanup intermediate files for this frame
    rm -f "$TMP_DIR/$file" "$cropped" "$banner"
    
    frame_index=$((frame_index + 1))
done

# --- 10. Assemble GIF with proportional delays -----------------------------
echo "Assembling GIF with ${#filtered[@]} frames..."

# Build convert command with delays
convert_cmd="convert -delay ${delays_hundredths[0]}"
for i in $(seq 1 $((${#delays_hundredths[@]} - 1))); do
    convert_cmd+=" -delay ${delays_hundredths[$i]}"
done
convert_cmd+=" \"$TMP_DIR\"/frame_*.png -delay $end_pause \"$TMP_DIR/frame_$(printf "%04d" $((frame_index-1))).png\" -loop 0 \"$output\""

eval "$convert_cmd"

echo "GIF created: $output ($(du -h "$output" | cut -f1))"

# Cleanup
rm -rf "$TMP_DIR" raw_snapshots.json snapshot_files.txt

# --- 11. Commit GIF to repository (if in GitHub Actions) -------------------
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
