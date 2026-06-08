#!/bin/bash
set -euo pipefail

# ============================
# CONFIGURATION
# ============================
START_DATE="2026-01-10"
END_DATE="2026-05-11"
EXTRA_DATES=("2026-05-26" "2026-05-27" "2026-05-28")
BATCH_SIZE=50
STATE_FILE="backfill-progress.json"
R2_BUCKET="${R2_BUCKET:-wdp-archiver}"
R2_STATE_PATH="backfill-progress.json"

# Tile range (your 42 tiles)
X_START=1225
X_END=1231
Y_START=513
Y_END=518
TILE_COLS=$((X_END - X_START + 1))
TILE_ROWS=$((Y_END - Y_START + 1))

# GitHub token (provided by workflow)
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
AUTH_HEADER=()
if [[ -n "$GITHUB_TOKEN" ]]; then
    AUTH_HEADER=(-H "Authorization: token $GITHUB_TOKEN")
fi

# Check required tools
for tool in curl jq tar montage pngquant rclone; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Missing required tool: $tool"
        exit 1
    fi
done

# ============================
# FUNCTIONS
# ============================

# Fetch all release tags (tag_name and published_at) using pagination
fetch_all_releases() {
    local page=1
    local all_entries=()
    while true; do
        echo "Fetching releases page $page..." >&2
        local url="https://api.github.com/repos/murolem/wplace-archives/releases?page=$page&per_page=100"
        local response_file=$(mktemp)
        local http_code
        http_code=$(curl -s -w "%{http_code}" "${AUTH_HEADER[@]}" "$url" -o "$response_file")
        
        if [[ "$http_code" != "200" ]]; then
            echo "WARNING: GitHub API returned HTTP $http_code on page $page. Stopping." >&2
            rm "$response_file"
            break
        fi
        
        # Check if response is a non-empty JSON array
        if ! jq -e 'type == "array" and length > 0' "$response_file" >/dev/null 2>&1; then
            rm "$response_file"
            break
        fi
        
        # Extract tag_name and published_at
        while IFS=$'\t' read -r tag published; do
            all_entries+=("$tag|$published")
        done < <(jq -r '.[] | [.tag_name, .published_at] | @tsv' "$response_file")
        
        rm "$response_file"
        ((page++))
        
        # Safety limit
        if [[ $page -gt 200 ]]; then
            echo "WARNING: Reached page 200 limit, stopping." >&2
            break
        fi
        
        # Be polite to GitHub API
        sleep 0.5
    done
    
    printf '%s\n' "${all_entries[@]}"
}

# Convert tag to YYYYMMDD_HHMMSS filename (drop milliseconds)
date_from_tag() {
    local tag="$1"
    # Example: world-2026-05-26T01-10-14.124Z -> 20260526_011014
    echo "$tag" | sed 's/world-//' | sed 's/T/_/' | sed 's/-//g' | sed 's/\..*//'
}

