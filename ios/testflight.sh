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
#
# It builds what's on disk, so it stops when ios/ has uncommitted changes (another session's work in progress
# would ship otherwise). A leftover build-number bump from a failed upload doesn't count.
# `--allow-dirty` builds anyway.
set -euo pipefail
cd "$(dirname "$0")"

same_build=false
allow_dirty=false
for arg in "$@"; do
  case "$arg" in
    --same-build) same_build=true ;;
    --allow-dirty) allow_dirty=true ;;
    *) echo "Unknown option: $arg (use --same-build and/or --allow-dirty)" >&2; exit 2 ;;
  esac
done

# Uncommitted or untracked files under ios/, except project files whose only change is the build number.
dirty=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  path="${line:3}"
  case "$path" in
    ios/project.yml | ios/HealthOSSync.xcodeproj/project.pbxproj)
      if ! git diff HEAD -U0 -- "../$path" | grep -E '^[-+][^-+]' | grep -qv 'CURRENT_PROJECT_VERSION'; then continue; fi ;;
  esac
  dirty+=("$path")
done < <(git -C .. status --porcelain --untracked-files=all -- ios)
if [[ ${#dirty[@]} -gt 0 && "$allow_dirty" != true ]]; then
  echo "ios/ has uncommitted changes, so this build would include them:" >&2
  printf '  %s\n' "${dirty[@]}" >&2
  echo "Commit them first, or run with --allow-dirty to build them anyway." >&2
  exit 1
fi

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
if [[ "$same_build" == true ]]; then
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
# Xcode's own upload step can refuse an API key that App Store Connect accepts ("No Accounts with App Store
# Connect Access", seen with Xcode 27.1). Then the build is exported to an .ipa with the same key and sent
# with altool, which signs in with the key on its own.
upload_with_altool() {
  [[ ${#auth[@]} -gt 0 ]] || return 1
  echo "Xcode's upload didn't sign in; exporting the .ipa and sending it with altool instead." >&2
  sed 's#<string>upload</string>#<string>export</string>#' ExportOptions.plist > "$work/ExportOptions-local.plist"
  xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$work/ExportOptions-local.plist" \
    -exportPath "$work/ipa" -allowProvisioningUpdates "${auth[@]}" -quiet &&
    xcrun altool --upload-app -f "$work/ipa/HealthOSSync.ipa" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
}
if ! xcodebuild -exportArchive -archivePath "$archive" \
  -exportOptionsPlist ExportOptions.plist -exportPath "$work/export" -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} &&
  ! upload_with_altool; then
  rm -rf "$work"
  echo "Upload failed. The archive is in Xcode > Window > Organizer as \"HealthOSSync $version ($next)\": Distribute App > App Store Connect > Upload." >&2
  echo "To retry from here, fix the sign-in and run: ./testflight.sh --same-build" >&2
  exit 1
fi
rm -rf "$work"
echo "Uploaded $version ($next). It shows up in App Store Connect > TestFlight after Apple processes it (usually 5–30 minutes)."
