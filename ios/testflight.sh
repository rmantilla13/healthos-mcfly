#!/usr/bin/env bash
# Builds the next TestFlight build and uploads it to App Store Connect (team 92X9CP6C6D).
#
# Signing in, either way works:
# - An App Store Connect API key (recommended: it doesn't expire like the Xcode sign-in does). Keep it outside
#   the repo: the key file at ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8, and its ids in
#   ~/.appstoreconnect/healthos.env as ASC_KEY_ID=... and ASC_ISSUER_ID=...
# - Otherwise the Apple account in Xcode > Settings > Accounts.
#
# Bumps CURRENT_PROJECT_VERSION in project.yml first, since every upload needs a new build number.
# `./testflight.sh --same-build` retries the current number (after an upload that failed).
# The archive is kept in Xcode's Archives folder, so a failed upload can still go out from Organizer.
set -euo pipefail
cd "$(dirname "$0")"

auth=()
env_file="$HOME/.appstoreconnect/healthos.env"
if [[ -f "$env_file" ]]; then
  # shellcheck disable=SC1090
  source "$env_file"
  key="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID:-}.p8"
  if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -f "$key" ]]; then
    auth=(-authenticationKeyPath "$key" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
    echo "Signing in with App Store Connect API key $ASC_KEY_ID"
  else
    echo "Note: $env_file is incomplete or $key is missing; using the Xcode account instead." >&2
  fi
fi

current=$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: "?([0-9]+)"?/\1/p' project.yml)
if [[ "${1:-}" == "--same-build" ]]; then
  next=$current
else
  next=$((current + 1))
  sed -i '' -E "s/^( *CURRENT_PROJECT_VERSION: )\"?[0-9]+\"?/\1\"$next\"/" project.yml
fi
xcodegen generate --quiet
version=$(sed -nE 's/^ *MARKETING_VERSION: "?([^"]+)"?/\1/p' project.yml)
echo "Building $version ($next)"

archive="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)/HealthOSSync $version ($next).xcarchive"
mkdir -p "$(dirname "$archive")"
xcodebuild -project HealthOSSync.xcodeproj -scheme HealthOSSync -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" \
  -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} -quiet archive

work=$(mktemp -d)
if ! xcodebuild -exportArchive -archivePath "$archive" \
  -exportOptionsPlist ExportOptions.plist -exportPath "$work/export" -allowProvisioningUpdates ${auth[@]+"${auth[@]}"}; then
  rm -rf "$work"
  echo "Upload failed. The archive is in Xcode > Window > Organizer as \"HealthOSSync $version ($next)\": Distribute App > App Store Connect > Upload." >&2
  echo "To retry from here, fix the sign-in and run: ./testflight.sh --same-build" >&2
  exit 1
fi
rm -rf "$work"
echo "Uploaded $version ($next). It shows up in App Store Connect > TestFlight after Apple processes it (usually 5–30 minutes)."
