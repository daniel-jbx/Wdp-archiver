#!/bin/bash
set -euo pipefail

# ============================
# CONFIGURATION
# ============================
START_DATE="2026-01-10"
END_DATE="2026-03-04"
EXTRA_DATES=("")

R2_BUCKET="${R2_BUCKET:-wdp-archiver}"
R2_ENDPOINT="${R2_ENDPOINT:-}"
R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-}"
R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-}"

# Validate required R2 credentials
if [[ -z "$R2_ENDPOINT" || -z "$R2_ACCESS_KEY_ID" || -z "$R2_SECRET_ACCESS_KEY" ]]; then
    echo "ERROR: R2_ENDPOINT, R2_ACCESS_KEY_ID, and R2_SECRET_ACCESS_KEY must be set."
    exit 1
fi

# WDP (original) – stored at bucket root
WDP_X_START=1225
WDP_X_END=1231
WDP_Y_START=513
WDP_Y_END=518

# Antarktika – stored under antarktika/ prefix
ANT_X_START=1279
ANT_X_END=1284
ANT_Y_START=1715
ANT_Y_END=1719

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

# Common R2 flags
R2_FLAGS=(
    --s3-endpoint="$R2_ENDPOINT"
    --s3-access-key-id="$R2_ACCESS_KEY_ID"
    --s3-secret-access-key="$R2_SECRET_ACCESS_KEY"
    --s3-region="auto"
)

# ============================
# FUNCTIONS
# ============================

# Fetch a URL with retries on 5xx errors
fetch_with_retry() {
    local url="$1"
    local max_retries=3
    local retry_delay=2
    local attempt=1
    local response_file=$(mktemp)
    local http_code

    while [[ $attempt -le $max_retries ]]; do
        http_code=$(curl -s -w "%{http_code}" -L "${AUTH_HEADER[@]}" "$url" -o "$response_file")
        if [[ "$http_code" == "200" ]]; then
            cat "$response_file"
            rm "$response_file"
            return 0
        elif [[ "$http_code" -ge 500 && "$http_code" -le 599 ]]; then
            echo "WARNING: HTTP $http_code on attempt $attempt/$max_retries. Retrying in ${retry_delay}s..." >&2
            sleep $retry_delay
            retry_delay=$((retry_delay * 2))
            ((attempt++))
        else
            echo "ERROR: HTTP $http_code (non‑retryable)." >&2
            rm "$response_file"
            return 1
        fi
    done
    echo "ERROR: Failed to fetch $url after $max_retries attempts." >&2
    rm "$response_file"
    return 1
}

