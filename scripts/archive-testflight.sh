#!/bin/zsh
# Archive VerseLoop and export for TestFlight (App Store distribution).
# One-time setup: put your 10-char Team ID into scripts/ExportOptions.plist
# (or archive from Xcode Organizer instead — no script needed).
# Every upload needs a NEW build number: bump CURRENT_PROJECT_VERSION first.
set -euo pipefail
cd "$(dirname "$0")/.."
ARCHIVE="build/VerseLoop.xcarchive"
xcodebuild archive \
  -project VerseLoop.xcodeproj -scheme VerseLoop \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_STYLE=Automatic
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist scripts/ExportOptions.plist \
  -exportPath build/TestFlight
echo "IPA at build/TestFlight/. Upload with Transporter or Xcode Organizer."
