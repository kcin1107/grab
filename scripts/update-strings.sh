#!/bin/zsh
# Refreshes Resources/Localizable.xcstrings from the code: the compiler extracts every localizable
# string (SwiftUI text and String(localized:)), and xcstringstool merges them into the catalog,
# keeping existing translations and marking strings that are no longer used as stale.
set -euo pipefail
cd "${0:A:h}/.."
DERIVED_DATA="$PWD/build/DerivedData"
xcodebuild -project Grab.xcodeproj -scheme Grab -configuration Debug \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED_DATA" \
  SWIFT_EMIT_LOC_STRINGS=YES build >/dev/null
STRINGS_DATA=("$DERIVED_DATA"/Build/Intermediates.noindex/Grab.build/Debug/Grab.build/Objects-normal/arm64/*.stringsdata(N))
(( ${#STRINGS_DATA} )) || { echo "No extracted localization strings found" >&2; exit 1; }
[[ -f Resources/Localizable.xcstrings ]] || echo '{"sourceLanguage":"en","strings":{},"version":"1.0"}' > Resources/Localizable.xcstrings
xcrun xcstringstool sync Resources/Localizable.xcstrings --stringsdata "${STRINGS_DATA[@]}"
echo "Updated Resources/Localizable.xcstrings"
