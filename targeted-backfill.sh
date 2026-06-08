#!/bin/bash
set -euo pipefail

# ============================
# CONFIGURATION (May 26–29)
# ============================
START_DATE="2026-05-26"
END_DATE="2026-05-29"
EXTRA_DATES=()   # not needed, already in range
BATCH_SIZE=50    # enough to process all ~24 snapshots in one run
STATE_FILE="backfill-progress.json"
R2_BUCKET="${R2_BUCKET:-wdp-archiver}"
R2_STATE_PATH="backfill-progress.json"

X_START=1225
X_END=1231
Y_START=513
Y_END=518
TILE_COLS=$((X_END - X_START + 1))
TILE_ROWS=$((Y_END - Y_START + 1))

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
AUTH_HEADER=()
if [[ -n "$GITHUB_TOKEN" ]]; then
    AUTH_HEADER=(-H "Authorization: token $GITHUB_TOKEN")
fi

for tool in curl jq tar montage pngquant rclone; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Missing required tool: $tool"
        exit 1
    fi
done

# ============================
# FUNCTIONS
# ============================

fetch_all_releases() {
    local page=1
    local all_entries=()
    while true; do
        echo "Fetching releases page $page..." >&2
        local url="https://api.github.com/repos/murolem/wplace-archives/releases?page=$page&per_page=100"
        local response_file=$(mktemp)
        local http_code
        http_code=$(curl -s -w "%{http_code}" -L "${AUTH_HEADER[@]}" "$url" -o "$response_file")
        if [[ "$http_code" != "200" ]]; then
            echo "WARNING: GitHub API returned HTTP $http_code on page $page. Stopping." >&2
            rm "$response_file"
            break
        fi
        if ! jq -e 'type == "array" and length > 0' "$response_file" >/dev/null 2>&1; then
            rm "$response_file"
            break
        fi
        while IFS=$'\t' read -r tag published; do
            all_entries+=("$tag|$published")
        done < <(jq -r '.[] | [.tag_name, .published_at] | @tsv' "$response_file")
        rm "$response_file"
        ((page++))
        if [[ $page -gt 200 ]]; then
            echo "WARNING: Reached page 200 limit, stopping." >&2
            break
        fi
        sleep 0.5
    done
    printf '%s\n' "${all_entries[@]}"
}

date_from_tag() {
    local tag="$1"
    echo "$tag" | sed 's/world-//' | sed 's/T/_/' | sed 's/-//g' | sed 's/\..*//'
}

# Ensure snapshots.json is a valid JSON array
ensure_valid_manifest() {
    local tmp_manifest=$(mktemp)
    if rclone cat "r2:$R2_BUCKET/snapshots.json" 2>/dev/null > "$tmp_manifest"; then
        if ! jq -e 'type == "array"' "$tmp_manifest" >/dev/null 2>&1; then
            echo "  WARNING: snapshots.json is corrupted. Backing up and resetting."
            rclone copyto "$tmp_manifest" "r2:$R2_BUCKET/snapshots.json.corrupted.$(date +%s)"
            echo '[]' | rclone copyto - "r2:$R2_BUCKET/snapshots.json"
        fi
    else
        echo '[]' | rclone copyto - "r2:$R2_BUCKET/snapshots.json"
    fi
    rm -f "$tmp_manifest"
}

