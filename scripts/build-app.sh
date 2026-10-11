#!/bin/zsh
# Builds Grab.app into ./build. Pass --install to copy it to /Applications.
set -euo pipefail
cd "${0:A:h}/.."

INSTALL=""
while (( $# )); do
  case "$1" in
    --install) INSTALL=1; shift ;;
    *) echo "usage: build-app.sh [--install]" >&2; exit 1 ;;
  esac
done
SCRATCH=.build

# Universal binary so it runs on both Apple Silicon and Intel Macs.
MIN_MACOS=14.0
SDK_VERSION="$(xcrun --show-sdk-version)"
# The universal build otherwise stamps the binary with SDK = MIN_MACOS, and macOS then treats
# Grab as an old app: no Liquid Glass window buttons or controls. Record the real SDK.
FLAGS=(--arch arm64 --arch x86_64
       -Xlinker -platform_version -Xlinker macos -Xlinker $MIN_MACOS -Xlinker $SDK_VERSION)
swift build -c release --scratch-path $SCRATCH $FLAGS
BIN="$(swift build -c release --scratch-path $SCRATCH $FLAGS --show-bin-path)"
for arch in arm64 x86_64; do
  STAMP=$(vtool -arch $arch -show-build "$BIN/Grab" | awk '/ sdk /{print $2}')
  [[ "$STAMP" == "$SDK_VERSION" ]] || { echo "Binary ($arch) is stamped with SDK $STAMP, expected $SDK_VERSION" >&2; exit 1; }
done

APP=build/Grab.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Grab" "$APP/Contents/MacOS/Grab"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Translations: compile the String Catalog into <language>.lproj/Localizable.strings.
xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$APP/Contents/Resources" >/dev/null
mkdir -p "$APP/Contents/Resources/en.lproj"   # English is the source language; marks it as available

ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Hardened runtime: blocks code injection (DYLD_* variables, unsigned libraries) into Grab.
codesign --force --options runtime --sign - "$APP"
echo "Built $APP"

if [[ -n "$INSTALL" ]]; then
  rm -rf /Applications/Grab.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Grab.app"
fi
