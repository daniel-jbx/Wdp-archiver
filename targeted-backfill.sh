#!/bin/bash
set -euo pipefail

# ============================
# CONFIGURATION (TEST PHASE)
# ============================
START_DATE="2026-01-10"
END_DATE="2026-05-11"
EXTRA_DATES=("2026-05-26" "2026-05-27" "2026-05-28")
BATCH_SIZE=1                     # Only one snapshot for debugging
STATE_FILE="backfill-progress.json"
R2_BUCKET="${R2_BUCKET:-wdp-archiver}"
R2_STATE_PATH="backfill-progress.json"

X_START=1225
X_END=1231
Y_START=513
Y_END=518

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

process_release_debug() {
    local tag_name="$1"
    local snap_date=$(date_from_tag "$tag_name")
    local snapshot_name="a_wdpsnapshot_${snap_date}.png"
    
    echo "--- DEBUG: Processing $tag_name -> $snapshot_name"
    
    # Fetch asset URLs
    local asset_urls=()
    while IFS= read -r url; do
        asset_urls+=("$url")
    done < <(curl -s "${AUTH_HEADER[@]}" "https://api.github.com/repos/murolem/wplace-archives/releases/tags/$tag_name" | jq -r '.assets[].browser_download_url' | grep '\.tar\.gz\.')
    
    if [[ ${#asset_urls[@]} -eq 0 ]]; then
        echo "  ERROR: No split tarballs found for $tag_name"
        return 1
    fi
    
    echo "  Downloading and listing first 30 files from the concatenated archive..."
    # Stream all parts, list contents (first 30 lines)
    (
        for url in "${asset_urls[@]}"; do
            curl -s --fail "$url"
        done
    ) | tar -tzf - 2>/dev/null | head -30
    
    echo ""
    echo "  If the listing above is empty, the archive may be corrupted or not a valid tar.gz."
    echo "  If you see paths, please note the directory structure (e.g., '1225/513.png' or 'tiles/1225/513.png')."
    echo "  Then we will adjust the TILE_PATH_PATTERN accordingly."
    
    return 0
}

# ============================
# MAIN
# ============================

# Load state (ignore for debug, start fresh)
echo "Debug mode: will process only the first snapshot and list its contents."

# Fetch all releases
echo "Fetching all releases from GitHub (paginated)..."
all_releases=$(fetch_all_releases)
if [[ -z "$all_releases" ]]; then
    echo "ERROR: No releases found."
    exit 1
fi

total_fetched=$(echo "$all_releases" | wc -l)
echo "Fetched $total_fetched total releases."

# Filter by date range (same as before)
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

# Newest first
IFS=$'\n' target_tags=($(sort -r <<<"${target_tags[*]}"))
unset IFS

total_targets=${#target_tags[@]}
echo "Total snapshots in date range: $total_targets"
if [[ $total_targets -eq 0 ]]; then
    echo "No releases in target date range."
    exit 0
fi

# Take the first snapshot (most recent)
first_tag="${target_tags[0]}"
echo "Processing debug snapshot: $first_tag"
process_release_debug "$first_tag"

echo "Debug complete. Script will now exit without uploading any files."