process_release() {
    local tag_name="$1"
    local snap_date=$(date_from_tag "$tag_name")
    local snapshot_name="wdpsnapshot_${snap_date}.png"
    
    echo "--- Processing $tag_name -> $snapshot_name"
    
    # Skip if already in manifest
    ensure_valid_manifest
    if rclone cat "r2:$R2_BUCKET/snapshots.json" | jq -r ".[].filename" | grep -qx "$snapshot_name"; then
        echo "  Already exists in snapshots.json, skipping."
        return 0
    fi
    
    local temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN
    
    # Fetch split part URLs
    local asset_urls=()
    while IFS= read -r url; do
        asset_urls+=("$url")
    done < <(curl -s -L "${AUTH_HEADER[@]}" "https://api.github.com/repos/murolem/wplace-archives/releases/tags/$tag_name" | jq -r '.assets[].browser_download_url' | grep '\.tar\.gz\.')
    
    if [[ ${#asset_urls[@]} -eq 0 ]]; then
        echo "  ERROR: No split tarballs found for $tag_name"
        return 1
    fi
    
    # Build patterns for the 42 tiles (match any top directory)
    local tile_patterns=()
    for x in $(seq $X_START $X_END); do
        for y in $(seq $Y_START $Y_END); do
            tile_patterns+=("*/$x/$y.png")
        done
    done
    
    mkdir -p "$temp_dir/tiles"
    # Stream concatenated parts, strip top directory, extract matching files
    (
        for url in "${asset_urls[@]}"; do
            curl -L -s --fail "$url"
        done
    ) | tar -xz --strip-components=1 -C "$temp_dir/tiles" --wildcards "${tile_patterns[@]}" 2>/dev/null || true
    
    extracted_count=$(find "$temp_dir/tiles" -name "*.png" 2>/dev/null | wc -l)
    echo "  Extracted $extracted_count tiles (up to 42). Missing tiles will be transparent placeholders."
    
    # Build expected tile files
    local tile_files=()
    for y in $(seq $Y_START $Y_END); do
        for x in $(seq $X_START $X_END); do
            tile_files+=("$temp_dir/tiles/$x/$y.png")
        done
    done
    
    # Create transparent placeholders for missing
    for tf in "${tile_files[@]}"; do
        if [[ ! -f "$tf" ]]; then
            mkdir -p "$(dirname "$tf")"
            convert -size 1000x1000 xc:none "$tf"
        fi
    done
    
    # Stitch
    montage "${tile_files[@]}" -tile ${TILE_COLS}x${TILE_ROWS} -geometry 1000x1000+0+0 "$temp_dir/stitched.png"
    pngquant --quality=80-100 --speed=1 --force 64 "$temp_dir/stitched.png" --output "$temp_dir/compressed.png"
    
    # Upload to R2
    rclone copyto "$temp_dir/compressed.png" "r2:$R2_BUCKET/$snapshot_name"
    
    # Update snapshots.json (append new entry)
    local iso_timestamp=$(date -d "${tag_name//world-/}" -Iseconds 2>/dev/null || echo "1970-01-01T00:00:00Z")
    local manifest_tmp=$(mktemp)
    rclone cat "r2:$R2_BUCKET/snapshots.json" > "$manifest_tmp"
    jq --arg name "$snapshot_name" --arg ts "$iso_timestamp" '. += [{"filename": $name, "timestamp": $ts}]' "$manifest_tmp" > "$manifest_tmp.new"
    rclone copyto "$manifest_tmp.new" "r2:$R2_BUCKET/snapshots.json"
    
    echo "  ✓ Successfully uploaded $snapshot_name and updated snapshots.json"
    return 0
}

# ============================
# MAIN
# ============================

if rclone cat "r2:$R2_BUCKET/$R2_STATE_PATH" 2>/dev/null > "$STATE_FILE"; then
    last_processed=$(jq -r '.last_processed_tag' "$STATE_FILE")
    processed_count=$(jq -r '.processed_count' "$STATE_FILE")
else
    last_processed=""
    processed_count=0
    echo '{"last_processed_tag": "", "processed_count": 0}' > "$STATE_FILE"
fi

echo "Last processed tag: ${last_processed:-none}"
echo "Total processed so far: $processed_count"

echo "Fetching all releases from GitHub (paginated)..."
all_releases=$(fetch_all_releases)
if [[ -z "$all_releases" ]]; then
    echo "ERROR: No releases found."
    exit 1
fi

total_fetched=$(echo "$all_releases" | wc -l)
echo "Fetched $total_fetched total releases."

target_tags=()
while IFS=$'|' read -r tag published; do
    pub_date="${published:0:10}"
    if [[ "$pub_date" >= "$START_DATE" && "$pub_date" <= "$END_DATE" ]]; then
        target_tags+=("$tag")
    fi
done <<< "$all_releases"

# Sort chronologically (oldest first – better for viewer timeline)
IFS=$'\n' target_tags=($(sort <<<"${target_tags[*]}"))
unset IFS

total_targets=${#target_tags[@]}
echo "Total snapshots in date range ($START_DATE to $END_DATE): $total_targets"
if [[ $total_targets -eq 0 ]]; then
    echo "No releases in target date range."
    exit 0
fi

start_idx=0
if [[ -n "$last_processed" ]]; then
    for i in "${!target_tags[@]}"; do
        if [[ "${target_tags[$i]}" == "$last_processed" ]]; then
            start_idx=$((i + 1))
            break
        fi
    done
fi

if [[ $start_idx -ge $total_targets ]]; then
    echo "All snapshots already processed!"
    exit 0
fi

echo "Resuming from index $start_idx (${target_tags[$start_idx]:-end})"

processed_this_run=0
for ((i=start_idx; i<total_targets && processed_this_run<BATCH_SIZE; i++)); do
    tag="${target_tags[$i]}"
    if process_release "$tag"; then
        processed_this_run=$((processed_this_run + 1))
        processed_count=$((processed_count + 1))
        jq --arg tag "$tag" --argjson cnt "$processed_count" \
            '.last_processed_tag = $tag | .processed_count = $cnt' "$STATE_FILE" > "$STATE_FILE.tmp"
        mv "$STATE_FILE.tmp" "$STATE_FILE"
        rclone copyto "$STATE_FILE" "r2:$R2_BUCKET/$R2_STATE_PATH"
    else
        echo "Failed to process $tag – stopping batch."
        break
    fi
done

echo "============================================="
echo "Run finished. Processed $processed_this_run snapshots."
echo "Total processed overall: $processed_count"
if [[ $((start_idx + processed_this_run)) -ge $total_targets ]]; then
    echo "🎉 All target snapshots have been backfilled!"
fi
