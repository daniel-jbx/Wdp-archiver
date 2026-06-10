#!/bin/bash
set -euo pipefail

# ============================
# CONFIGURATION
# ============================
START_DATE="2026-01-10"
END_DATE="2026-03-04"
EXTRA_DATES=("")

R2_BUCKET="${R2_BUCKET:-wdp-archiver}"

# WDP (original) – stored at bucket root
WDP_X_START=1225
WDP_X_END=1231
WDP_Y_START=513
WDP_Y_END=518
WDP_TILE_COLS=$((WDP_X_END - WDP_X_START + 1))
WDP_TILE_ROWS=$((WDP_Y_END - WDP_Y_START + 1))

# Antarktika – stored under antarktika/ prefix
ANT_X_START=1279
ANT_X_END=1284
ANT_Y_START=1715
ANT_Y_END=1719
ANT_TILE_COLS=$((ANT_X_END - ANT_X_START + 1))
ANT_TILE_ROWS=$((ANT_Y_END - ANT_Y_START + 1))

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

# Reliable manifest update: download → add → upload (no stdin, no server‑side move)
append_to_manifest() {
    local manifest_path="$1"
    local snapshot_name="$2"
    local tmp_dir=$(mktemp -d)
    local tmp_manifest="$tmp_dir/manifest.json"
    local tmp_new="$tmp_dir/new.json"

    # Download existing manifest or start with empty array
    if ! rclone cat "r2:$R2_BUCKET/$manifest_path" 2>/dev/null > "$tmp_manifest"; then
        echo '[]' > "$tmp_manifest"
    fi

    # Ensure it's a valid JSON array
    if ! jq -e 'type == "array"' "$tmp_manifest" >/dev/null 2>&1; then
        echo '[]' > "$tmp_manifest"
    fi

    # Append new name, deduplicate, and sort
    jq --arg name "$snapshot_name" '. + [$name] | unique | sort' "$tmp_manifest" > "$tmp_new"

    # Upload using file copy (safe for R2)
    rclone copyto "$tmp_new" "r2:$R2_BUCKET/$manifest_path"

    rm -rf "$tmp_dir"
}

# Process WDP (snapshots at root, manifest at root)
process_wdp() {
    local tag_name="$1"
    local tiles_dir="$2"
    local snap_date=$(date_from_tag "$tag_name")
    local snapshot_name="wdpsnapshot_${snap_date}.png"
    echo "  [WDP] $tag_name -> $snapshot_name"

    # Check if already uploaded
    if rclone ls "r2:$R2_BUCKET/" 2>/dev/null | grep -q "$snapshot_name"; then
        echo "  [WDP] Already exists. Updating manifest (just in case)."
        append_to_manifest "snapshots.json" "$snapshot_name"
        return 0
    fi

    local temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    # Collect tile files
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

    montage -background none -alpha on "${tile_files[@]}" \
        -tile ${WDP_TILE_COLS}x${WDP_TILE_ROWS} \
        -geometry 1000x1000+0+0 \
        PNG32:"$temp_dir/stitched.png"

    pngquant --quality=80-100 --speed=1 --force 64 "$temp_dir/stitched.png" --output "$temp_dir/compressed.png"

    rclone copyto "$temp_dir/compressed.png" "r2:$R2_BUCKET/$snapshot_name"

    # Update manifest
    append_to_manifest "snapshots.json" "$snapshot_name"

    echo "  [WDP] ✓ Uploaded $snapshot_name and updated manifest."
    return 0
}

