#!/bin/bash
# No "set -e" for now – we want to see every failure.

# Print every command and its output immediately
set -x
exec 2>&1   # redirect stderr to stdout for full capture

echo "=== Starting GIF generation ==="

CONFIG_FILE="gif-config.txt"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file missing"
    exit 1
fi

# Read config
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

echo "date_from=$date_from"
echo "date_to=$date_to"
echo "max_fps=$max_fps"
echo "bucket_url=$bucket_url"

# Validate required fields
if [ -z "$date_from" ] || [ -z "$date_to" ] || [ -z "$max_fps" ]; then
    echo "ERROR: Required fields missing"
    exit 1
fi

# Install dependencies (GitHub Actions runner already has them, but ensure)
echo "Installing packages..."
sudo apt-get update -qq
sudo apt-get install -y -qq jq ffmpeg bc curl

# Date conversion
if command -v gdate &>/dev/null; then
    DATE_CMD="gdate"
else
    DATE_CMD="date"
fi

from_epoch=$($DATE_CMD -d "$date_from" +%s)
to_epoch=$($DATE_CMD -d "$date_to" +%s)

if [ -z "$from_epoch" ] || [ -z "$to_epoch" ]; then
    echo "ERROR: Date conversion failed"
    exit 1
fi

echo "from_epoch=$from_epoch to_epoch=$to_epoch"

# Fetch manifest
MANIFEST_URL="$bucket_url/snapshots.json"
echo "Fetching $MANIFEST_URL"
curl -v -o snapshots.json "$MANIFEST_URL"  # verbose to see HTTP status

if [ ! -s snapshots.json ]; then
    echo "ERROR: snapshots.json empty or not fetched"
    exit 1
fi

echo "Manifest content:"
cat snapshots.json

# Check if manifest is a valid JSON array
if ! jq -e 'type == "array"' snapshots.json >/dev/null; then
    echo "ERROR: snapshots.json is not a JSON array"
    exit 1
fi

# Extract snapshots in date range
filtered=()
for file in $(jq -r '.[]' snapshots.json); do
    ts=$(echo "$file" | sed -n 's/.*wdpsnapshot_\([0-9]\{8\}_[0-9]\{6\}\)\.png/\1/p')
    if [ -z "$ts" ]; then continue; fi
    epoch=$($DATE_CMD -d "${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:9:2}:${ts:11:2}:${ts:13:2}" +%s)
    if [ "$epoch" -ge "$from_epoch" ] && [ "$epoch" -le "$to_epoch" ]; then
        filtered+=("$file:$epoch")
    fi
done

echo "Filtered snapshots: ${#filtered[@]}"
if [ ${#filtered[@]} -lt 2 ]; then
    echo "ERROR: Not enough snapshots in range"
    exit 1
fi

# Continue with the rest of the GIF generation...
# (the rest is unchanged from the previous script, but we'll add it for completeness)
# For brevity, I'll assume you add the remaining code from the earlier version.
# The key is that we now see exactly where it stops.
