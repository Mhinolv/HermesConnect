#!/bin/zsh
# Build a signed Debug app and install it over the app on the paired iPhone.
# It never uninstalls. A delete resets the permissions, the pinned host key and the device SSH key.
# Usage: scripts/device.sh [device-udid-or-name]   (default: the first paired physical iPhone)
set -euo pipefail
cd "$(dirname "$0")/.."
DEV=${1:-$(xcrun devicectl list devices 2>/dev/null | awk '/available \(paired\)/ && /physical/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) {print $i; exit}}')}
[[ -n "$DEV" ]] || { echo "!! no paired iPhone found (connect it, unlock it, trust this Mac)"; exit 2; }
xcodebuild -project HermesConnect.xcodeproj -scheme HermesConnect -configuration Debug \
  -destination "id=$DEV" -derivedDataPath build/DeviceData -clonedSourcePackagesDirPath build/SourcePackages \
  -allowProvisioningUpdates build | grep -E 'error:|BUILD (SUCCEEDED|FAILED)' || true
APP=build/DeviceData/Build/Products/Debug-iphoneos/HermesConnect.app
[[ -d "$APP" ]] || { echo "!! build failed. If the error is 'No Accounts', sign in at Xcode > Settings > Accounts."; exit 1; }
xcrun devicectl device install app --device "$DEV" "$APP"
echo "DEVICE INSTALL PASS"
