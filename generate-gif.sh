#!/bin/bash

# No 'set -e' – we check each command manually.
# Print commands and their output for debugging.
set -x
exec 2>&1

echo "=== Starting GIF generation ==="

# --- Configuration file ---
CONFIG_FILE="gif-config.txt"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: $CONFIG_FILE not found."
    exit 1
fi

# Read parameters
date_from=$(grep -E '^date_from=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')
date_to=$(grep -E '^date_to=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')
x_start=$(grep -E '^x_start=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')
x_end=$(grep -E '^x_end=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')
y_start=$(grep -E '^y_start=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')
y_end=$(grep -E '^y_end=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')
max_fps=$(grep -E '^max_fps=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')
output=$(grep -E '^output=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')
bucket_url=$(grep -E '^bucket_url=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')

# Default bucket URL
if [ -z "$bucket_url" ]; then
    bucket_url="https://pub-e0766eb5f5114fc097a10215d5e6081b.r2.dev"
fi

echo "date_from=$date_from"
echo "date_to=$date_to"
echo "max_fps=$max_fps"
echo "output=$output"
echo "bucket_url=$bucket_url"
echo "crop: x=$x_start..$x_end, y=$y_start..$y_end"

# Validate mandatory fields
if [ -z "$date_from" ] || [ -z "$date_to" ] || [ -z "$max_fps" ]; then
    echo "ERROR: date_from, date_to, and max_fps must be set in $CONFIG_FILE"
    exit 1
fi

# --- Install dependencies (quietly) ---
echo "Installing required packages..."
sudo apt-get update -qq
sudo apt-get install -y -qq jq ffmpeg bc curl

# --- Date conversion (support both GNU and BSD date) ---
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
echo "from_epoch=$from_epoch, to_epoch=$to_epoch"

# --- Fetch snapshots.json ---
MANIFEST_URL="$bucket_url/snapshots.json"
echo "Fetching manifest from $MANIFEST_URL"
curl -s -o snapshots.json -w "HTTP %{http_code}\n" "$MANIFEST_URL"
if [ ! -s snapshots.json ]; then
    echo "ERROR: snapshots.json is empty or could not be downloaded."
    exit 1
fi

echo "Manifest content (first 500 chars):"
head -c 500 snapshots.json
echo ""

# Validate JSON
if ! jq empty snapshots.json 2>/dev/null; then
    echo "ERROR: snapshots.json is not valid JSON."
    cat snapshots.json
    exit 1
fi

# Ensure it's an array
if ! jq -e 'type == "array"' snapshots.json >/dev/null; then
    echo "ERROR: snapshots.json is not a JSON array. Found:"
    jq type snapshots.json
    exit 1
fi

# Count entries
count=$(jq length snapshots.json)
echo "Manifest contains $count entries."

if [ "$count" -eq 0 ]; then
    echo "ERROR: snapshots.json is empty (zero snapshots)."
    echo "You need to run the update-map.yml workflow first to populate snapshots."
    exit 1
fi

# --- Filter snapshots by date range ---
filtered_snapshots=()
while IFS= read -r file; do
    # Extract timestamp from filename: wdpsnapshot_YYYYMMDD_HHMMSS.png
    timestamp_str=$(echo "$file" | sed -n 's/.*wdpsnapshot_\([0-9]\{8\}_[0-9]\{6\}\)\.png/\1/p')
    if [ -z "$timestamp_str" ]; then
        echo "WARNING: Skipping file with unexpected name: $file"
        continue
    fi
    # Convert YYYYMMDD_HHMMSS to epoch
    epoch=$($DATE_CMD -d "${timestamp_str:0:4}-${timestamp_str:4:2}-${timestamp_str:6:2} ${timestamp_str:9:2}:${timestamp_str:11:2}:${timestamp_str:13:2}" +%s 2>/dev/null || true)
    if [ -n "$epoch" ] && [ "$epoch" -ge "$from_epoch" ] && [ "$epoch" -le "$to_epoch" ]; then
        filtered_snapshots+=("$file:$epoch")
    fi
done < <(jq -r '.[]' snapshots.json)

echo "Found ${#filtered_snapshots[@]} snapshots in date range."

if [ ${#filtered_snapshots[@]} -lt 2 ]; then
    echo "ERROR: Need at least 2 snapshots, but only ${#filtered_snapshots[@]} found."
    exit 1
fi

# Sort by timestamp
IFS=$'\n' filtered_snapshots=($(sort -t: -k2 -n <<<"${filtered_snapshots[*]}"))
unset IFS

# --- Compute intervals and durations ---
min_interval=999999999
prev_epoch=0
for entry in "${filtered_snapshots[@]}"; do
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

base_duration=$(echo "scale=6; 1 / $max_fps" | bc)
echo "min_interval=$min_interval seconds, base_duration=$base_duration seconds"

# --- Download images and create concat script ---
concat_script="ffconcat version 1.0\n"
prev_epoch=0
for entry in "${filtered_snapshots[@]}"; do
    file="${entry%:*}"
    epoch="${entry#*:}"
    if [ $prev_epoch -eq 0 ]; then
        echo "Downloading $file ..."
        curl -f -s -o "$file" "$bucket_url/$file" || { echo "Failed to download $file"; exit 1; }
        prev_epoch=$epoch
        continue
    fi
    interval=$((epoch - prev_epoch))
    duration=$(echo "scale=6; ($interval / $min_interval) * $base_duration" | bc)
    concat_script+="file '$file'\n"
    concat_script+="duration $duration\n"
    echo "Downloading $file ..."
    curl -f -s -o "$file" "$bucket_url/$file" || { echo "Failed to download $file"; exit 1; }
    prev_epoch=$epoch
done
# Add last frame again (ffmpeg needs a file without duration to repeat last frame's duration)
last_file="${filtered_snapshots[-1]%:*}"
concat_script+="file '$last_file'\n"

echo -e "$concat_script" > concat.txt
echo "Concat script created (first 20 lines):"
head -20 concat.txt

# --- Generate GIF with cropping ---
ffmpeg_cmd="ffmpeg -f concat -safe 0 -i concat.txt -vf \"fps=$max_fps"
if [ -n "$x_start" ] && [ -n "$x_end" ] && [ -n "$y_start" ] && [ -n "$y_end" ]; then
    width=$((x_end - x_start))
    height=$((y_end - y_start))
    # Validate crop dimensions (max 7000x6000)
    if [ $width -le 0 ] || [ $height -le 0 ]; then
        echo "ERROR: Invalid crop dimensions (width=$width, height=$height)"
        exit 1
    fi
    ffmpeg_cmd+=",crop=${width}:${height}:${x_start}:${y_start}"
fi
ffmpeg_cmd+=",scale=800:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse\" -loop 0 -y \"$output\""

echo "Running ffmpeg command:"
echo "$ffmpeg_cmd"
eval "$ffmpeg_cmd"
ffmpeg_exit=$?

if [ $ffmpeg_exit -eq 0 ]; then
    echo "SUCCESS: GIF created as $output"
    # Optionally upload to repository (uncomment if needed)
    # git config user.name "github-actions[bot]"
    # git config user.email "github-actions[bot]@users.noreply.github.com"
    # git add "$output"
    # git commit -m "Generate timelapse GIF"
    # git push
else
    echo "ERROR: ffmpeg failed with exit code $ffmpeg_exit"
    exit $ffmpeg_exit
fi