fetch_all_releases() {
    local page=1
    local all_entries=()
    while true; do
        echo "Fetching releases page $page..." >&2
        local url="https://api.github.com/repos/murolem/wplace-archives/releases?page=$page&per_page=100"
        local response
        if ! response=$(fetch_with_retry "$url"); then
            echo "WARNING: Could not fetch page $page. Stopping pagination." >&2
            break
        fi
        if ! jq -e 'type == "array" and length > 0' <<<"$response" >/dev/null 2>&1; then
            echo "No more releases (page $page empty)." >&2
            break
        fi
        while IFS= read -r tag; do
            all_entries+=("$tag")
        done < <(jq -r '.[].tag_name' <<<"$response")
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

# For WDP: manifest is at root "snapshots.json"
ensure_wdp_manifest() {
    local tmp_manifest=$(mktemp)
    if rclone cat ":s3:$R2_BUCKET/snapshots.json" "${R2_FLAGS[@]}" 2>/dev/null > "$tmp_manifest"; then
        if ! jq -e 'type == "array"' "$tmp_manifest" >/dev/null 2>&1; then
            echo "WARNING: WDP snapshots.json corrupted. Resetting to empty array."
            echo '[]' | rclone copyto - ":s3:$R2_BUCKET/snapshots.json" "${R2_FLAGS[@]}" || exit 1
        fi
    else
        # File does not exist – create empty array
        echo '[]' | rclone copyto - ":s3:$R2_BUCKET/snapshots.json" "${R2_FLAGS[@]}" || exit 1
    fi
    rm -f "$tmp_manifest"
}

# For antarktika: manifest is at "antarktika/snapshots.json"
ensure_antarktika_manifest() {
    local tmp_manifest=$(mktemp)
    if rclone cat ":s3:$R2_BUCKET/antarktika/snapshots.json" "${R2_FLAGS[@]}" 2>/dev/null > "$tmp_manifest"; then
        if ! jq -e 'type == "array"' "$tmp_manifest" >/dev/null 2>&1; then
            echo "WARNING: antarktika snapshots.json corrupted. Resetting to empty array."
            echo '[]' | rclone copyto - ":s3:$R2_BUCKET/antarktika/snapshots.json" "${R2_FLAGS[@]}" || exit 1
        fi
    else
        echo '[]' | rclone copyto - ":s3:$R2_BUCKET/antarktika/snapshots.json" "${R2_FLAGS[@]}" || exit 1
    fi
    rm -f "$tmp_manifest"
}

process_wdp() {
    local tag_name="$1"
    local tiles_dir="$2"

    local snap_date=$(date_from_tag "$tag_name")
    local snapshot_name="wdpsnapshot_${snap_date}.png"

    echo "  [WDP] Processing $tag_name -> $snapshot_name"

    ensure_wdp_manifest

    # Skip if already in manifest
    if rclone cat ":s3:$R2_BUCKET/snapshots.json" "${R2_FLAGS[@]}" 2>/dev/null | jq -r '.[]' | grep -qx "$snapshot_name"; then
        echo "  [WDP] Already in manifest, skipping."
        return 0
    fi

    # Skip if file exists but not in manifest (fix manifest)
    if rclone ls ":s3:$R2_BUCKET/" "${R2_FLAGS[@]}" 2>/dev/null | grep -q "$snapshot_name"; then
        echo "  [WDP] File exists but not in manifest. Adding to manifest."
        local manifest_tmp=$(mktemp)
        rclone cat ":s3:$R2_BUCKET/snapshots.json" "${R2_FLAGS[@]}" > "$manifest_tmp" 2>/dev/null
        jq --arg name "$snapshot_name" '. += [$name]' "$manifest_tmp" > "$manifest_tmp.new"
        rclone copyto "$manifest_tmp.new" ":s3:$R2_BUCKET/snapshots.json" "${R2_FLAGS[@]}" || exit 1
        return 0
    fi

    local temp_dir=$(mktemp -d)

    # Collect tile files for WDP
    local tile_files=()
    for y in $(seq $WDP_Y_START $WDP_Y_END); do
        for x in $(seq $WDP_X_START $WDP_X_END); do
            tile_files+=("$tiles_dir/$x/$y.png")
        done
    done

    # Create missing tiles as transparent 1000x1000 PNGs
    for tf in "${tile_files[@]}"; do
        if [[ ! -f "$tf" ]]; then
            mkdir -p "$(dirname "$tf")"
            convert -size 1000x1000 canvas:transparent PNG32:"$tf"
        fi
    done

    local cols=$((WDP_X_END - WDP_X_START + 1))
    local rows=$((WDP_Y_END - WDP_Y_START + 1))

    montage -background none -alpha on "${tile_files[@]}" \
        -tile ${cols}x${rows} \
        -geometry 1000x1000+0+0 \
        PNG32:"$temp_dir/stitched.png"

    pngquant --quality=80-100 --speed=1 --force 64 "$temp_dir/stitched.png" --output "$temp_dir/compressed.png"

    rclone copyto "$temp_dir/compressed.png" ":s3:$R2_BUCKET/$snapshot_name" "${R2_FLAGS[@]}" || exit 1

    # Update manifest
    local manifest_tmp=$(mktemp)
    rclone cat ":s3:$R2_BUCKET/snapshots.json" "${R2_FLAGS[@]}" > "$manifest_tmp" 2>/dev/null
    jq --arg name "$snapshot_name" '. += [$name]' "$manifest_tmp" > "$manifest_tmp.new"
    rclone copyto "$manifest_tmp.new" ":s3:$R2_BUCKET/snapshots.json" "${R2_FLAGS[@]}" || exit 1

    rm -rf "$temp_dir"
    echo "  [WDP] ✓ Uploaded $snapshot_name and updated manifest."
    return 0
}

process_antarktika() {
    local tag_name="$1"
    local tiles_dir="$2"

    local snap_date=$(date_from_tag "$tag_name")
    local snapshot_name="antarktika_snapshot_${snap_date}.png"

    echo "  [Antarktika] Processing $tag_name -> $snapshot_name"

    ensure_antarktika_manifest

    # Skip if already in manifest
    if rclone cat ":s3:$R2_BUCKET/antarktika/snapshots.json" "${R2_FLAGS[@]}" 2>/dev/null | jq -r '.[]' | grep -qx "$snapshot_name"; then
        echo "  [Antarktika] Already in manifest, skipping."
        return 0
    fi

    # Skip if file exists but not in manifest (fix manifest)
    if rclone ls ":s3:$R2_BUCKET/antarktika/" "${R2_FLAGS[@]}" 2>/dev/null | grep -q "$snapshot_name"; then
        echo "  [Antarktika] File exists but not in manifest. Adding to manifest."
        local manifest_tmp=$(mktemp)
        rclone cat ":s3:$R2_BUCKET/antarktika/snapshots.json" "${R2_FLAGS[@]}" > "$manifest_tmp" 2>/dev/null
        jq --arg name "$snapshot_name" '. += [$name]' "$manifest_tmp" > "$manifest_tmp.new"
        rclone copyto "$manifest_tmp.new" ":s3:$R2_BUCKET/antarktika/snapshots.json" "${R2_FLAGS[@]}" || exit 1
        return 0
    fi

    local temp_dir=$(mktemp -d)

    # Collect tile files for antarktika
    local tile_files=()
    for y in $(seq $ANT_Y_START $ANT_Y_END); do
        for x in $(seq $ANT_X_START $ANT_X_END); do
            tile_files+=("$tiles_dir/$x/$y.png")
        done
    done

    # Create missing tiles as transparent 1000x1000 PNGs
    for tf in "${tile_files[@]}"; do
        if [[ ! -f "$tf" ]]; then
            mkdir -p "$(dirname "$tf")"
            convert -size 1000x1000 canvas:transparent PNG32:"$tf"
        fi
    done

    local cols=$((ANT_X_END - ANT_X_START + 1))
    local rows=$((ANT_Y_END - ANT_Y_START + 1))

    montage -background none -alpha on "${tile_files[@]}" \
        -tile ${cols}x${rows} \
        -geometry 1000x1000+0+0 \
        PNG32:"$temp_dir/stitched.png"

    pngquant --quality=80-100 --speed=1 --force 64 "$temp_dir/stitched.png" --output "$temp_dir/compressed.png"

    rclone copyto "$temp_dir/compressed.png" ":s3:$R2_BUCKET/antarktika/$snapshot_name" "${R2_FLAGS[@]}" || exit 1

    # Update manifest
    local manifest_tmp=$(mktemp)
    rclone cat ":s3:$R2_BUCKET/antarktika/snapshots.json" "${R2_FLAGS[@]}" > "$manifest_tmp" 2>/dev/null
    jq --arg name "$snapshot_name" '. += [$name]' "$manifest_tmp" > "$manifest_tmp.new"
    rclone copyto "$manifest_tmp.new" ":s3:$R2_BUCKET/antarktika/snapshots.json" "${R2_FLAGS[@]}" || exit 1

    rm -rf "$temp_dir"
    echo "  [Antarktika] ✓ Uploaded $snapshot_name and updated manifest."
    return 0
}

# ============================
# MAIN – Process only ONE date (newest not fully done)
# ============================

# Read last completed dates for each dataset from R2
last_wdp=""
if rclone cat ":s3:$R2_BUCKET/wdp-backfill-state.txt" "${R2_FLAGS[@]}" 2>/dev/null > /tmp/wdp_state; then
    last_wdp=$(cat /tmp/wdp_state)
fi
last_ant=""
if rclone cat ":s3:$R2_BUCKET/antarktika-backfill-state.txt" "${R2_FLAGS[@]}" 2>/dev/null > /tmp/ant_state; then
    last_ant=$(cat /tmp/ant_state)
fi
echo "Last completed WDP date: ${last_wdp:-none}"
echo "Last completed Antarktika date: ${last_ant:-none}"

# Fetch all releases
echo "Fetching all releases..."
all_tags=$(fetch_all_releases)
if [[ -z "$all_tags" ]]; then
    echo "ERROR: No releases found."
    exit 1
fi

total_count=$(echo "$all_tags" | wc -l)
echo "Total releases fetched: $total_count"

# Show debug info
if [[ $total_count -gt 0 ]]; then
    echo "First 3 tags:"
    echo "$all_tags" | sed -n '1,3p'
    echo "Last 3 tags:"
    echo "$all_tags" | sed -n "$((total_count-2)),${total_count}p"
fi
echo "Years present in tags:"
echo "$all_tags" | sed -n 's/^world-\([0-9]\{4\}\).*/\1/p' | sort -u

# Group by date within range
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

# Get dates sorted newest first
all_dates=($(printf '%s\n' "${!day_tags[@]}" | sort -r))

if [[ ${#all_dates[@]} -eq 0 ]]; then
    echo "No dates in range $START_DATE .. $END_DATE."
    exit 0
fi

# Find the first (newest) date that needs processing for either dataset
for current_date in "${all_dates[@]}"; do
    wdp_needed=0
    ant_needed=0
    if [[ -z "$last_wdp" || "$current_date" > "$last_wdp" ]]; then
        wdp_needed=1
    fi
    if [[ -z "$last_ant" || "$current_date" > "$last_ant" ]]; then
        ant_needed=1
    fi
    if [[ $wdp_needed -eq 0 && $ant_needed -eq 0 ]]; then
        echo "Date $current_date already fully processed. Skipping."
        continue
    fi

    echo "Processing date: $current_date (WDP needed=$wdp_needed, Ant needed=$ant_needed)"

    IFS='|' read -ra tags <<< "${day_tags[$current_date]}"
    tags=(${tags[@]/#/})
    IFS=$'\n' tags=($(printf '%s\n' "${tags[@]}" | sort -r))
    unset IFS

    echo "Found ${#tags[@]} snapshots for $current_date."

    wdp_success_all=1
    ant_success_all=1

    for tag in "${tags[@]}"; do
        if [[ -z "$tag" ]]; then
            continue
        fi

        echo "--- Processing tag $tag ---"

        temp_dir=$(mktemp -d)

        # Fetch asset URLs (split tarballs)
        asset_urls=()
        while IFS= read -r url; do
            asset_urls+=("$url")
        done < <(curl -s -L "${AUTH_HEADER[@]}" "https://api.github.com/repos/murolem/wplace-archives/releases/tags/$tag" | jq -r '.assets[].browser_download_url' | grep '\.tar\.gz\.')

        if [[ ${#asset_urls[@]} -eq 0 ]]; then
            echo "  ERROR: No split tarballs found for $tag. Skipping this tag for both datasets."
            wdp_success_all=0
            ant_success_all=0
            rm -rf "$temp_dir"
            continue
        fi

        # Build tile patterns for needed areas
        tile_patterns=()
        if [[ $wdp_needed -eq 1 ]]; then
            for x in $(seq $WDP_X_START $WDP_X_END); do
                for y in $(seq $WDP_Y_START $WDP_Y_END); do
                    tile_patterns+=("*/$x/$y.png")
                done
            done
        fi
        if [[ $ant_needed -eq 1 ]]; then
            for x in $(seq $ANT_X_START $ANT_X_END); do
                for y in $(seq $ANT_Y_START $ANT_Y_END); do
                    tile_patterns+=("*/$x/$y.png")
                done
            done
        fi

        if [[ ${#tile_patterns[@]} -gt 0 ]]; then
            mkdir -p "$temp_dir/tiles"
            (
                for url in "${asset_urls[@]}"; do
                    curl -L -s --fail "$url"
                done
            ) | tar -xz --strip-components=1 -C "$temp_dir/tiles" --wildcards "${tile_patterns[@]}" 2>/dev/null || true
        fi

        # Process WDP if needed
        if [[ $wdp_needed -eq 1 ]]; then
            if process_wdp "$tag" "$temp_dir/tiles"; then
                echo "  WDP success for $tag"
            else
                wdp_success_all=0
                echo "  WDP failed for $tag"
            fi
        fi

        # Process antarktika if needed
        if [[ $ant_needed -eq 1 ]]; then
            if process_antarktika "$tag" "$temp_dir/tiles"; then
                echo "  Antarktika success for $tag"
            else
                ant_success_all=0
                echo "  Antarktika failed for $tag"
            fi
        fi

        rm -rf "$temp_dir"
    done

    # Update state files if fully successful
    if [[ $wdp_needed -eq 1 && $wdp_success_all -eq 1 ]]; then
        echo "$current_date" | rclone rcat ":s3:$R2_BUCKET/wdp-backfill-state.txt" "${R2_FLAGS[@]}" || exit 1
        echo "✅ WDP state updated to $current_date"
    fi
    if [[ $ant_needed -eq 1 && $ant_success_all -eq 1 ]]; then
        echo "$current_date" | rclone rcat ":s3:$R2_BUCKET/antarktika-backfill-state.txt" "${R2_FLAGS[@]}" || exit 1
        echo "✅ Antarktika state updated to $current_date"
    fi

    # Stop after this date (even if some parts failed)
    echo "Finished processing date $current_date. Exiting (one day per run)."
    exit 0
done

echo "All dates in range are already fully processed. Nothing to do."
