#!/bin/zsh
# Notarizes build/Grab.app (signed with --sign) and staples the ticket, then zips it as build/Grab.zip.
# Needs notarytool credentials in the keychain, stored once with
#   xcrun notarytool store-credentials grab-notary --apple-id <Apple ID> --team-id <Team ID>
set -euo pipefail
cd "${0:A:h:h}"

APP=build/Grab.app
ZIP=build/Grab.zip
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "${NOTARY_PROFILE:-grab-notary}" --wait
xcrun stapler staple "$APP"
# Zip again so the download carries the stapled ticket and opens without a network check.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose "$APP"
echo "Notarized $ZIP"
