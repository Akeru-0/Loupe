#!/bin/sh
# Builds dev-library/ from APFS clones of sample photos in ~/Pictures (no extra
# disk space; originals are never modified) plus synthetic edge cases.
# Usage: scripts/make-dev-library.sh [--force]
set -e
cd "$(dirname "$0")/.."
SRC="$HOME/Pictures"
DEST=dev-library

if [ -e "$DEST" ]; then
  if [ "$1" = "--force" ]; then
    rm -rf "$DEST"
  else
    echo "dev-library/ already exists; use --force to rebuild it" >&2
    exit 1
  fi
fi
mkdir -p "$DEST"

# APFS clones of real samples (cp -c = clonefile).
cp -c -R "$SRC/Photos iceland" "$DEST/"
cp -c -R "$SRC/Screan shots:recording" "$DEST/"
for f in eby.jpg eby.xmp IMG_2174.CR2 IMG_2174.xmp kocka1.jpg memoji.jpg; do
  cp -c "$SRC/$f" "$DEST/"
done

# Synthetic edge cases.
cp -c "$DEST/Photos iceland/IMG_9744.JPG" "$DEST/Photos iceland/IMG_9744-edited.jpg"  # edit version
: > "$DEST/broken.jpg"                                                              # 0-byte image
mkdir -p "$DEST/Test.photoslibrary" && cp -c "$SRC/kocka1.jpg" "$DEST/Test.photoslibrary/x.jpg"  # package: skipped
mkdir -p "$DEST/LightCraft Library/thumbs" && cp -c "$SRC/kocka1.jpg" "$DEST/LightCraft Library/thumbs/t.jpg"  # excluded
cp -c "$SRC/kocka2.jpg" "$DEST/$(printf 'Z\314\214lut\314\214ouc\314\214ky\314\201.JPG')"  # NFD name "Žluťoučký"

echo "dev-library ready: $(find "$DEST" -type f | wc -l | tr -d ' ') files"
