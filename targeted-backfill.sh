#!/bin/bash
set -euo pipefail

# ============================
# CONFIGURATION (TEST PHASE)
# ============================
START_DATE="2026-01-10"
END_DATE="2026-05-11"
EXTRA_DATES=("2026-05-26" "2026-05-27" "2026-05-28")
BATCH_SIZE=4                     # Only 4 per run for testing
STATE_FILE="backfill-progress.json"
R2_BUCKET="${R2_BUCKET:-wdp-archiver}"
R2_STATE_PATH="backfill-progress.json"

# Tile range
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
        http_code=$(curl -s -w "%{http_code}" "${AUTH_HEADER[@]}" "$url" -o "$response_file")
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

# Detect tile path by listing a few files from the first asset of a release
detect_tile_path() {
    local tag_name="$1"
    echo "  Detecting tile path structure from $tag_name..."
    local asset_url
    asset_url=$(curl -s "${AUTH_HEADER[@]}" "https://api.github.com/repos/murolem/wplace-archives/releases/tags/$tag_name" | jq -r '.assets[0].browser_download_url')
    if [[ -z "$asset_url" ]]; then
        echo "  ERROR: Cannot fetch asset URL for $tag_name"
        return 1
    fi
    # Download first 2 MB of the first split part
    local sample=$(mktemp)
    curl -s -r 0-2097152 "$asset_url" -o "$sample"
    echo "  Listing first 20 files inside the tarball (this may take a moment)..."
    local paths=$(tar -tzf "$sample" 2>/dev/null | head -20)
    rm "$sample"
    if [[ -z "$paths" ]]; then
        echo "  ERROR: Cannot read tarball contents for $tag_name"
        return 1
    fi
    echo "  Sample paths found:"
    echo "$paths" | sed 's/^/    /'
    
    # Try to guess a pattern that includes numbers (tile coordinates)
    # Look for a line like "1225/513.png" or "tiles/1225/513.png" or "world/1225/513.png"
    local sample_path=$(echo "$paths" | grep -E '[0-9]+/[0-9]+\.png' | head -1)
    if [[ -z "$sample_path" ]]; then
        echo "  ERROR: Could not find any tile path matching pattern {number}/{number}.png"
        echo "  Please inspect the listing above and adjust detection manually."
        return 1
    fi
    
    # Remove the numeric part and .png to get the pattern
    # Example: "tiles/1225/513.png" -> "tiles/%d/%d.png"
    local pattern=$(echo "$sample_path" | sed -E 's/[0-9]+/%d/g' | sed 's/\.png$//')
    TILE_PATH_PATTERN="${pattern}.png"
    echo "  Detected tile path pattern: $TILE_PATH_PATTERN"
    return 0
}

process_release() {
    local tag_name="$1"
    local snap_date=$(date_from_tag "$tag_name")
    # Prefix with a_ for easy deletion
    local snapshot_name="a_wdpsnapshot_${snap_date}.png"
    
    echo "--- Processing $tag_name -> $snapshot_name"
    
    # Skip if already exists in R2 (simple check using rclone ls)
    if rclone ls "r2:$R2_BUCKET/" | grep -q "$snapshot_name"; then
        echo "  Already exists in R2, skipping."
        return 0
    fi
    
    # Detect tile path pattern (only once, using the first release)
    if [[ -z "${TILE_PATH_PATTERN:-}" ]]; then
        if ! detect_tile_path "$tag_name"; then
            echo "  Failed to detect tile pattern. Skipping this snapshot."
            return 1
        fi
    fi
    
    # Build the list of expected tile paths
    local tile_paths=()
    for x in $(seq $X_START $X_END); do
        for y in $(seq $Y_START $Y_END); do
            local path
            path=$(printf "$TILE_PATH_PATTERN" "$x" "$y")
            tile_paths+=("$path")
        done
    done
    
    local temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN
    
    # Fetch asset URLs (split tarballs)
    local asset_urls=()
    while IFS= read -r url; do
        asset_urls+=("$url")
    done < <(curl -s "${AUTH_HEADER[@]}" "https://api.github.com/repos/murolem/wplace-archives/releases/tags/$tag_name" | jq -r '.assets[].browser_download_url' | grep '\.tar\.gz\.')
    
    if [[ ${#asset_urls[@]} -eq 0 ]]; then
        echo "  ERROR: No split tarballs found for $tag_name"
        return 1
    fi
    
    mkdir -p "$temp_dir/tiles"
    # Extract only the needed tiles
    (
        for url in "${asset_urls[@]}"; do
            curl -s --fail "$url"
        done
    ) | tar -xz -C "$temp_dir/tiles" --wildcards "${tile_paths[@]}" 2>/dev/null || true
    
    # Count extracted tiles
    extracted_count=$(find "$temp_dir/tiles" -name "*.png" | wc -l)
    if [[ $extracted_count -eq 0 ]]; then
        echo "  ERROR: No tiles extracted (pattern may be wrong). Skipping."
        echo "  Expected pattern: $TILE_PATH_PATTERN"
        echo "  To debug, you can manually examine a release tarball."
        return 1
    fi
    echo "  Extracted $extracted_count tiles (expected 42)."
    
    # Build montage command with discovered paths
    local tile_files=()
    for y in $(seq $Y_START $Y_END); do
        for x in $(seq $X_START $X_END); do
            local path
            path=$(printf "$TILE_PATH_PATTERN" "$x" "$y")
            tile_files+=("$temp_dir/tiles/$path")
        done
    done
    
    # Create missing tiles as transparent placeholders
    for tf in "${tile_files[@]}"; do
        if [[ ! -f "$tf" ]]; then
            mkdir -p "$(dirname "$tf")"
            convert -size 1000x1000 xc:none "$tf"
        fi
    done
    
    montage "${tile_files[@]}" -tile ${TILE_COLS}x${TILE_ROWS} -geometry 1000x1000+0+0 "$temp_dir/stitched.png"
    pngquant --quality=80-100 --speed=1 --force 64 "$temp_dir/stitched.png" --output "$temp_dir/compressed.png"
    
    # Upload to R2 with the 'a_' prefix
    rclone copyto "$temp_dir/compressed.png" "r2:$R2_BUCKET/$snapshot_name"
    
    echo "  ✓ Successfully uploaded $snapshot_name (no manifest update)"
    return 0
}

# ============================
# MAIN
# ============================

# Load state
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

# Fetch all releases
echo "Fetching all releases from GitHub (paginated)..."
all_releases=$(fetch_all_releases)
if [[ -z "$all_releases" ]]; then
    echo "ERROR: No releases found."
    exit 1
fi

total_fetched=$(echo "$all_releases" | wc -l)
echo "Fetched $total_fetched total releases."

# Filter by date range
target_tags=()
while IFS=$'|' read -r tag published; do
    pub_date="${published:0:10}"
    if [[ "$pub_date" > "$START_DATE" || "$pub_date" == "$START_DATE" ]] && \
       [[ "$pub_date" < "$END_DATE" || "$pub_date" == "$END_DATE" ]]; then
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

# Sort **NEWEST FIRST** (reverse chronological)
IFS=$'\n' target_tags=($(sort -r <<<"${target_tags[*]}"))
unset IFS

total_targets=${#target_tags[@]}
echo "Total snapshots in date range: $total_targets"
if [[ $total_targets -eq 0 ]]; then
    echo "No releases in target date range."
    exit 0
fi

# Find where to resume (based on last_processed, which is also newest first)
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

# Process up to BATCH_SIZE (4)
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
