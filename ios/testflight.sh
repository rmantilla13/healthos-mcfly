#!/usr/bin/env bash
# Builds the next TestFlight build and uploads it to App Store Connect.
# Signs with the Apple account in Xcode > Settings > Accounts (team 92X9CP6C6D).
# Bumps CURRENT_PROJECT_VERSION in project.yml first: every upload needs a new build number.
set -euo pipefail
cd "$(dirname "$0")"

current=$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: "?([0-9]+)"?/\1/p' project.yml)
next=$((current + 1))
sed -i '' -E "s/^( *CURRENT_PROJECT_VERSION: )\"?[0-9]+\"?/\1\"$next\"/" project.yml
xcodegen generate --quiet
echo "Building $(sed -nE 's/^ *MARKETING_VERSION: "?([^"]+)"?/\1/p' project.yml) ($next)"

work=$(mktemp -d)
xcodebuild -project HealthOSSync.xcodeproj -scheme HealthOSSync -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$work/HealthOSSync.xcarchive" \
  -allowProvisioningUpdates -quiet archive
xcodebuild -exportArchive -archivePath "$work/HealthOSSync.xcarchive" \
  -exportOptionsPlist ExportOptions.plist -exportPath "$work/export" -allowProvisioningUpdates
rm -rf "$work"
echo "Uploaded build $next. It shows up in App Store Connect > TestFlight after Apple processes it (usually 5–30 minutes)."
