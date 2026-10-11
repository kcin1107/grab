#!/bin/zsh
# Publishes a release: ./scripts/release.sh 1.1.0 ["What changed"]
# Builds Grab, packages a .dmg, commits the version bump, tags it, pushes, and creates the
# GitHub release.
set -euo pipefail
cd "${0:A:h}/.."

VERSION="${1:?usage: release.sh <version> [notes]}"
CHANGES="${2:-}"
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first." >&2; exit 1; }
git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "v$VERSION already exists." >&2; exit 1; }

PLIST=Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(( $(git rev-list --count HEAD) + 1 ))" "$PLIST"

rm -rf dist && mkdir dist
./scripts/build-app.sh

# A disk image with Grab and a shortcut to Applications.
STAGE=build/dmg
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R build/Grab.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp scripts/dmg-readme.txt "$STAGE/Read Me First.txt"
hdiutil create -quiet -volname "Grab $VERSION" -srcfolder "$STAGE" -ov -format UDZO dist/Grab.dmg

git add "$PLIST"
git commit -q -m "Release $VERSION"
git tag "v$VERSION"
git push -q origin HEAD --tags
gh release create "v$VERSION" dist/Grab.dmg \
  --title "Grab $VERSION" --notes "$CHANGES"
echo "Released $VERSION"
