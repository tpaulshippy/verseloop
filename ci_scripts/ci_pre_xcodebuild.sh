#!/bin/sh
# Xcode Cloud pre-build: stamp a unique build number so every TestFlight
# upload is accepted (Apple rejects re-uploaded build numbers).
# Locally this is a no-op (CI_BUILD_NUMBER only exists in Xcode Cloud).
set -e
if [ -n "${CI_BUILD_NUMBER:-}" ]; then
  echo "Stamping build number ${CI_BUILD_NUMBER}"
  # shellcheck disable=SC2016
  sed -i '' 's/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = '"${CI_BUILD_NUMBER}"';/g' \
    "$CI_PRIMARY_REPOSITORY_PATH/VerseLoop.xcodeproj/project.pbxproj"
else
  echo "No CI_BUILD_NUMBER (local build) — leaving build number alone."
fi
