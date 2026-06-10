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

# Reliable manifest update: download → add → upload
append_to_manifest() {
    local manifest_path="$1"
    local snapshot_name="$2"
    local tmp_dir=$(mktemp -d)
    local tmp_manifest="$tmp_dir/manifest.json"
    local tmp_new="$tmp_dir/new.json"

    if ! rclone cat "r2:$R2_BUCKET/$manifest_path" 2>/dev/null > "$tmp_manifest"; then
        echo '[]' > "$tmp_manifest"
    fi
    if ! jq -e 'type == "array"' "$tmp_manifest" >/dev/null 2>&1; then
        echo '[]' > "$tmp_manifest"
    fi
    jq --arg name "$snapshot_name" '. + [$name] | unique | sort' "$tmp_manifest" > "$tmp_new"
    rclone copyto "$tmp_new" "r2:$R2_BUCKET/$manifest_path"
    rm -rf "$tmp_dir"
}

# Reliable state file write (content -> temp file -> copyto)
write_state_file() {
    local state_path="$1"
    local content="$2"
    local tmp_file=$(mktemp)
    echo "$content" > "$tmp_file"
    rclone copyto "$tmp_file" "r2:$R2_BUCKET/$state_path"
    rm -f "$tmp_file"
}

# Process WDP (snapshots at root, manifest at root)
process_wdp() {
    local tag_name="$1"
    local tiles_dir="$2"
    local snap_date=$(date_from_tag "$tag_name")
    local snapshot_name="wdpsnapshot_${snap_date}.png"
    echo "  [WDP] $tag_name -> $snapshot_name"

    if rclone stat "r2:$R2_BUCKET/$snapshot_name" &>/dev/null; then
        echo "  [WDP] Already exists. Updating manifest."
        append_to_manifest "snapshots.json" "$snapshot_name"
        return 0
    fi

    local temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    local tile_files=()
    for y in $(seq $WDP_Y_START $WDP_Y_END); do
        for x in $(seq $WDP_X_START $WDP_X_END); do
            tile_files+=("$tiles_dir/$x/$y.png")
        done
    done

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
    append_to_manifest "snapshots.json" "$snapshot_name"

    echo "  [WDP] ✓ Uploaded $snapshot_name"
    return 0
}

# Process antarktika (snapshots under antarktika/, manifest at antarktika/snapshots.json)
process_antarktika() {
    local tag_name="$1"
    local tiles_dir="$2"
    local snap_date=$(date_from_tag "$tag_name")
    local snapshot_name="antarktika_snapshot_${snap_date}.png"
    echo "  [Antarktika] $tag_name -> antarktika/$snapshot_name"

    if rclone stat "r2:$R2_BUCKET/antarktika/$snapshot_name" &>/dev/null; then
        echo "  [Antarktika] Already exists. Updating manifest."
        append_to_manifest "antarktika/snapshots.json" "$snapshot_name"
        return 0
    fi

    local temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    local tile_files=()
    for y in $(seq $ANT_Y_START $ANT_Y_END); do
        for x in $(seq $ANT_X_START $ANT_X_END); do
            tile_files+=("$tiles_dir/$x/$y.png")
        done
    done

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
    append_to_manifest "antarktika/snapshots.json" "$snapshot_name"

    echo "  [Antarktika] ✓ Uploaded $snapshot_name"
    return 0
}

# ============================
# MAIN
# ============================

