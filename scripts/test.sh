#!/bin/zsh
# Full suite: HermesKit package tests (macOS, fast), then the app tests on the iOS Simulator.
set -euo pipefail
cd "${0:A:h}/.."
SIM=${SIM:-"iPhone 18 Pro"}
(cd Packages/HermesKit && swift test --quiet)
xcodebuild test -quiet -project HermesConnect.xcodeproj -scheme HermesConnect \
  -destination "platform=iOS Simulator,name=$SIM" -derivedDataPath build/DerivedData \
  -clonedSourcePackagesDirPath build/SourcePackages CODE_SIGNING_ALLOWED=NO
echo "SUITE PASS"
