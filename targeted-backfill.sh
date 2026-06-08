#!/bin/bash
set -euo pipefail

START_DATE="2026-01-10"
END_DATE="2026-05-11"
EXTRA_DATES=("2026-05-26" "2026-05-27" "2026-05-28")
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

AUTH_HEADER=()
if [[ -n "$GITHUB_TOKEN" ]]; then
    AUTH_HEADER=(-H "Authorization: token $GITHUB_TOKEN")
fi

for tool in curl jq strings; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Missing required tool: $tool"
        exit 1
    fi
done

# Fetch the most recent release in the date range
echo "Fetching releases..."
all_releases=$(curl -s -L "${AUTH_HEADER[@]}" "https://api.github.com/repos/murolem/wplace-archives/releases?per_page=100" | jq -r '.[] | "\(.tag_name)|\(.published_at)"')
target_tags=()
while IFS='|' read -r tag published; do
    pub_date="${published:0:10}"
    if [[ "$pub_date" > "$START_DATE" || "$pub_date" == "$START_DATE" ]] && \
       [[ "$pub_date" < "$END_DATE" || "$pub_date" == "$END_DATE" ]]; then
        target_tags+=("$tag")
    else
        for extra in "2026-05-26" "2026-05-27" "2026-05-28"; do
            if [[ "$pub_date" == "$extra" ]]; then
                target_tags+=("$tag")
                break
            fi
        done
    fi
done <<< "$all_releases"

IFS=$'\n' target_tags=($(sort -r <<<"${target_tags[*]}"))
first_tag="${target_tags[0]}"
echo "Debug snapshot: $first_tag"

# Get the first split part URL (aa)
asset_url=$(curl -s -L "${AUTH_HEADER[@]}" "https://api.github.com/repos/murolem/wplace-archives/releases/tags/$first_tag" | jq -r '.assets[] | select(.name | endswith(".tar.gz.aa")) | .browser_download_url')
if [[ -z "$asset_url" ]]; then
    echo "ERROR: No .aa split part found."
    exit 1
fi
echo "First part URL: $asset_url"

echo "Downloading first 2 MB of this part (no full download)..."
temp_file=$(mktemp)
curl -L -s --fail -r 0-2097152 "$asset_url" -o "$temp_file"

echo "File type:"
file "$temp_file"

echo "First 100 bytes (hexdump):"
xxd -l 100 "$temp_file" || true

echo "Attempting to list filenames from partial tarball (may show first few files)..."
if tar -tzf "$temp_file" 2>/dev/null | head -30; then
    echo "Successfully listed some entries."
else
    echo "tar failed. Using 'strings' to grep for potential tile paths..."
    strings "$temp_file" | grep -E '[0-9]{3,4}/[0-9]{3,4}\.png' | head -30
fi

rm "$temp_file"
echo "Debug complete. No full downloads were performed."