# Process a single release
process_release() {
    local tag_name="$1"
    local snap_date=$(date_from_tag "$tag_name")
    local snapshot_name="wdpsnapshot_${snap_date}.png"
    
    echo "--- Processing $tag_name -> $snapshot_name"
    
    # Skip if already exists in R2 (check snapshots.json)
    if rclone cat "r2:$R2_BUCKET/snapshots.json" 2>/dev/null | jq -e 'type == "array"' >/dev/null; then
        if rclone cat "r2:$R2_BUCKET/snapshots.json" | jq -r ".[].filename" | grep -qx "$snapshot_name"; then
            echo "  Already exists in R2, skipping."
            return 0
        fi
    fi
    
    local temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN
    
    # Fetch asset URLs for the split tarballs
    local asset_urls=()
    while IFS= read -r url; do
        asset_urls+=("$url")
    done < <(curl -s "${AUTH_HEADER[@]}" "https://api.github.com/repos/murolem/wplace-archives/releases/tags/$tag_name" | jq -r '.assets[].browser_download_url' | grep '\.tar\.gz\.')
    
    if [[ ${#asset_urls[@]} -eq 0 ]]; then
        echo "  ERROR: No split tarballs found for $tag_name"
        return 1
    fi
    
    # Prepare tile paths (e.g., 1225/513.png)
    local tile_paths=()
    for x in $(seq $X_START $X_END); do
        for y in $(seq $Y_START $Y_END); do
            tile_paths+=("$x/$y.png")
        done
    done
    
    mkdir -p "$temp_dir/tiles"
    # Stream and extract only needed tiles
    (
        for url in "${asset_urls[@]}"; do
            curl -s --fail "$url"
        done
    ) | tar -xz -C "$temp_dir/tiles" --wildcards "${tile_paths[@]}" 2>/dev/null || {
        echo "  Warning: Some tiles missing, creating transparent placeholders"
        for path in "${tile_paths[@]}"; do
            local target="$temp_dir/tiles/$path"
            if [[ ! -f "$target" ]]; then
                mkdir -p "$(dirname "$target")"
                convert -size 1000x1000 xc:none "$target"
            fi
        done
    }
    
    # Build montage command (row-major order)
    local tile_files=()
    for y in $(seq $Y_START $Y_END); do
        for x in $(seq $X_START $X_END); do
            tile_files+=("$temp_dir/tiles/$x/$y.png")
        done
    done
    montage "${tile_files[@]}" -tile ${TILE_COLS}x${TILE_ROWS} -geometry 1000x1000+0+0 "$temp_dir/stitched.png"
    
    # Compress with pngquant
    pngquant --quality=80-100 --speed=1 --force 64 "$temp_dir/stitched.png" --output "$temp_dir/compressed.png"
    
    # Upload to R2
    rclone copyto "$temp_dir/compressed.png" "r2:$R2_BUCKET/$snapshot_name"
    
    # Update snapshots.json manifest
    local manifest_tmp=$(mktemp)
    local iso_timestamp=$(date -d "${tag_name//world-/}" -Iseconds 2>/dev/null || echo "1970-01-01T00:00:00Z")
    if rclone cat "r2:$R2_BUCKET/snapshots.json" 2>/dev/null | jq -e 'type == "array"' >/dev/null; then
        rclone cat "r2:$R2_BUCKET/snapshots.json" > "$manifest_tmp"
        jq --arg name "$snapshot_name" --arg ts "$iso_timestamp" '. += [{"filename": $name, "timestamp": $ts}]' "$manifest_tmp" > "$manifest_tmp.new"
    else
        jq -n --arg name "$snapshot_name" --arg ts "$iso_timestamp" '[{"filename": $name, "timestamp": $ts}]' > "$manifest_tmp.new"
    fi
    rclone copyto "$manifest_tmp.new" "r2:$R2_BUCKET/snapshots.json"
    
    echo "  ✓ Successfully processed and uploaded $snapshot_name"
    return 0
}

# ============================
# MAIN
# ============================

# Download state file from R2
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

# Fetch all releases (real tags, with irregular timestamps)
echo "Fetching all releases from GitHub (paginated)..."
all_releases=$(fetch_all_releases)
if [[ -z "$all_releases" ]]; then
    echo "ERROR: No releases found. Check GitHub API and token."
    exit 1
fi

total_fetched=$(echo "$all_releases" | wc -l)
echo "Fetched $total_fetched total releases."

# Filter releases by date range
target_tags=()
while IFS=$'|' read -r tag published; do
    pub_date="${published:0:10}"  # YYYY-MM-DD
    if [[ "$pub_date" >= "$START_DATE" && "$pub_date" <= "$END_DATE" ]]; then
        target_tags+=("$tag")
    else
        for extra in "${EXTRA_DATES[@]}"; do
            if [[ "$pub_date" == "$extra" ]]; then
                target_tags+=("$tag")
                break
            fi
        done
    fi
done <<< "$all_releases"

# Sort chronologically (oldest first)
IFS=$'\n' target_tags=($(sort <<<"${target_tags[*]}"))
unset IFS

total_targets=${#target_tags[@]}
echo "Total snapshots to backfill (within date range): $total_targets"

if [[ $total_targets -eq 0 ]]; then
    echo "No releases found in the target date range."
    exit 0
fi

# Find resume index
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
    echo "All target snapshots have already been processed!"
    exit 0
fi

echo "Resuming from index $start_idx (${target_tags[$start_idx]:-end})"

# Process up to BATCH_SIZE snapshots
processed_this_run=0
for ((i=start_idx; i<total_targets && processed_this_run<BATCH_SIZE; i++)); do
    tag="${target_tags[$i]}"
    if process_release "$tag"; then
        processed_this_run=$((processed_this_run + 1))
        processed_count=$((processed_count + 1))
        # Update state file after each success
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
