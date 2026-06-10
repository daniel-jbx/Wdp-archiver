#!/bin/bash
set -euo pipefail

# ============================
# CONFIGURATION
# ============================
START_DATE="2026-01-10"
END_DATE="2026-04-11"
EXTRA_DATES=("")

R2_BUCKET="${R2_BUCKET:-wdp-archiver}"

# WDP (original)
WDP_X_START=1225
WDP_X_END=1231
WDP_Y_START=513
WDP_Y_END=518

# Antarktika
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
    local dataset="$1"   # "wdp" or "antarktika"
    local prefix="${dataset}/"
    local tmp_manifest=$(mktemp)
    if rclone cat "r2:$R2_BUCKET/${prefix}snapshots.json" 2>/dev/null > "$tmp_manifest"; then
        if ! jq -e 'type == "array"' "$tmp_manifest" >/dev/null 2>&1; then
            echo "WARNING: $dataset snapshots.json corrupted. Resetting to empty array."
            echo '[]' | rclone copyto - "r2:$R2_BUCKET/${prefix}snapshots.json"
        fi
    else
        echo '[]' | rclone copyto - "r2:$R2_BUCKET/${prefix}snapshots.json"
    fi
    rm -f "$tmp_manifest"
}

process_dataset() {
    local dataset="$1"       # "wdp" or "antarktika"
    local x_start="$2"
    local x_end="$3"
    local y_start="$4"
    local y_end="$5"
    local tag_name="$6"
    local tiles_dir="$7"     # directory containing extracted tile subdirs (*/x/y.png)

    local snap_date=$(date_from_tag "$tag_name")
    local snapshot_name="${dataset}_snapshot_${snap_date}.png"
    local prefix="${dataset}/"
    local state_file="${dataset}-backfill-state.txt"

    echo "  [$dataset] Processing $tag_name -> $snapshot_name"

    ensure_valid_manifest "$dataset"

    # Skip if snapshot already in manifest
    if rclone cat "r2:$R2_BUCKET/${prefix}snapshots.json" | jq -r '.[]' | grep -qx "$snapshot_name"; then
        echo "  [$dataset] Already in manifest, skipping."
        return 0
    fi
    # Skip if file exists but not in manifest (fix manifest)
    if rclone ls "r2:$R2_BUCKET/${prefix}" | grep -q "$snapshot_name"; then
        echo "  [$dataset] File exists but not in manifest. Adding to manifest."
        local manifest_tmp=$(mktemp)
        rclone cat "r2:$R2_BUCKET/${prefix}snapshots.json" > "$manifest_tmp"
        jq --arg name "$snapshot_name" '. += [$name]' "$manifest_tmp" > "$manifest_tmp.new"
        rclone copyto "$manifest_tmp.new" "r2:$R2_BUCKET/${prefix}snapshots.json"
        return 0
    fi

    local temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    # Collect tile files for this dataset
    local tile_files=()
    for y in $(seq "$y_start" "$y_end"); do
        for x in $(seq "$x_start" "$x_end"); do
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

    local cols=$((x_end - x_start + 1))
    local rows=$((y_end - y_start + 1))

    montage -background none -alpha on "${tile_files[@]}" \
        -tile ${cols}x${rows} \
        -geometry 1000x1000+0+0 \
        PNG32:"$temp_dir/stitched.png"

    pngquant --quality=80-100 --speed=1 --force 64 "$temp_dir/stitched.png" --output "$temp_dir/compressed.png"

    rclone copyto "$temp_dir/compressed.png" "r2:$R2_BUCKET/${prefix}$snapshot_name"

    # Update manifest
    local manifest_tmp=$(mktemp)
    rclone cat "r2:$R2_BUCKET/${prefix}snapshots.json" > "$manifest_tmp"
    jq --arg name "$snapshot_name" '. += [$name]' "$manifest_tmp" > "$manifest_tmp.new"
    rclone copyto "$manifest_tmp.new" "r2:$R2_BUCKET/${prefix}snapshots.json"

    echo "  [$dataset] ✓ Uploaded $snapshot_name and updated manifest."
    return 0
}

