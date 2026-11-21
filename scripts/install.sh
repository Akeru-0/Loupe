#!/bin/sh
# Builds the release app and installs it as /Applications/Loupe.app (quitting a running Loupe first), then opens it.
# For this Mac. Other Macs install from GitHub Releases and update themselves (scripts/release.sh).
set -e
cd "$(dirname "$0")/.."
BUILD=$(git rev-list --count HEAD) scripts/bundle.sh release
osascript -e 'tell application id "local.loupe.Loupe" to quit' 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Loupe >/dev/null || break; sleep 1; done
rm -rf /Applications/Loupe.app
ditto build/Loupe.app /Applications/Loupe.app
echo "Installed /Applications/Loupe.app"
open /Applications/Loupe.app
