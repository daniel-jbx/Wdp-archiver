#!/bin/bash
set -euo pipefail

# ----------------------------------------------------------------------
# Script to generate a timelapse GIF from wplace.live snapshots
# stored in a public Cloudflare R2 bucket.
#
# Configuration is read from 'gif-config.txt' in the repository root.
# ----------------------------------------------------------------------

# --- 1. Parse Configuration -------------------------------------------------
CONFIG_FILE="gif-config.txt"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Configuration file $CONFIG_FILE not found."
    exit 1
fi

# Read key-value pairs (allowing spaces around the '=')
date_from=$(grep -E '^date_from=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')
date_to=$(grep -E '^date_to=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')
x_start=$(grep -E '^x_start=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')
x_end=$(grep -E '^x_end=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')
y_start=$(grep -E '^y_start=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')
y_end=$(grep -E '^y_end=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')
max_fps=$(grep -E '^max_fps=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')
output=$(grep -E '^output=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')
bucket_url=$(grep -E '^bucket_url=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')

# Set default bucket URL if not provided
if [ -z "$bucket_url" ]; then
    bucket_url="https://pub-e0766eb5f5114fc097a10215d5e6081b.r2.dev"
fi

# Basic validation
if [ -z "$date_from" ] || [ -z "$date_to" ] || [ -z "$max_fps" ]; then
    echo "ERROR: date_from, date_to, and max_fps must be set in $CONFIG_FILE."
    exit 1
fi

# Convert dates to seconds since epoch for easy comparison
# Using 'date -d' which works in GNU date (Linux) and also in macOS if you have GNU coreutils.
# We'll attempt to support both, but this is the standard.
if command -v gdate &> /dev/null; then
    DATE_CMD="gdate"
else
    DATE_CMD="date"
fi

from_epoch=$($DATE_CMD -d "$date_from" +%s 2>/dev/null)
to_epoch=$($DATE_CMD -d "$date_to" +%s 2>/dev/null)

if [ -z "$from_epoch" ] || [ -z "$to_epoch" ]; then
    echo "ERROR: Invalid date format. Please use 'YYYY-MM-DD HH:MM:SS'."
    exit 1
fi

# --- 2. Install Dependencies (for GitHub Actions environment) -------------
# Install required packages if they're missing. This is idempotent.
if ! command -v jq &> /dev/null; then
    echo "Installing jq..."
    sudo apt-get update && sudo apt-get install -y jq
fi

if ! command -v ffmpeg &> /dev/null; then
    echo "Installing ffmpeg..."
    sudo apt-get update && sudo apt-get install -y ffmpeg
fi

if ! command -v curl &> /dev/null; then
    echo "Installing curl..."
    sudo apt-get update && sudo apt-get install -y curl
fi

if ! command -v bc &> /dev/null; then
    echo "Installing bc..."
    sudo apt-get update && sudo apt-get install -y bc
fi

# --- 3. List Snapshots from the Public R2 Bucket -------------------------
echo "Fetching snapshot list from public R2 bucket: $bucket_url"

# For public R2 buckets, you can use the S3 ListObjectsV2 API.
# However, the bucket must have the ListBucket permission for public access.
# If your bucket does not, you'll need to provide credentials via rclone (see comments below).
# We'll construct the S3 request URL.
BUCKET_NAME="wdp-archiver"   # The bucket name from the original project
ENDPOINT="${bucket_url/https:\/\//}"  # remove https:// for the path
# The S3 endpoint for list operations is often different from the CDN URL.
# For Cloudflare R2, the public r2.dev URL does not support listing.
# You need to use the S3-compatible endpoint, which typically requires credentials.
# We'll attempt the direct S3 API, but it will likely fail. We'll fall back to rclone if needed.

# Attempt to list objects using the S3 REST API (will fail if bucket is not public-listable)
LIST_URL="https://${ENDPOINT}/${BUCKET_NAME}/?list-type=2&prefix=wdpsnapshot_"
HTTP_STATUS=$(curl -s -o bucket-list.xml -w "%{http_code}" "$LIST_URL")