# ============================
# MAIN – Process both datasets together
# ============================

# Read last completed dates for each dataset
last_wdp=""
if rclone cat "r2:$R2_BUCKET/wdp-backfill-state.txt" 2>/dev/null > /tmp/wdp_state; then
    last_wdp=$(cat /tmp/wdp_state)
fi
last_ant=""
if rclone cat "r2:$R2_BUCKET/antarktika-backfill-state.txt" 2>/dev/null > /tmp/ant_state; then
    last_ant=$(cat /tmp/ant_state)
fi
echo "Last completed WDP date: ${last_wdp:-none}"
echo "Last completed Antarktika date: ${last_ant:-none}"

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

# Determine the next date to process for each dataset independently
# We'll iterate over dates from newest to oldest, but only process a date
# if at least one dataset hasn't completed it yet.

for current_date in "${all_dates[@]}"; do
    wdp_needed=0
    ant_needed=0
    if [[ -z "$last_wdp" || "$current_date" < "$last_wdp" ]]; then
        wdp_needed=1
    fi
    if [[ -z "$last_ant" || "$current_date" < "$last_ant" ]]; then
        ant_needed=1
    fi
    if [[ $wdp_needed -eq 0 && $ant_needed -eq 0 ]]; then
        echo "Date $current_date already fully processed (both datasets)."
        continue
    fi

    echo "Processing date: $current_date (WDP needed=$wdp_needed, Ant needed=$ant_needed)"

    IFS='|' read -ra tags <<< "${day_tags[$current_date]}"
    tags=(${tags[@]/#/})  # remove empties
    # Sort tags descending (newest first) within the day
    IFS=$'\n' tags=($(printf '%s\n' "${tags[@]}" | sort -r))
    unset IFS

    echo "Found ${#tags[@]} snapshots for $current_date."

    # Process each tag of this date
    wdp_success_all=1
    ant_success_all=1

    for tag in "${tags[@]}"; do
        if [[ -z "$tag" ]]; then
            continue
        fi

        echo "--- Processing tag $tag ---"

        # ---- Download and extract tiles once for both datasets ----
        local temp_dir=$(mktemp -d)
        trap "rm -rf '$temp_dir'" RETURN

        # Fetch asset URLs (split tarballs)
        local asset_urls=()
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

        # Build tile patterns for both areas
        local tile_patterns=()
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
            if process_dataset "wdp" $WDP_X_START $WDP_X_END $WDP_Y_START $WDP_Y_END "$tag" "$temp_dir/tiles"; then
                echo "  WDP success for $tag"
            else
                wdp_success_all=0
                echo "  WDP failed for $tag"
            fi
        fi

        # Process antarktika if needed
        if [[ $ant_needed -eq 1 ]]; then
            if process_dataset "antarktika" $ANT_X_START $ANT_X_END $ANT_Y_START $ANT_Y_END "$tag" "$temp_dir/tiles"; then
                echo "  Antarktika success for $tag"
            else
                ant_success_all=0
                echo "  Antarktika failed for $tag"
            fi
        fi

        rm -rf "$temp_dir"
    done

    # After processing all tags of the date, update state files for datasets that succeeded fully
    if [[ $wdp_needed -eq 1 && $wdp_success_all -eq 1 ]]; then
        echo "$current_date" | rclone rcat "r2:$R2_BUCKET/wdp-backfill-state.txt"
        echo "✅ WDP state updated to $current_date"
    fi
    if [[ $ant_needed -eq 1 && $ant_success_all -eq 1 ]]; then
        echo "$current_date" | rclone rcat "r2:$R2_BUCKET/antarktika-backfill-state.txt"
        echo "✅ Antarktika state updated to $current_date"
    fi
done

echo "Backfill completed."
