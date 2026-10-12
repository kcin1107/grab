#!/bin/zsh
# Builds Grab.app into ./build. Pass --install to copy it to /Applications, and --sign "<identity>"
# to sign it with a Developer ID (with a secure timestamp, as notarization needs) instead of ad hoc.
set -euo pipefail
cd "${0:A:h:h}"

INSTALL=""
IDENTITY="-"
while (( $# )); do
  case "$1" in
    --install) INSTALL=1; shift ;;
    --sign) IDENTITY="$2"; shift 2 ;;
    *) echo "usage: build-app.sh [--install] [--sign <identity>]" >&2; exit 1 ;;
  esac
done
DERIVED_DATA="$PWD/build/DerivedData"
xcodebuild -project Grab.xcodeproj -scheme Grab -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED_DATA" build

APP=build/Grab.app
rm -rf "$APP"
ditto "$DERIVED_DATA/Build/Products/Release/Grab.app" "$APP"

# Hardened runtime: blocks code injection (DYLD_* variables, unsigned libraries) into Grab.
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --options runtime --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
echo "Built $APP"

if [[ -n "$INSTALL" ]]; then
  rm -rf /Applications/Grab.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Grab.app"
fi