# Process antarktika (snapshots under antarktika/, manifest at antarktika/snapshots.json)
process_antarktika() {
    local tag_name="$1"
    local tiles_dir="$2"
    local snap_date=$(date_from_tag "$tag_name")
    local snapshot_name="antarktika_snapshot_${snap_date}.png"
    echo "  [Antarktika] $tag_name -> antarktika/$snapshot_name"

    if rclone ls "r2:$R2_BUCKET/antarktika/" 2>/dev/null | grep -q "$snapshot_name"; then
        echo "  [Antarktika] Already exists. Updating manifest."
        append_to_manifest "antarktika/snapshots.json" "$snapshot_name"
        return 0
    fi

    local temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    # Collect tile files
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

    montage -background none -alpha on "${tile_files[@]}" \
        -tile ${ANT_TILE_COLS}x${ANT_TILE_ROWS} \
        -geometry 1000x1000+0+0 \
        PNG32:"$temp_dir/stitched.png"

    pngquant --quality=80-100 --speed=1 --force 64 "$temp_dir/stitched.png" --output "$temp_dir/compressed.png"

    rclone copyto "$temp_dir/compressed.png" "r2:$R2_BUCKET/antarktika/$snapshot_name"

    # Update manifest
    append_to_manifest "antarktika/snapshots.json" "$snapshot_name"

    echo "  [Antarktika] ✓ Uploaded $snapshot_name and updated manifest."
    return 0
}

# ============================
# MAIN – Process only the next older date (backwards)
# ============================

