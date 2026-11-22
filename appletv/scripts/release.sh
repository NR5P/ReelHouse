#!/usr/bin/env bash
# Archive the Apple TV app in Release and upload it to App Store Connect (TestFlight).
# Needs Xcode signed in to the team and the tvOS App Store Connect record for com.reelhouse.client.tv.
set -euo pipefail

DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUILD="$DIR/build"
mkdir -p "$BUILD"

echo "==> Archiving ReelHouseTV (tvOS)"
xcodebuild -project "$DIR/ReelHouseTV.xcodeproj" -scheme ReelHouseTV -configuration Release \
  -destination "generic/platform=tvOS" -archivePath "$BUILD/ReelHouseTV.xcarchive" \
  -allowProvisioningUpdates archive | grep -E "error:|warning: .*signing|\*\* ARCHIVE" || true
[[ -d "$BUILD/ReelHouseTV.xcarchive" ]] || { echo "Archive failed - see above." >&2; exit 1; }

echo "==> Uploading to App Store Connect"
xcodebuild -exportArchive -archivePath "$BUILD/ReelHouseTV.xcarchive" \
  -exportOptionsPlist "$DIR/scripts/ExportOptions.plist" -exportPath "$BUILD/ReelHouseTV-export" \
  -allowProvisioningUpdates | grep -E "error:|Upload|EXPORT" || true
echo "==> Done. Check App Store Connect → TestFlight."