if [ "$HTTP_STATUS" -ne 200 ]; then
    echo "WARNING: Direct S3 listing failed (HTTP $HTTP_STATUS)."
    echo "The bucket is not configured to allow public listing, or the endpoint is incorrect."
    echo "Attempting to use rclone with credentials (if provided)."

    # --- Fallback to rclone with credentials ---------------------------------
    # You must provide R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, and R2_ENDPOINT
    # as environment variables (e.g., GitHub secrets).
    if [ -z "${R2_ACCESS_KEY_ID:-}" ] || [ -z "${R2_SECRET_ACCESS_KEY:-}" ] || [ -z "${R2_ENDPOINT:-}" ]; then
        echo "ERROR: R2 credentials not set. Please provide R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, and R2_ENDPOINT."
        exit 1
    fi

    # Configure rclone on the fly
    if ! command -v rclone &> /dev/null; then
        echo "Installing rclone..."
        curl -s https://rclone.org/install.sh | sudo bash
    fi

    # Create rclone config
    rclone config create r2 s3 \
        provider=Cloudflare \
        access_key_id="$R2_ACCESS_KEY_ID" \
        secret_access_key="$R2_SECRET_ACCESS_KEY" \
        endpoint="$R2_ENDPOINT" \
        acl=public-read

    # List files with rclone
    rclone lsjson "r2:$BUCKET_NAME" --include "wdpsnapshot_*.png" > snapshots.json
else
    # Parse the XML response for the keys
    echo "Successfully listed bucket via S3 API."
    # Use grep and sed to extract the filenames from the XML
    # This is a bit brittle but works for simple cases.
    grep -oP '(?<=<Key>)wdpsnapshot_.*?\.png(?=</Key>)' bucket-list.xml > snapshot_files.txt
    # Convert list to JSON format for consistency with rclone
    jq -R -s 'split("\n") | map(select(length>0)) | { ".[]": { "Name": . } }' snapshot_files.txt > snapshots.json
fi

if [ ! -s snapshots.json ]; then
    echo "ERROR: No snapshots found."
    exit 1
fi

# --- 4. Filter by Date Range ------------------------------------------------
# Extract filename and timestamp (from the filename)
jq -r '.[] | [.Name, (.Name | sub("wdpsnapshot_"; "") | sub("\\.[^.]*$"; "") | gsub("_"; ":"))] | @tsv' snapshots.json > raw_snapshots.txt

filtered_snapshots=()
while IFS=$'\t' read -r file timestamp_str; do
    # Convert timestamp from YYYYMMDD:HHMMSS to epoch
    epoch=$($DATE_CMD -d "${timestamp_str:0:4}-${timestamp_str:4:2}-${timestamp_str:6:2} ${timestamp_str:9:2}:${timestamp_str:11:2}:${timestamp_str:13:2}" +%s 2>/dev/null || true)
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

# --- 5. Compute Intervals and Durations ------------------------------------
min_interval=999999999
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
        # Download the first file (we need to download all files anyway)
        echo "Downloading $file..."
        curl -s -o "$file" "$bucket_url/$file"
        prev_epoch=$epoch
        continue
    fi
    interval=$((epoch - prev_epoch))
    # Duration = (interval / min_interval) * base_duration
    duration=$(echo "scale=6; ($interval / $min_interval) * $base_duration" | bc)
    # Append to concat script (last frame will be omitted, we'll duplicate it)
    concat_script+="file '$file'\n"
    concat_script+="duration $duration\n"
    # Download the next file
    echo "Downloading $file..."
    curl -s -o "$file" "$bucket_url/$file"
    prev_epoch=$epoch
done
# Duplicate the last frame to force its duration (ffmpeg requirement)
last_file="${filtered_snapshots[-1]%:*}"
concat_script+="file '$last_file'\n"

echo -e "$concat_script" > concat.txt

# --- 6. Generate GIF with Optional Cropping --------------------------------
ffmpeg_cmd="ffmpeg -f concat -safe 0 -i concat.txt -vf \"fps=$max_fps"
if [ -n "$x_start" ] && [ -n "$x_end" ] && [ -n "$y_start" ] && [ -n "$y_end" ]; then
    width=$((x_end - x_start))
    height=$((y_end - y_start))
    ffmpeg_cmd+=",crop=${width}:${height}:${x_start}:${y_start}"
fi
ffmpeg_cmd+=",scale=800:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse\" -loop 0 \"$output\""

eval "$ffmpeg_cmd"

echo "GIF successfully created: $output"

# --- 7. Optional: Upload the GIF back to the repository --------------------
# If you want to commit the GIF to the main branch, uncomment the following:
# git config user.name "github-actions[bot]"
# git config user.email "github-actions[bot]@users.noreply.github.com"
# git add "$output"
# git commit -m "Add generated timelapse GIF"
# git push
