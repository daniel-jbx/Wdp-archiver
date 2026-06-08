#!/bin/bash
set -euo pipefail

# ============================
# CONFIGURATION
# ============================
START_DATE="2026-01-10"
END_DATE="2026-05-11"
EXTRA_DATES=("2026-05-26" "2026-05-27" "2026-05-28")
BATCH_SIZE=50                     # number of snapshots per workflow run
STATE_FILE="backfill-progress.json"
R2_BUCKET="${R2_BUCKET:-wdp-archiver}"
R2_STATE_PATH="backfill-progress.json"

# Tile range (exactly your 42 tiles)
X_START=1225
X_END=1231
Y_START=513
Y_END=518
TILE_COLS=$((X_END - X_START + 1))
TILE_ROWS=$((Y_END - Y_START + 1))

# GitHub API token (optional, but strongly recommended to avoid rate limiting)
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
AUTH_HEADER=""
if [[ -n "$GITHUB_TOKEN" ]]; then
    AUTH_HEADER="-H 'Authorization: token $GITHUB_TOKEN'"
fi

# Tools check
for tool in curl jq tar montage pngquant rclone; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Missing required tool: $tool"
        exit 1
    fi
done

# ============================
# FUNCTIONS
# ============================

# Fetch all release tags for a given date (YYYY-MM-DD)
get_tags_for_date() {
    local date_str="$1"
    # Use per_page=100 to catch all releases (murolem has ~8 per day)
    eval curl -s "https://api.github.com/repos/murolem/wplace-archives/releases?per_page=100" \
        "$AUTH_HEADER" | jq -r ".[] | select(.tag_name | startswith(\"world-$date_str\")) | .tag_name"
}

# Generate all dates between START_DATE and END_DATE (inclusive)
get_date_list() {
    local start="$1"
    local end="$2"
    local current=$(date -d "$start" +%Y-%m-%d)
    local end_date=$(date -d "$end" +%Y-%m-%d)
    while [[ "$current" < "$end_date" ]] || [[ "$current" == "$end_date" ]]; do
        echo "$current"
        current=$(date -d "$current + 1 day" +%Y-%m-%d)
    done
}

# Build the full list of target release tags (oldest first)
build_target_tags() {
    local tags=()
    # Main range
    for date in $(get_date_list "$START_DATE" "$END_DATE"); do
        while IFS= read -r tag; do
            [[ -n "$tag" ]] && tags+=("$tag")
        done < <(get_tags_for_date "$date")
    done
    # Extra dates (May 26–28)
    for date in "${EXTRA_DATES[@]}"; do
        while IFS= read -r tag; do
            [[ -n "$tag" ]] && tags+=("$tag")
        done < <(get_tags_for_date "$date")
    done
    # Sort chronologically (oldest first)
    printf '%s\n' "${tags[@]}" | sort
}

# Convert tag to YYYYMMDD_HHMMSS for snapshot filename
date_from_tag() {
    local tag="$1"
    # world-2026-01-10T00-00-00.000Z -> 20260110_000000
    echo "$tag" | sed 's/world-//' | sed 's/T/_/' | sed 's/-//g' | sed 's/\..*//'
}

