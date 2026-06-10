#!/bin/bash
set -euo pipefail

# ============================
# CONFIGURATION
# ============================
START_DATE="2026-01-10"
END_DATE="2026-04-11"
EXTRA_DATES=("")

R2_BUCKET="${R2_BUCKET:-wdp-archiver}"
STATE_FILE="backfill-state.txt"

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
        while IFS= read -r tag; do
            all_entries+=("$tag")
        done < <(jq -r '.[].tag_name' "$response_file")
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
    local tmp_manifest=$(mktemp)
    if rclone cat "r2:$R2_BUCKET/snapshots.json" 2>/dev/null > "$tmp_manifest"; then
        if ! jq -e 'type == "array"' "$tmp_manifest" >/dev/null 2>&1; then
            echo "WARNING: snapshots.json corrupted. Resetting to empty array."
            echo '[]' | rclone copyto - "r2:$R2_BUCKET/snapshots.json"
        fi
    else
        echo '[]' | rclone copyto - "r2:$R2_BUCKET/snapshots.json"
    fi
    rm -f "$tmp_manifest"
}

process_release() {
    local tag_name="$1"
    if [[ -z "$tag_name" ]]; then
        echo "  ERROR: Empty tag name provided."
        return 1
    fi
    local snap_date=$(date_from_tag "$tag_name")
    local snapshot_name="wdpsnapshot_${snap_date}.png"
    
    echo "--- Processing $tag_name -> $snapshot_name"
    
    ensure_valid_manifest
    if rclone cat "r2:$R2_BUCKET/snapshots.json" | jq -r '.[]' | grep -qx "$snapshot_name"; then
        echo "  Already in snapshots.json, skipping."
        return 0
    fi
    if rclone ls "r2:$R2_BUCKET/" | grep -q "$snapshot_name"; then
        echo "  File already exists in R2 (but not in manifest). Adding to manifest and skipping."
        local manifest_tmp=$(mktemp)
        rclone cat "r2:$R2_BUCKET/snapshots.json" > "$manifest_tmp"
        jq --arg name "$snapshot_name" '. += [$name]' "$manifest_tmp" > "$manifest_tmp.new"
        rclone copyto "$manifest_tmp.new" "r2:$R2_BUCKET/snapshots.json"
        return 0
    fi
    
    local temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN
    
    local asset_urls=()
    while IFS= read -r url; do
        asset_urls+=("$url")
    done < <(curl -s -L "${AUTH_HEADER[@]}" "https://api.github.com/repos/murolem/wplace-archives/releases/tags/$tag_name" | jq -r '.assets[].browser_download_url' | grep '\.tar\.gz\.')
    
    if [[ ${#asset_urls[@]} -eq 0 ]]; then
        echo "  ERROR: No split tarballs found for $tag_name"
        return 1
    fi
    
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
    echo "  Extracted $extracted_count tiles (up to 42). Missing tiles will be transparent."
    
    local tile_files=()
    for y in $(seq $Y_START $Y_END); do
        for x in $(seq $X_START $X_END); do
            tile_files+=("$temp_dir/tiles/$x/$y.png")
        done
    done
    
    for tf in "${tile_files[@]}"; do
        if [[ ! -f "$tf" ]]; then
            mkdir -p "$(dirname "$tf")"
            convert -size 1000x1000 canvas:transparent PNG32:"$tf"
        fi
    done
    
    montage -background none -alpha on "${tile_files[@]}" \
        -tile ${TILE_COLS}x${TILE_ROWS} \
        -geometry 1000x1000+0+0 \
        PNG32:"$temp_dir/stitched.png"
    
    pngquant --quality=80-100 --speed=1 --force 64 "$temp_dir/stitched.png" --output "$temp_dir/compressed.png"
    
    rclone copyto "$temp_dir/compressed.png" "r2:$R2_BUCKET/$snapshot_name"
    
    local manifest_tmp=$(mktemp)
    rclone cat "r2:$R2_BUCKET/snapshots.json" > "$manifest_tmp"
    jq --arg name "$snapshot_name" '. += [$name]' "$manifest_tmp" > "$manifest_tmp.new"
    rclone copyto "$manifest_tmp.new" "r2:$R2_BUCKET/snapshots.json"
    
    echo "  ✓ Successfully uploaded $snapshot_name and updated snapshots.json"
    return 0
}

# ============================
# MAIN – State-based progression (newest to oldest)
# ============================

# Read last completed date from state file
if rclone cat "r2:$R2_BUCKET/$STATE_FILE" 2>/dev/null > /tmp/state; then
    last_done=$(cat /tmp/state)
else
    last_done=""
fi
echo "Last completed date: ${last_done:-none}"

# Fetch all tags and group by date
echo "Fetching all releases..."
all_tags=$(fetch_all_releases)
if [[ -z "$all_tags" ]]; then
    echo "ERROR: No releases found."
    exit 1
fi

declare -A day_tags
for tag in $all_tags; do
    tag_date=$(echo "$tag" | sed -n 's/^world-\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\).*$/\1/p')
    if [[ -z "$tag_date" ]]; then
        continue
    fi
    if [[ ( "$tag_date" > "$START_DATE" || "$tag_date" == "$START_DATE" ) && ( "$tag_date" < "$END_DATE" || "$tag_date" == "$END_DATE" ) ]]; then
        day_tags["$tag_date"]+="$tag|"
    else
        for extra in "${EXTRA_DATES[@]}"; do
            if [[ "$tag_date" == "$extra" ]]; then
                day_tags["$tag_date"]+="$tag|"
                break
            fi
        done
    fi
done

# Get all dates sorted newest first
all_dates=($(printf '%s\n' "${!day_tags[@]}" | sort -r))

if [[ ${#all_dates[@]} -eq 0 ]]; then
    echo "No dates in range."
    exit 0
fi

# Determine next date to process: the next older date after last_done
next_date=""
if [[ -z "$last_done" ]]; then
    # Start from the newest date
    next_date="${all_dates[0]}"
else
    # Find the date that is the next older than last_done
    for d in "${all_dates[@]}"; do
        if [[ "$d" < "$last_done" ]]; then
            next_date="$d"
            break
        fi
    done
fi

if [[ -z "$next_date" ]]; then
    echo "All dates processed (no date older than $last_done)."
    exit 0
fi

echo "Processing date: $next_date"

# Get tags for this date
IFS='|' read -ra tags <<< "${day_tags[$next_date]}"
tags=(${tags[@]/#/})  # remove empties
# Sort tags descending (newest first) within the day
IFS=$'\n' tags=($(printf '%s\n' "${tags[@]}" | sort -r))
unset IFS

echo "Found ${#tags[@]} snapshots for $next_date."

# Process all snapshots for this date
success_count=0
for tag in "${tags[@]}"; do
    if [[ -z "$tag" ]]; then
        continue
    fi
    if process_release "$tag"; then
        success_count=$((success_count + 1))
    else
        echo "Failed to process $tag. Stopping day."
        break
    fi
done

if [[ $success_count -eq ${#tags[@]} ]]; then
    # Update state file with this date
    echo "$next_date" | rclone rcat "r2:$R2_BUCKET/$STATE_FILE"
    echo "✅ Completed date $next_date. State updated."
else
    echo "⚠️ Not all snapshots succeeded. State not updated. Rerun will retry same date."
fi
