#!/bin/bash
set -euo pipefail

START_DATE="2026-01-10"
END_DATE="2026-05-11"
EXTRA_DATES=("2026-05-26" "2026-05-27" "2026-05-28")
R2_BUCKET="${R2_BUCKET:-wdp-archiver}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

AUTH_HEADER=()
if [[ -n "$GITHUB_TOKEN" ]]; then
    AUTH_HEADER=(-H "Authorization: token $GITHUB_TOKEN")
fi

for tool in curl jq tar xxd; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Missing required tool: $tool"
        exit 1
    fi
done

# Fetch the most recent release in the date range
echo "Fetching all releases..."
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

# Pick the most recent (first after sort -r)
IFS=$'\n' target_tags=($(sort -r <<<"${target_tags[*]}"))
first_tag="${target_tags[0]}"
echo "Debug snapshot: $first_tag"

# Fetch asset URLs for this release
asset_urls=()
while IFS= read -r url; do
    asset_urls+=("$url")
done < <(curl -s -L "${AUTH_HEADER[@]}" "https://api.github.com/repos/murolem/wplace-archives/releases/tags/$first_tag" | jq -r '.assets[].browser_download_url' | grep '\.tar\.gz\.')

if [[ ${#asset_urls[@]} -eq 0 ]]; then
    echo "ERROR: No split tarballs found."
    exit 1
fi

echo "Downloading ${#asset_urls[@]} split parts with redirect following..."
temp_file=$(mktemp)
for url in "${asset_urls[@]}"; do
    echo "  $url"
    curl -L -s --fail "$url" >> "$temp_file"
    # Check that we actually downloaded something
    size=$(stat -c%s "$temp_file" 2>/dev/null || stat -f%z "$temp_file" 2>/dev/null || echo "0")
    echo "  Current total size: $size bytes"
done

echo "Checking file type..."
file "$temp_file"
echo "First 100 bytes (hexdump):"
xxd -l 100 "$temp_file"

echo "Attempting to list tar contents..."
tar -tzf "$temp_file" 2>&1 | head -30 || {
    echo "tar command failed. The archive might be corrupted or not a valid tar.gz."
}

rm "$temp_file"
