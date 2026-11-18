#!/bin/sh
# Fills dev-library/perf/ with 5,000 APFS clones of the dev library's photos and videos under unique names
# (no extra disk space; the sources are never modified), for scrolling and memory checks.
# Needs dev-library/ (scripts/make-dev-library.sh). Never reads ~/Pictures.
# Usage: scripts/make-perf-library.sh [--force]   (--force deletes and rebuilds dev-library/perf/ only)
set -e
cd "$(dirname "$0")/.."
SRC=dev-library
DEST="$SRC/perf"
COUNT=5000
PER_FOLDER=500

if [ ! -d "$SRC" ]; then
  echo "dev-library/ is missing; run scripts/make-dev-library.sh first" >&2
  exit 1
fi
if [ -e "$DEST" ]; then
  if [ "$1" = "--force" ]; then
    rm -rf "$DEST"
  else
    echo "dev-library/perf/ already exists; use --force to rebuild it" >&2
    exit 1
  fi
fi

LIST="$(mktemp)"
trap 'rm -f "$LIST"' EXIT
# Media files outside perf/, excluded folders and packages; empty files are left out.
find "$SRC" \( -path "$DEST" -o -name 'LightCraft Library' -o -name '*.photoslibrary' \) -prune -o \
  -type f -size +0 \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.heic' -o -iname '*.png' -o -iname '*.tif' \
  -o -iname '*.tiff' -o -iname '*.cr2' -o -iname '*.cr3' -o -iname '*.nef' -o -iname '*.arw' -o -iname '*.dng' \
  -o -iname '*.mov' -o -iname '*.mp4' \) -print | sort > "$LIST"
SOURCES=$(wc -l < "$LIST" | tr -d ' ')
if [ "$SOURCES" -eq 0 ]; then
  echo "no photos found in dev-library/" >&2
  exit 1
fi

mkdir -p "$DEST"
i=0
while [ "$i" -lt "$COUNT" ]; do
  while IFS= read -r src && [ "$i" -lt "$COUNT" ]; do
    folder="$DEST/$(printf '%02d' $((i / PER_FOLDER)))"
    [ -d "$folder" ] || mkdir "$folder"
    ext="${src##*.}"
    cp -c "$src" "$folder/P$(printf '%05d' "$i").$ext"
    i=$((i + 1))
  done < "$LIST"
done

echo "dev-library/perf ready: $COUNT files cloned from $SOURCES sources"
