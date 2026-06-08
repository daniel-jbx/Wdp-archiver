#!/bin/bash
set -euo pipefail

# ============================
# CONFIGURATION
# ============================
START_DATE="2026-01-10"
END_DATE="2026-05-11"
EXTRA_DATES=("2026-05-26" "2026-05-27" "2026-05-28")
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

ensure_valid_manifest() {
    # Ensure snapshots.json exists and is an array of strings.
    local tmp_manifest=$(mktemp)
    if rclone cat "r2:$R2_BUCKET/snapshots.json" 2>/dev/null > "$tmp_manifest"; then
        if ! jq -e 'type == "array"' "$tmp_manifest" >/dev/null 2>&1; then
            echo "  WARNING: snapshots.json corrupted. Resetting to empty array."
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
    
    # Skip if filename already in manifest (plain string check)
    ensure_valid_manifest
    if rclone cat "r2:$R2_BUCKET/snapshots.json" | jq -r '.[]' | grep -qx "$snapshot_name"; then
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
    (
        for url in "${asset_urls[@]}"; do
            curl -L -s --fail "$url"
        done
    ) | tar -xz --strip-components=1 -C "$temp_dir/tiles" --wildcards "${tile_patterns[@]}" 2>/dev/null || true
    
    extracted_count=$(find "$temp_dir/tiles" -name "*.png" 2>/dev/null | wc -l)
    echo "  Extracted $extracted_count tiles (up to 42). Missing tiles → placeholders."
    
    local tile_files=()
    for y in $(seq $Y_START $Y_END); do
        for x in $(seq $X_START $X_END); do
            tile_files+=("$temp_dir/tiles/$x/$y.png")
        done
    done
    
    for tf in "${tile_files[@]}"; do
        if [[ ! -f "$tf" ]]; then
            mkdir -p "$(dirname "$tf")"
            convert -size 1000x1000 xc:none "$tf"
        fi
    done
    
    montage "${tile_files[@]}" -tile ${TILE_COLS}x${TILE_ROWS} -geometry 1000x1000+0+0 "$temp_dir/stitched.png"
    pngquant --quality=80-100 --speed=1 --force 64 "$temp_dir/stitched.png" --output "$temp_dir/compressed.png"
    
    rclone copyto "$temp_dir/compressed.png" "r2:$R2_BUCKET/$snapshot_name"
    
    # Append filename to snapshots.json (plain string)
    local manifest_tmp=$(mktemp)
    rclone cat "r2:$R2_BUCKET/snapshots.json" > "$manifest_tmp"
    jq --arg name "$snapshot_name" '. += [$name]' "$manifest_tmp" > "$manifest_tmp.new"
    rclone copyto "$manifest_tmp.new" "r2:$R2_BUCKET/snapshots.json"
    
    echo "  ✓ Successfully uploaded $snapshot_name and updated snapshots.json"
    return 0
}

# ============================
# MAIN – Process one entire day (all snapshots for a single date)
# ============================

if rclone cat "r2:$R2_BUCKET/$R2_STATE_PATH" 2>/dev/null > "$STATE_FILE"; then
    last_processed_date=$(jq -r '.last_processed_date' "$STATE_FILE")
    processed_count=$(jq -r '.processed_count' "$STATE_FILE")
else
    last_processed_date=""
    processed_count=0
    echo '{"last_processed_date": "", "processed_count": 0}' > "$STATE_FILE"
fi

echo "Last processed date: ${last_processed_date:-none}"
echo "Total days processed: $processed_count"

echo "Fetching all releases from GitHub (paginated)..."
all_releases=$(fetch_all_releases)
if [[ -z "$all_releases" ]]; then
    echo "ERROR: No releases found."
    exit 1
fi

total_fetched=$(echo "$all_releases" | wc -l)
echo "Fetched $total_fetched total releases."

# Build list of (date, tag) pairs for the target range
declare -A day_tags
while IFS=$'|' read -r tag published; do
    pub_date="${published:0:10}"
    # Check if date is in main range or extra dates
    if [[ ( "$pub_date" > "$START_DATE" || "$pub_date" == "$START_DATE" ) && ( "$pub_date" < "$END_DATE" || "$pub_date" == "$END_DATE" ) ]]; then
        day_tags["$pub_date"]+="$tag|"
    else
        for extra in "${EXTRA_DATES[@]}"; do
            if [[ "$pub_date" == "$extra" ]]; then
                day_tags["$pub_date"]+="$tag|"
                break
            fi
        done
    fi
done <<< "$all_releases"

# Get sorted list of dates (newest first)
dates=($(printf '%s\n' "${!day_tags[@]}" | sort -r))
total_dates=${#dates[@]}
echo "Total dates in range: $total_dates"

if [[ $total_dates -eq 0 ]]; then
    echo "No dates found in target range."
    exit 0
fi

# Find next date to process (after last_processed_date)
next_date=""
for d in "${dates[@]}"; do
    if [[ -z "$last_processed_date" || "$d" < "$last_processed_date" ]]; then
        next_date="$d"
        break
    fi
done

if [[ -z "$next_date" ]]; then
    echo "All dates have been processed."
    exit 0
fi

echo "Processing all snapshots for date: $next_date"

# Get all tags for this date
IFS='|' read -ra tags <<< "${day_tags[$next_date]}"
# Sort tags chronologically (oldest first within the day – order doesn't matter much)
IFS=$'\n' tags=($(printf '%s\n' "${tags[@]}" | sort))
unset IFS

echo "Found ${#tags[@]} snapshots for $next_date."

# Process each snapshot for this date
success_count=0
for tag in "${tags[@]}"; do
    if process_release "$tag"; then
        success_count=$((success_count + 1))
    else
        echo "Failed to process $tag. Stopping day."
        break
    fi
done

echo "Processed $success_count / ${#tags[@]} snapshots for $next_date."

# Update state
if [[ $success_count -eq ${#tags[@]} ]]; then
    processed_count=$((processed_count + 1))
    jq --arg date "$next_date" --argjson cnt "$processed_count" \
        '.last_processed_date = $date | .processed_count = $cnt' "$STATE_FILE" > "$STATE_FILE.tmp"
    mv "$STATE_FILE.tmp" "$STATE_FILE"
    rclone copyto "$STATE_FILE" "r2:$R2_BUCKET/$R2_STATE_PATH"
    echo "✅ Completed date $next_date."
else
    echo "⚠️ Not all snapshots succeeded for $next_date. State not updated. Rerun will retry same date."
fi

echo "============================================="
