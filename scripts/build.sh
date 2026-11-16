#!/bin/zsh
# Build the app for the iOS Simulator (no tests).
set -euo pipefail
cd "${0:A:h}/.."
SIM=${SIM:-"iPhone 18 Pro"}
xcodebuild build-for-testing -quiet -project HermesConnect.xcodeproj -scheme HermesConnect \
  -destination "platform=iOS Simulator,name=$SIM" -derivedDataPath build/DerivedData \
  -clonedSourcePackagesDirPath build/SourcePackages CODE_SIGNING_ALLOWED=NO
echo "BUILD PASS"
