#!/bin/zsh
# Archive VerseLoop and export for TestFlight (App Store distribution).
# One-time setup: put your 10-char Team ID into scripts/ExportOptions.plist
# (or archive from Xcode Organizer instead — no script needed).
# Every upload needs a NEW build number: bump CURRENT_PROJECT_VERSION first.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ASC_KEY_ID:=UJN8FGCNSD}"
: "${ASC_ISSUER_ID:=0f2ee42a-6766-49de-9547-64bf521d2762}"
: "${ASC_KEY_PATH:=$HOME/AuthKey_UJN8FGCNSD.p8}"
ARCHIVE="build/VerseLoop.xcarchive"
xcodebuild archive \
  -project VerseLoop.xcodeproj -scheme VerseLoop \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=KRF39C6NC9 \
  CODE_SIGN_IDENTITY="Apple Distribution" \
  PROVISIONING_PROFILE_SPECIFIER="VerseLoop AppStore" \
  OTHER_CODE_SIGN_FLAGS="--keychain /tmp/vl.keychain-db"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist scripts/ExportOptions.plist \
  -exportPath build/TestFlight \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
echo "IPA at build/TestFlight/. Upload with Transporter or Xcode Organizer."
