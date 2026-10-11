#!/bin/zsh
# Build, install, launch VerseLoop on the iPhone SE (3rd generation) simulator.
# No signing team needed (CODE_SIGNING_ALLOWED=NO works for simulator).
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="platform=iOS Simulator,id=9AB19681-3731-42F6-A128-7AFCFC28B499"
UDID="9AB19681-3731-42F6-A128-7AFCFC28B499"
xcrun simctl boot "$UDID" 2>/dev/null || true
open -a Simulator 2>/dev/null || true
xcodebuild -project VerseLoop.xcodeproj -scheme VerseLoop -configuration Debug \
  -destination "$DEST" CODE_SIGNING_ALLOWED=NO build
APP="$HOME/Library/Developer/Xcode/DerivedData/VerseLoop-*/Build/Products/Debug-iphonesimulator/VerseLoop.app"
APP=( $APP(N) )
xcrun simctl install booted "$APP[1]"
xcrun simctl launch booted com.tpaulshippy.verseloop
echo "Installed + launched on iPhone SE (3rd generation)."

# Record a video: in another terminal run
#   xcrun simctl io booted recordVideo recordings/verseloop-se3.mov
# then drive the UI tests (whole class: single-verse + range flows):
#   xcodebuild test -project VerseLoop.xcodeproj -scheme VerseLoop \
#     -destination "$DEST" CODE_SIGNING_ALLOWED=NO \
#     -only-testing:VerseLoopUITests