# Read and validate state files
last_wdp=""
if rclone cat "r2:$R2_BUCKET/wdp-backfill-state.txt" 2>/dev/null > /tmp/wdp_state; then
    content=$(cat /tmp/wdp_state)
    if [[ -n "$content" && "$content" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        last_wdp="$content"
        echo "WDP state file contains: $last_wdp"
    else
        echo "WDP state file exists but contains invalid/empty data. Ignoring."
    fi
else
    echo "WDP state file not found."
fi

last_ant=""
if rclone cat "r2:$R2_BUCKET/antarktika-backfill-state.txt" 2>/dev/null > /tmp/ant_state; then
    content=$(cat /tmp/ant_state)
    if [[ -n "$content" && "$content" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        last_ant="$content"
        echo "Antarktika state file contains: $last_ant"
    else
        echo "Antarktika state file exists but contains invalid/empty data. Ignoring."
    fi
else
    echo "Antarktika state file not found."
fi

# Fetch all releases
echo "Fetching all releases..."
all_tags=$(fetch_all_releases)
if [[ -z "$all_tags" ]]; then
    echo "ERROR: No releases found."
    exit 1
fi

# Group tags by date and filter by range
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
    echo "No dates in range $START_DATE .. $END_DATE."
    exit 0
fi

# Find the next date to process: the newest date that is older than both last_wdp and last_ant
# (or the newest date if a state is missing).
next_date=""
for d in "${all_dates[@]}"; do
    need=0
    if [[ -z "$last_wdp" || "$d" < "$last_wdp" ]]; then
        need=1
    fi
    if [[ -z "$last_ant" || "$d" < "$last_ant" ]]; then
        need=1
    fi
    if [[ $need -eq 1 ]]; then
        next_date="$d"
        break
    fi
done

if [[ -z "$next_date" ]]; then
    echo "All dates in range are already fully processed for both datasets."
    exit 0
fi

echo "Next date to process: $next_date"

# Determine which datasets still need this date (based on state)
wdp_needed=0
ant_needed=0
if [[ -z "$last_wdp" || "$next_date" < "$last_wdp" ]]; then
    wdp_needed=1
fi
if [[ -z "$last_ant" || "$next_date" < "$last_ant" ]]; then
    ant_needed=1
fi

echo "Processing date: $next_date (WDP needed=$wdp_needed, Ant needed=$ant_needed)"

IFS='|' read -ra tags <<< "${day_tags[$next_date]}"
tags=(${tags[@]/#/})
IFS=$'\n' tags=($(printf '%s\n' "${tags[@]}" | sort -r))
unset IFS

echo "Found ${#tags[@]} snapshots for $next_date."

wdp_success_all=1
ant_success_all=1

for tag in "${tags[@]}"; do
    if [[ -z "$tag" ]]; then
        continue
    fi

    # Determine for this specific tag whether each snapshot already exists
    snap_date=$(date_from_tag "$tag")
    wdp_snapshot="wdpsnapshot_${snap_date}.png"
    ant_snapshot="antarktika_snapshot_${snap_date}.png"
    wdp_exists=0
    ant_exists=0

    if rclone ls "r2:$R2_BUCKET/$wdp_snapshot" &>/dev/null; then
        wdp_exists=1
    fi
    if rclone ls "r2:$R2_BUCKET/antarktika/$ant_snapshot" &>/dev/null; then
        ant_exists=1
    fi

    # If both already exist, skip this tag entirely
    if [[ $wdp_exists -eq 1 && $ant_exists -eq 1 ]]; then
        echo "--- Tag $tag already fully processed (both snapshots exist). Skipping."
        continue
    fi

    echo "--- Processing tag $tag (WDP exists=$wdp_exists, Ant exists=$ant_exists) ---"

    # Build list of tile patterns based on what is missing
    tile_patterns=()
    if [[ $wdp_exists -eq 0 ]]; then
        for x in $(seq $WDP_X_START $WDP_X_END); do
            for y in $(seq $WDP_Y_START $WDP_Y_END); do
                tile_patterns+=("*/$x/$y.png")
            done
        done
    fi
    if [[ $ant_exists -eq 0 ]]; then
        for x in $(seq $ANT_X_START $ANT_X_END); do
            for y in $(seq $ANT_Y_START $ANT_Y_END); do
                tile_patterns+=("*/$x/$y.png")
            done
        done
    fi

    if [[ ${#tile_patterns[@]} -eq 0 ]]; then
        # Should not happen because we already checked both exist
        continue
    fi

    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    # Fetch asset URLs (split tarballs)
    asset_urls=()
    while IFS= read -r url; do
        asset_urls+=("$url")
    done < <(curl -s -L "${AUTH_HEADER[@]}" "https://api.github.com/repos/murolem/wplace-archives/releases/tags/$tag" | jq -r '.assets[].browser_download_url' | grep '\.tar\.gz\.')

    if [[ ${#asset_urls[@]} -eq 0 ]]; then
        echo "  ERROR: No split tarballs found for $tag. Skipping this tag."
        if [[ $wdp_exists -eq 0 ]]; then
            wdp_success_all=0
        fi
        if [[ $ant_exists -eq 0 ]]; then
            ant_success_all=0
        fi
        rm -rf "$temp_dir"
        continue
    fi

    # Extract tiles (only once for all needed patterns)
    if [[ ${#tile_patterns[@]} -gt 0 ]]; then
        mkdir -p "$temp_dir/tiles"
        (
            for url in "${asset_urls[@]}"; do
                curl -L -s --fail "$url"
            done
        ) | tar -xz --strip-components=1 -C "$temp_dir/tiles" --wildcards "${tile_patterns[@]}" 2>/dev/null || true
    fi

    # Process WDP if missing
    if [[ $wdp_exists -eq 0 ]]; then
        if process_wdp "$tag" "$temp_dir/tiles"; then
            echo "  WDP success for $tag"
        else
            wdp_success_all=0
            echo "  WDP failed for $tag"
        fi
    else
        # Already exists, but we should ensure manifest includes it
        append_to_manifest "snapshots.json" "$wdp_snapshot"
    fi

    # Process antarktika if missing
    if [[ $ant_exists -eq 0 ]]; then
        if process_antarktika "$tag" "$temp_dir/tiles"; then
            echo "  Antarktika success for $tag"
        else
            ant_success_all=0
            echo "  Antarktika failed for $tag"
        fi
    else
        append_to_manifest "antarktika/snapshots.json" "$ant_snapshot"
    fi

    rm -rf "$temp_dir"
done

# Update state files only if all tags that needed processing succeeded
if [[ $wdp_needed -eq 1 && $wdp_success_all -eq 1 ]]; then
    echo "$next_date" | rclone rcat "r2:$R2_BUCKET/wdp-backfill-state.txt" 2>/dev/null || true
    echo "✅ WDP state updated to $next_date"
fi
if [[ $ant_needed -eq 1 && $ant_success_all -eq 1 ]]; then
    echo "$next_date" | rclone rcat "r2:$R2_BUCKET/antarktika-backfill-state.txt" 2>/dev/null || true
    echo "✅ Antarktika state updated to $next_date"
fi

echo "Finished processing date $next_date. Exiting (one day per run)."
