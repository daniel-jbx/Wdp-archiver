#!/bin/bash
set -euo pipefail

# ============================
# CONFIGURATION
# ============================
START_DATE="2026-01-10"
END_DATE="2026-05-10"
EXTRA_DATES=("2026-05-26" "2026-05-27" "2026-05-28")

# Special single-snapshot date – exact tag for midnight 2026-05-29
SINGLE_SNAPSHOT_DATE="2026-05-29"
SPECIAL_TAG="world-2026-05-29T00-15-15.367Z"

R2_BUCKET="${R2_BUCKET:-wdp-archiver}"

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
# LOCKING (mutex using R2)
# ============================
LOCK_FILE="backfill.lock"
LOCK_TIMEOUT=3600  # maximum seconds to wait (1 hour)
LOCK_RETRY_INTERVAL=30  # seconds between retries

acquire_lock() {
    local start_time=$(date +%s)
    while true; do
        # Try to create the lock file atomically
        if rclone copyto /dev/null "r2:$R2_BUCKET/$LOCK_FILE" --ignore-existing 2>/dev/null; then
            echo "Lock acquired."
            # Write timestamp into lock file (optional)
            echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | rclone rcat "r2:$R2_BUCKET/$LOCK_FILE" 2>/dev/null || true
            return 0
        fi
        local now=$(date +%s)
        if (( now - start_time >= LOCK_TIMEOUT )); then
            echo "ERROR: Timeout waiting for lock. Exiting."
            exit 1
        fi
        echo "Lock held by another run. Waiting ${LOCK_RETRY_INTERVAL} seconds..."
        sleep $LOCK_RETRY_INTERVAL
    done
}

release_lock() {
    echo "Releasing lock..."
    rclone deletefile "r2:$R2_BUCKET/$LOCK_FILE" 2>/dev/null || true
}

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
    
    # Skip if already exists (check both manifest and bucket)
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
    echo "  Extracted $extracted_count tiles (up to 42). Missing tiles will be transparent."
    
    # Build expected tile files
    local tile_files=()
    for y in $(seq $Y_START $Y_END); do
        for x in $(seq $X_START $X_END); do
            tile_files+=("$temp_dir/tiles/$x/$y.png")
        done
    done
    
    # Create transparent placeholders for missing tiles
    for tf in "${tile_files[@]}"; do
        if [[ ! -f "$tf" ]]; then
            mkdir -p "$(dirname "$tf")"
            convert -size 1000x1000 canvas:transparent PNG32:"$tf"
        fi
    done
    
    # Stitch with transparent background, output as 32‑bit PNG
    montage -background none -alpha on "${tile_files[@]}" \
        -tile ${TILE_COLS}x${TILE_ROWS} \
        -geometry 1000x1000+0+0 \
        PNG32:"$temp_dir/stitched.png"
    
    # Compress to 64 colors, preserving alpha
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
# MAIN – Process one date per run (newest first, no state file)
# ============================

# Acquire lock to prevent concurrent runs
acquire_lock
trap release_lock EXIT

echo "Fetching all releases from GitHub (paginated)..."
all_tags=$(fetch_all_releases)
if [[ -z "$all_tags" ]]; then
    echo "ERROR: No releases found."
    exit 1
fi

total_tags=$(echo "$all_tags" | wc -l)
echo "Fetched $total_tags total releases."

# Group tags by date extracted from tag name
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

# Special date: hardcoded tag for 2026-05-29 midnight
day_tags["$SINGLE_SNAPSHOT_DATE"]="$SPECIAL_TAG|"
echo "Special date $SINGLE_SNAPSHOT_DATE will process only snapshot: $SPECIAL_TAG"

# Get sorted list of dates (newest first)
dates=($(printf '%s\n' "${!day_tags[@]}" | sort -r))
echo "Total unique dates in range: ${#dates[@]}"

# Find the newest date that is NOT fully present in snapshots.json
ensure_valid_manifest
existing_snapshots=$(rclone cat "r2:$R2_BUCKET/snapshots.json" | jq -r '.[]' | sort)

next_date=""
for d in "${dates[@]}"; do
    # Get all expected snapshot names for this date
    IFS='|' read -ra tags <<< "${day_tags[$d]}"
    all_expected=""
    for t in "${tags[@]}"; do
        if [[ -n "$t" ]]; then
            name=$(date_from_tag "$t")
            all_expected+="wdpsnapshot_${name}.png"$'\n'
        fi
    done
    # Check if all expected snapshots already exist in manifest
    missing=0
    while IFS= read -r expected; do
        if [[ -n "$expected" ]] && ! echo "$existing_snapshots" | grep -qxF "$expected"; then
            missing=1
            break
        fi
    done <<< "$all_expected"
    if [[ $missing -eq 1 ]]; then
        next_date="$d"
        break
    fi
done

if [[ -z "$next_date" ]]; then
    echo "All dates in range are already fully processed."
    exit 0
fi

echo "Processing date: $next_date (newest incomplete date)"

# Get tags for this date
IFS='|' read -ra tags <<< "${day_tags[$next_date]}"
# Remove empty elements
tags=(${tags[@]/#/})
# Sort tags descending (newest first) – except special date
if [[ "$next_date" != "$SINGLE_SNAPSHOT_DATE" ]]; then
    IFS=$'\n' tags=($(printf '%s\n' "${tags[@]}" | sort -r))
fi
unset IFS

echo "Found ${#tags[@]} snapshots for $next_date."

# Process each snapshot
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

echo "Processed $success_count / ${#tags[@]} snapshots for $next_date."
if [[ $success_count -eq ${#tags[@]} ]]; then
    echo "✅ Completed date $next_date."
else
    echo "⚠️ Not all snapshots succeeded for $next_date. Rerun will retry the same date."
fi
