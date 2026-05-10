name: Generate Cropped GIFs

on:
  workflow_dispatch:   # manual trigger

jobs:
  gifs:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      # 1. Get the script & config from the main branch
      - name: Checkout main branch (scripts)
        uses: actions/checkout@v4
        with:
          ref: main
          path: _main   # placed in subdirectory _main

      # 2. Get the snapshot files from the assets branch
      - name: Checkout assets branch (snapshots)
        uses: actions/checkout@v4
        with:
          ref: assets
          path: current   # placed in subdirectory current

      # 3. Copy script and config into the snapshot workspace
      - name: Copy script and config
        run: |
          cp _main/generate-cropped-gifs.sh current/
          cp _main/crops.txt current/

      - name: Install ImageMagick
        run: sudo apt-get update && sudo apt-get install -y imagemagick

      - name: Run cropped GIF generation
        working-directory: current
        run: bash generate-cropped-gifs.sh

      - name: Commit updated GIFs to assets
        working-directory: current
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git add *.gif
          if ! git diff --cached --quiet; then
            git commit -m "Update cropped GIFs (${GITHUB_RUN_NUMBER})"
            git push origin assets
          else
            echo "No changes to GIFs"
          fi
