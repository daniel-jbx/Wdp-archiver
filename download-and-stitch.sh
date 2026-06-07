#!/bin/bash
set -euo pipefail

# ---- CONFIGURE YOUR TILE RANGE ----
START_COL=1225  # leftmost column (X)
START_ROW=513   # topmost row (Y)
END_COL=1231    # rightmost column (X)
END_ROW=518     # bottommost row (Y)
# -----------------------------------

BASE_URL="https://backend.wplace.live/files/s0/tiles"
TILE_DIR="tiles"
OUTPUT="output.png"

mkdir -p "$TILE_DIR"

echo "Downloading tiles from ($START_COL,$START_ROW) to ($END_COL,$END_ROW)..."

for (( col=START_COL; col<=END_COL; col++ )); do
  for (( row=START_ROW; row<=END_ROW; row++ )); do
    url="${BASE_URL}/${col}/${row}.png"
    filename="${TILE_DIR}/${col}_${row}.png"
    echo "  -> $url"
    if ! curl -sSf --retry 2 "$url" -o "$filename"; then
      # Create a fully transparent placeholder if the tile does not exist
      echo "  Tile $url does not exist, using transparent placeholder"
      convert -size 1000x1000 xc:none "$filename"
    fi
    sleep 0.2   # gentle delay (5 req/sec ~ 0.2s per request)
  done
done

echo "Stitching tiles..."
# Build a file list for montage in the correct order (row-major)
FILELIST=""
for (( row=START_ROW; row<=END_ROW; row++ )); do
  for (( col=START_COL; col<=END_COL; col++ )); do
    FILELIST+="${TILE_DIR}/${col}_${row}.png "
  done
done

# Montage with transparent background → full RGBA PNG
montage $FILELIST \
  -background none \
  -geometry 1000x1000+0+0 \
  -tile $((END_COL-START_COL+1))x$((END_ROW-START_ROW+1)) \
  PNG32:"$OUTPUT"

echo "Stitching complete: $OUTPUT"
