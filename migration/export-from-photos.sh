#!/bin/bash
# Exports the Apple Photos library into a folder tree with XMP sidecars.
# Usage: migration/export-from-photos.sh <destination> [extra osxphotos args…]
# Re-runnable: --update only exports what is new or changed since the last run.
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -ge 1 ] || { echo "usage: $0 <destination> [osxphotos args…]" >&2; exit 2; }
DEST="$1"; shift
REPORT="${REPORT:-migration/export-report-$(date +%Y%m%d-%H%M%S).csv}"
mkdir -p "$DEST"
exec osxphotos export "$DEST" \
  --directory "{created.year}/{created.year}-{created.mm}-{created.dd}" \
  --sidecar XMP --sidecar-drop-ext --edited-suffix "-edited" \
  --keyword-template "{favorite?Favorite,}" --keyword-template "Albums|{folder_album}" \
  --update --report "$REPORT" \
  "$@"
