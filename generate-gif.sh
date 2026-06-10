#!/bin/bash
set -euo pipefail

# ---------------------------
# 1. Parse configuration
# ---------------------------
CONFIG_FILE="gif-config.txt"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Configuration file $CONFIG_FILE not found"
    exit 1
fi

# Read key-value pairs
date_from=$(grep -E '^date_from=' "$CONFIG_FILE" | cut -d'=' -f2 | sed 's/^ *//;s/ *$//')
date_to=$(grep -E '^date_to=' "$CONFIG_FILE" | cut -d'=' -f2 | sed 's/^ *//;s/ *$//')
x_start=$(grep -E '^x_start=' "$CONFIG_FILE" | cut -d'=' -f2 | sed 's/^ *//;s/ *$//')
x_end=$(grep -E '^x_end=' "$CONFIG_FILE" | cut -d'=' -f2 | sed 's/^ *//;s/ *$//')
y_start=$(grep -E '^y_start=' "$CONFIG_FILE" | cut -d'=' -f2 | sed 's/^ *//;s/ *$//')
y_end=$(grep -E '^y_end=' "$CONFIG_FILE" | cut -d'=' -f2 | sed 's/^ *//;s/ *$//')
max_fps=$(grep -E '^max_fps=' "$CONFIG_FILE" | cut -d'=' -f2 | sed 's/^ *//;s/ *$//')
output=$(grep -E '^output=' "$CONFIG_FILE" | cut -d'=' -f2 | sed 's/^ *//;s/ *$//')

# Basic validation
if [ -z "$date_from" ] || [ -z "$date_to" ] || [ -z "$max_fps" ]; then
    echo "ERROR: Missing required fields in $CONFIG_FILE"
    exit 1
fi

# Convert dates to seconds since epoch for easy comparison
from_epoch=$(date -d "$date_from" +%s)
to_epoch=$(date -d "$date_to" +%s)

# ---------------------------
# 2. Install dependencies (GitHub Actions environment)
# ---------------------------
# Install rclone if not present
if ! command -v rclone &> /dev/null; then
    echo "Installing rclone..."
    curl -s https://rclone.org/install.sh | sudo bash
fi

# ffmpeg, jq, and ImageMagick are usually pre-installed on Ubuntu runners.
# If not, uncomment the line below:
# sudo apt-get update && sudo apt-get install -y ffmpeg jq imagemagick

# ---------------------------
# 3. List snapshots from R2 bucket
# ---------------------------
# The bucket is public; you can also use rclone with credentials if private.
# Here we assume the bucket is public and accessible via a custom domain.
# Adjust the remote name or URL as needed.
R2_BUCKET="wdp-archiver"
R2_ENDPOINT="https://<account-id>.r2.cloudflarestorage.com"

echo "Fetching snapshot list from R2..."
rclone lsjson ":$R2_BUCKET" --include "wdpsnapshot_*.png" --s3-provider="Cloudflare" --s3-endpoint="$R2_ENDPOINT" > snapshots.json

# Use jq to extract filename and timestamp
jq -r '.[] | [.Name, (.Name | sub("wdpsnapshot_"; "") | sub("\\.[^.]*$"; "") | gsub("_"; ":"))] | @tsv' snapshots.json > raw_snapshots.txt

# ---------------------------
# 4. Filter by date range
# ---------------------------
filtered_snapshots=()
while IFS=$'\t' read -r file timestamp_str; do
    # Convert timestamp from YYYYMMDD:HHMMSS to epoch
    epoch=$(date -d "${timestamp_str:0:4}-${timestamp_str:4:2}-${timestamp_str:6:2} ${timestamp_str:9:2}:${timestamp_str:11:2}:${timestamp_str:13:2}" +%s 2>/dev/null || true)
    if [ -n "$epoch" ] && [ "$epoch" -ge "$from_epoch" ] && [ "$epoch" -le "$to_epoch" ]; then
        filtered_snapshots+=("$file:$epoch")
    fi
done < raw_snapshots.txt

if [ ${#filtered_snapshots[@]} -lt 2 ]; then
    echo "ERROR: At least two snapshots are required to create a GIF."
    exit 1
fi

# Sort by timestamp (just in case)
IFS=$'\n' filtered_snapshots=($(sort -t: -k2 -n <<<"${filtered_snapshots[*]}"))
unset IFS

# ---------------------------
# 5. Compute intervals and durations
# ---------------------------
min_interval=999999999
declare -a durations
prev_epoch=0
for entry in "${filtered_snapshots[@]}"; do
    file="${entry%:*}"
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

# Duration for the shortest interval = 1 / max_fps seconds
base_duration=$(echo "scale=6; 1 / $max_fps" | bc)

# Build arrays for ffmpeg concat script
concat_script="ffconcat version 1.0\n"
prev_epoch=0
for entry in "${filtered_snapshots[@]}"; do
    file="${entry%:*}"
    epoch="${entry#*:}"
    if [ $prev_epoch -eq 0 ]; then
        prev_epoch=$epoch
        continue
    fi
    interval=$((epoch - prev_epoch))
    # Duration = (interval / min_interval) * base_duration
    duration=$(echo "scale=6; ($interval / $min_interval) * $base_duration" | bc)
    # Append to concat script (last frame will be omitted, we'll duplicate it)
    concat_script+="file '$file'\n"
    concat_script+="duration $duration\n"
    prev_epoch=$epoch
done
# Duplicate the last frame to force its duration (ffmpeg requirement)
last_file="${filtered_snapshots[-1]%:*}"
concat_script+="file '$last_file'\n"

echo -e "$concat_script" > concat.txt

# ---------------------------
# 6. Generate GIF with optional cropping
# ---------------------------
ffmpeg_cmd="ffmpeg -f concat -safe 0 -i concat.txt -vf \"fps=$max_fps"
if [ -n "$x_start" ] && [ -n "$x_end" ] && [ -n "$y_start" ] && [ -n "$y_end" ]; then
    width=$((x_end - x_start))
    height=$((y_end - y_start))
    ffmpeg_cmd+=",crop=${width}:${height}:${x_start}:${y_start}"
fi
ffmpeg_cmd+=",scale=800:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse\" -loop 0 \"$output\""

eval "$ffmpeg_cmd"

echo "GIF successfully created: $output"

# ---------------------------
# 7. Upload the GIF back to the repository (optional)
# ---------------------------
# If you want to commit the GIF to the main branch, uncomment the following:
# git config user.name "github-actions[bot]"
# git config user.email "github-actions[bot]@users.noreply.github.com"
# git add "$output"
# git commit -m "Add generated timelapse GIF"
# git push
