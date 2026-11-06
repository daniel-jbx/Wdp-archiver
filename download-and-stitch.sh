#!/bin/bash
set -euo pipefail

# ---- CONFIGURE YOUR TILE RANGE ----
START_COL=1224  # leftmost column (X)
START_ROW=513   # topmost row (Y)
END_COL=1231    # rightmost column (X)
END_ROW=519     # bottommost row (Y)
# -----------------------------------

BASE_URL="https://backend.wplace.live/files/s0/tiles"
TILE_DIR="tiles"
OUTPUT="output.png"
TILE=1000

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
      python3 -c "from PIL import Image; Image.new('RGBA', ($TILE, $TILE), (0, 0, 0, 0)).save('$filename')"
    fi
    sleep 0.2   # gentle delay (5 req/sec ~ 0.2s per request)
  done
done

echo "Stitching tiles..."

# PIL-based stitch: replaces `montage` from ImageMagick.
# Row-major paste order matches the previous -tile COLSxROWS layout.
python3 << PYEOF
import sys
from PIL import Image

START_COL = $START_COL
START_ROW = $START_ROW
END_COL   = $END_COL
END_ROW   = $END_ROW
TILE      = $TILE
COLS      = END_COL - START_COL + 1
ROWS      = END_ROW - START_ROW + 1

print(f"Grid: {COLS} cols x {ROWS} rows = {COLS*TILE}x{ROWS*TILE} pixels")

grid = Image.new('RGBA', (COLS * TILE, ROWS * TILE), (0, 0, 0, 0))

for row_idx, row in enumerate(range(START_ROW, END_ROW + 1)):
    for col_idx, col in enumerate(range(START_COL, END_COL + 1)):
        path = f'tiles/{col}_{row}.png'
        try:
            tile = Image.open(path).convert('RGBA')
        except Exception as e:
            print(f"ERROR: cannot open {path}: {e}", file=sys.stderr)
            sys.exit(1)
        if tile.size != (TILE, TILE):
            print(f"WARN: {path} is {tile.size}, resizing to ({TILE},{TILE})", file=sys.stderr)
            tile = tile.resize((TILE, TILE), Image.NEAREST)
        grid.paste(tile, (col_idx * TILE, row_idx * TILE))

grid.save('$OUTPUT')
print(f"Wrote $OUTPUT ({grid.size[0]}x{grid.size[1]})")
PYEOF

echo "Stitching complete: $OUTPUT"
