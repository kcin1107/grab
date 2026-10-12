#!/bin/zsh
# Builds Grab.app into ./build. Pass --install to copy it to /Applications.
set -euo pipefail
cd "${0:A:h:h}"

INSTALL=""
while (( $# )); do
  case "$1" in
    --install) INSTALL=1; shift ;;
    *) echo "usage: build-app.sh [--install]" >&2; exit 1 ;;
  esac
done
DERIVED_DATA="$PWD/build/DerivedData"
xcodebuild -project Grab.xcodeproj -scheme Grab -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED_DATA" build

APP=build/Grab.app
rm -rf "$APP"
ditto "$DERIVED_DATA/Build/Products/Release/Grab.app" "$APP"

# Hardened runtime: blocks code injection (DYLD_* variables, unsigned libraries) into Grab.
codesign --force --options runtime --sign - "$APP"
echo "Built $APP"

if [[ -n "$INSTALL" ]]; then
  rm -rf /Applications/Grab.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Grab.app"
fi