# Process a single release: extract 42 tiles, stitch, compress, upload
process_release() {
    local tag_name="$1"
    local snap_date=$(date_from_tag "$tag_name")
    local snapshot_name="wdpsnapshot_${snap_date}.png"

    echo "--- Processing $tag_name -> $snapshot_name"

    # Skip if already exists in R2 (check snapshots.json)
    if rclone cat "r2:$R2_BUCKET/snapshots.json" 2>/dev/null | jq -r ".[].filename" | grep -qx "$snapshot_name"; then
        echo "  Already exists in R2, skipping."
        return 0
    fi

    local temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    # Fetch asset URLs (the split .tar.gz parts)
    local asset_urls=()
    while IFS= read -r url; do
        asset_urls+=("$url")
    done < <(eval curl -s "https://api.github.com/repos/murolem/wplace-archives/releases/tags/$tag_name" \
        "$AUTH_HEADER" | jq -r '.assets[].browser_download_url' | grep '\.tar\.gz\.')

    if [[ ${#asset_urls[@]} -eq 0 ]]; then
        echo "  ERROR: No split tarballs found for $tag_name"
        return 1
    fi

    # Prepare list of tile paths (e.g., 1225/513.png)
    local tile_paths=()
    for x in $(seq $X_START $X_END); do
        for y in $(seq $Y_START $Y_END); do
            tile_paths+=("$x/$y.png")
        done
    done

    # Extract only the needed tiles from the concatenated tarballs
    mkdir -p "$temp_dir/tiles"
    (
        for url in "${asset_urls[@]}"; do
            curl -s --fail "$url"
        done
    ) | tar -xz -C "$temp_dir/tiles" --wildcards "${tile_paths[@]}" 2>/dev/null || {
        # Some tiles may be missing from the archive (shouldn't happen for valid coordinates)
        echo "  Warning: Some tiles missing, creating transparent placeholders"
        for path in "${tile_paths[@]}"; do
            local target="$temp_dir/tiles/$path"
            if [[ ! -f "$target" ]]; then
                mkdir -p "$(dirname "$target")"
                convert -size 1000x1000 xc:none "$target"
            fi
        done
    }

    # Build montage command: order row‑major (y first, then x)
    local tile_files=()
    for y in $(seq $Y_START $Y_END); do
        for x in $(seq $X_START $X_END); do
            tile_files+=("$temp_dir/tiles/$x/$y.png")
        done
    done
    montage "${tile_files[@]}" -tile ${TILE_COLS}x${TILE_ROWS} -geometry 1000x1000+0+0 "$temp_dir/stitched.png"

    # Compress to 64 colors (same as your live captures)
    pngquant --quality=80-100 --speed=1 --force 64 "$temp_dir/stitched.png" --output "$temp_dir/compressed.png"

    # Copy to final name and upload
    cp "$temp_dir/compressed.png" "$snapshot_name"
    rclone copy "$snapshot_name" "r2:$R2_BUCKET/"

    # Append to snapshots.json manifest
    local manifest_tmp=$(mktemp)
    local iso_timestamp=$(date -d "${tag_name//world-/}" -Iseconds 2>/dev/null || echo "1970-01-01T00:00:00Z")
    if rclone cat "r2:$R2_BUCKET/snapshots.json" 2>/dev/null > "$manifest_tmp"; then
        jq --arg name "$snapshot_name" --arg ts "$iso_timestamp" '. += [{"filename": $name, "timestamp": $ts}]' "$manifest_tmp" > "$manifest_tmp.new"
    else
        jq -n --arg name "$snapshot_name" --arg ts "$iso_timestamp" '[{"filename": $name, "timestamp": $ts}]' > "$manifest_tmp.new"
    fi
    rclone copy "$manifest_tmp.new" "r2:$R2_BUCKET/snapshots.json"

    echo "  ✓ Successfully processed and uploaded $snapshot_name"
    return 0
}

# ============================
# MAIN EXECUTION
# ============================

# Load or initialise state
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

# Build the complete ordered list of target tags
target_tags=($(build_target_tags))
total_targets=${#target_tags[@]}
echo "Total snapshots to backfill (including already existing): $total_targets"

if [[ $total_targets -eq 0 ]]; then
    echo "No target tags found. Check your date range and GitHub API."
    exit 0
fi

# Find where to resume
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
        rclone copy "$STATE_FILE" "r2:$R2_BUCKET/$R2_STATE_PATH"
    else
        echo "Failed to process $tag – stopping batch to avoid infinite retries."
        break
    fi
done

echo "============================================="
echo "Run finished. Processed $processed_this_run snapshots."
echo "Total processed overall: $processed_count"
if [[ $((start_idx + processed_this_run)) -ge $total_targets ]]; then
    echo "🎉 All target snapshots have been backfilled!"
fi
