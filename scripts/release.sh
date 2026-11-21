#!/bin/sh
# Publishes a Loupe release that installed copies update to (Sparkle):
#   builds the release app, signs it (the "Loupe" certificate), zips it, signs the zip with the Sparkle key in this
#   Mac's keychain, writes the update feed (appcast.xml) and publishes both as GitHub release v<version>.
# Usage: scripts/release.sh 0.2.0 ["What's new, one line per item"]
#
# Once per Mac, before the first release:
#   - Sparkle's tools: they're downloaded into .tools/ by this script.
#   - The update key: .tools/sparkle/bin/generate_keys --account loupe   (its public key is in Info.plist)
#   - The signing certificate: Keychain Access ▸ Certificate Assistant ▸ Create a Certificate…, Name "Loupe",
#     Identity Type "Self Signed Root", Certificate Type "Code Signing". Signing every release with it keeps
#     permissions like Full Disk Access across updates.
set -e
cd "$(dirname "$0")/.."
VERSION="$1"
NOTES="$2"
REPO=Akeru-0/Loupe
SPARKLE=2.10.1
[ -n "$VERSION" ] || { echo "usage: scripts/release.sh <version> [notes]" >&2; exit 1; }
TAG="v$VERSION"

# Only what's on GitHub's main is released.
[ "$(git branch --show-current)" = main ] || { echo "release from main" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "commit or stash your changes first" >&2; exit 1; }
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "push main first (git push)" >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then echo "$TAG already exists" >&2; exit 1; fi

if [ ! -x .tools/sparkle/bin/sign_update ]; then
  mkdir -p .tools/sparkle
  gh release download "$SPARKLE" -R sparkle-project/Sparkle -p "Sparkle-$SPARKLE.tar.xz" -D .tools --clobber
  tar -xf ".tools/Sparkle-$SPARKLE.tar.xz" -C .tools/sparkle
fi

BUILD=$(git rev-list --count HEAD)  # always grows on main: Sparkle compares it
VERSION="$VERSION" BUILD="$BUILD" scripts/bundle.sh release

ZIP="build/Loupe-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/Loupe.app "$ZIP"
SIGNATURE=$(.tools/sparkle/bin/sign_update --account loupe "$ZIP")  # sparkle:edSignature="…" length="…"

PREVIOUS=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [ -z "$NOTES" ]; then
  if [ -n "$PREVIOUS" ]; then
    NOTES=$(git log --no-merges --format='%s' "$PREVIOUS"..HEAD)
  else
    NOTES="First release."
  fi
fi
ITEMS=$(printf '%s\n' "$NOTES" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/^/<li>/' -e 's/$/<\/li>/')

cat > build/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Loupe</title>
    <item>
      <title>Loupe $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<ul>$ITEMS</ul>]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/Loupe-$VERSION.zip" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
EOF

git tag -a "$TAG" -m "Loupe $VERSION"
git push -q origin "$TAG"
printf '%s\n' "$NOTES" | sed 's/^/- /' > build/release-notes.md
gh release create "$TAG" "$ZIP" build/appcast.xml -R "$REPO" --title "Loupe $VERSION" --notes-file build/release-notes.md
echo "Released Loupe $VERSION (build $BUILD). Installed copies will offer it on their next check."
