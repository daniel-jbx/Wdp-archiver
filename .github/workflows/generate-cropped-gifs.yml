name: Generate Cropped GIFs

on:
  workflow_dispatch:   # manual trigger

jobs:
  gifs:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - name: Checkout assets branch
        uses: actions/checkout@v4
        with:
          ref: assets

      - name: Install ImageMagick
        run: sudo apt-get update && sudo apt-get install -y imagemagick

      - name: Run cropped GIF generation
        run: bash generate-cropped-gifs.sh

      - name: Commit updated GIFs to assets
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
