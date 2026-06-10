#!/bin/bash
# Debug version – prints all commands and stops on first error
set -euxo pipefail

# --- Configuration ----------------------------------------------------------
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

# --- Install dependencies ---------------------------------------------------
sudo apt-get update -qq
sudo apt-get install -y -qq jq ffmpeg bc curl imagemagick

# --- Date conversion -------------------------------------------------------
if command -v gdate &>/dev/null; then
    DATE_CMD="gdate"
else
    DATE_CMD="date"
fi

from_epoch=$($DATE_CMD -d "$date_from" +%s)
to_epoch=$($DATE_CMD -d "$date_to" +%s)
echo "from_epoch=$from_epoch to_epoch=$to_epoch"

# --- Fetch snapshots.json ---------------------------------------------------
MANIFEST_URL="$bucket_url/snapshots.json"
echo "Fetching $MANIFEST_URL"
curl -s -o snapshots.json "$MANIFEST_URL"
if [ ! -s snapshots.json ]; then
    echo "ERROR: snapshots.json is empty or not found."
    exit 1
fi

# Validate JSON and show first few entries
echo "snapshots.json content (first 200 chars):"
head -c 200 snapshots.json
echo ""

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

# --- Filter snapshots by date range ----------------------------------------
filtered=()
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
    echo "Date range: $date_from to $date_to"
    echo "First snapshot in manifest: $(jq -r '.[0]' snapshots.json)"
    echo "Last snapshot: $(jq -r '.[-1]' snapshots.json)"
    exit 1
fi

# --- Continue with the rest of the GIF generation (same as before) --------
# (The remaining code is identical to the previous working script – 
#  crop, banner, proportional delays, commit. I’ll omit it here for brevity,
#  but you must copy the full script from the previous answer that includes
#  the ImageMagick processing and git commit.)