# Read state files (using rclone cat, which works for reading)
last_wdp=""
if rclone cat "r2:$R2_BUCKET/wdp-backfill-state.txt" 2>/dev/null > /tmp/wdp_state; then
    content=$(cat /tmp/wdp_state)
    if [[ -n "$content" && "$content" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        last_wdp="$content"
        echo "WDP state: $last_wdp"
    else
        echo "WDP state invalid, ignoring."
    fi
else
    echo "WDP state not found."
fi

last_ant=""
if rclone cat "r2:$R2_BUCKET/antarktika-backfill-state.txt" 2>/dev/null > /tmp/ant_state; then
    content=$(cat /tmp/ant_state)
    if [[ -n "$content" && "$content" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        last_ant="$content"
        echo "Antarktika state: $last_ant"
    else
        echo "Antarktika state invalid, ignoring."
    fi
else
    echo "Antarktika state not found."
fi

# Fetch all releases
echo "Fetching releases..."
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

all_dates=($(printf '%s\n' "${!day_tags[@]}" | sort -r))

if [[ ${#all_dates[@]} -eq 0 ]]; then
    echo "No dates in range."
    exit 0
fi

# Find the next date older than last completed (or newest if no state)
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
    echo "All dates processed."
    exit 0
fi

echo "Next date: $next_date"

wdp_needed=0
ant_needed=0
[[ -z "$last_wdp" || "$next_date" < "$last_wdp" ]] && wdp_needed=1
[[ -z "$last_ant" || "$next_date" < "$last_ant" ]] && ant_needed=1
echo "Processing $next_date (WDP=$wdp_needed, Ant=$ant_needed)"

IFS='|' read -ra tags <<< "${day_tags[$next_date]}"
tags=(${tags[@]/#/})
IFS=$'\n' tags=($(printf '%s\n' "${tags[@]}" | sort -r))
unset IFS

echo "Found ${#tags[@]} tags"

wdp_success_all=1
ant_success_all=1

for tag in "${tags[@]}"; do
    [[ -z "$tag" ]] && continue

    snap_date=$(date_from_tag "$tag")
    wdp_snapshot="wdpsnapshot_${snap_date}.png"
    ant_snapshot="antarktika_snapshot_${snap_date}.png"

    wdp_exists=0
    ant_exists=0
    rclone stat "r2:$R2_BUCKET/$wdp_snapshot" &>/dev/null && wdp_exists=1
    rclone stat "r2:$R2_BUCKET/antarktika/$ant_snapshot" &>/dev/null && ant_exists=1

    echo "--- Tag $tag: WDP exists=$wdp_exists, Ant exists=$ant_exists ---"

    if [[ $wdp_exists -eq 1 && $ant_exists -eq 1 ]]; then
        echo "  Both snapshots already exist. Skipping tag."
        continue
    fi

    # Build tile patterns for missing ones
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

    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    asset_urls=()
    while IFS= read -r url; do
        asset_urls+=("$url")
    done < <(curl -s -L "${AUTH_HEADER[@]}" "https://api.github.com/repos/murolem/wplace-archives/releases/tags/$tag" | jq -r '.assets[].browser_download_url' | grep '\.tar\.gz\.')

    if [[ ${#asset_urls[@]} -eq 0 ]]; then
        echo "  ERROR: No split tarballs for $tag"
        [[ $wdp_exists -eq 0 ]] && wdp_success_all=0
        [[ $ant_exists -eq 0 ]] && ant_success_all=0
        rm -rf "$temp_dir"
        continue
    fi

    mkdir -p "$temp_dir/tiles"
    (
        for url in "${asset_urls[@]}"; do
            curl -L -s --fail "$url"
        done
    ) | tar -xz --strip-components=1 -C "$temp_dir/tiles" --wildcards "${tile_patterns[@]}" 2>/dev/null || true

    if [[ $wdp_exists -eq 0 ]]; then
        if process_wdp "$tag" "$temp_dir/tiles"; then
            echo "  WDP success"
        else
            wdp_success_all=0
            echo "  WDP failed"
        fi
    else
        append_to_manifest "snapshots.json" "$wdp_snapshot"
    fi

    if [[ $ant_exists -eq 0 ]]; then
        if process_antarktika "$tag" "$temp_dir/tiles"; then
            echo "  Antarktika success"
        else
            ant_success_all=0
            echo "  Antarktika failed"
        fi
    else
        append_to_manifest "antarktika/snapshots.json" "$ant_snapshot"
    fi

    rm -rf "$temp_dir"
done

# Update state files using reliable write_state_file function
if [[ $wdp_needed -eq 1 && $wdp_success_all -eq 1 ]]; then
    write_state_file "wdp-backfill-state.txt" "$next_date"
    echo "✅ WDP state -> $next_date"
fi
if [[ $ant_needed -eq 1 && $ant_success_all -eq 1 ]]; then
    write_state_file "antarktika-backfill-state.txt" "$next_date"
    echo "✅ Antarktika state -> $next_date"
fi

echo "Finished date $next_date. Exiting."
