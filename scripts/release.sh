#!/usr/bin/env bash
# Builds a Takely release: the app with Takely Pro, signed with Developer ID (hardened runtime), notarized and
# stapled, in a signed DMG, plus a Sparkle appcast with EdDSA-signed updates.
#
#   scripts/release.sh 0.2.0            # needs the Apple Developer Program (see below)
#   scripts/release.sh 0.2.0 --dry-run  # prints every step instead of running it
#
# Environment (put it in a gitignored .env.release and `source` it):
#   DEVELOPER_ID          "Developer ID Application: Your Name (TEAMID)" — in your login keychain
#   TEAM_ID               your Apple team ID
#   NOTARY_PROFILE        a notarytool profile: xcrun notarytool store-credentials <name> --apple-id … --team-id …
#   TAKELY_APPCAST_URL    where appcast.xml will be served, e.g. https://updates.example.com/appcast.xml
#   TAKELY_SPARKLE_PUBLIC_KEY  from Sparkle's generate_keys (the private key stays in your keychain)
#   TAKELY_DOWNLOAD_BASE  where the DMGs will be served, e.g. https://updates.example.com/
#   TAKELY_LICENSE_URL (license server), TAKELY_LICENSE_PRODUCT_IDS (Paddle pro_… IDs), TAKELY_BUY_URL (website buy page)
# Sparkle's tools (generate_keys, sign_update, generate_appcast) come with the Sparkle package:
#   build/SourcePackages/artifacts/sparkle/Sparkle/bin/  (after one build)
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:?usage: scripts/release.sh <version> [--dry-run]}"
dry=0
[[ "${2:-}" == "--dry-run" ]] && dry=1
build_number="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
dist="dist/$version"
# Every release's DMG stays here, so the appcast lists them all (and Sparkle can make deltas).
updates="dist/updates"
app="$dist/export/Takely.app"
dmg="$dist/Takely-$version.dmg"

run() {
    printf '+ %q' "$1"
    printf ' %q' "${@:2}"
    printf '\n'
    if ((!dry)); then "$@"; fi
}

need() {
    for name in "$@"; do
        if [[ -z "${!name:-}" ]]; then
            if ((dry)); then
                echo "(dry run) $name is not set"
                printf -v "$name" '%s' "<$name>"
            else
                echo "error: $name is not set (see the top of scripts/release.sh)" >&2
                exit 1
            fi
        fi
    done
}

need DEVELOPER_ID TEAM_ID NOTARY_PROFILE TAKELY_APPCAST_URL TAKELY_SPARKLE_PUBLIC_KEY TAKELY_DOWNLOAD_BASE \
    TAKELY_LICENSE_URL TAKELY_LICENSE_PRODUCT_IDS TAKELY_BUY_URL
((dry)) || [[ "$TAKELY_DOWNLOAD_BASE" == */ ]] || { echo "error: TAKELY_DOWNLOAD_BASE must end with /" >&2; exit 1; }
[[ -d Packages/TakelyPro ]] || { echo "error: releases include Takely Pro (Packages/TakelyPro is missing)" >&2; exit 1; }
if ((!dry)) && ! security find-identity -v -p codesigning | grep -qF "$DEVELOPER_ID"; then
    echo "error: no \"$DEVELOPER_ID\" certificate in the keychain. Developer ID certificates need the Apple Developer Program." >&2
    exit 1
fi
sparkle_bin="build/SourcePackages/artifacts/sparkle/Sparkle/bin"

# notarytool can exit 0 with an "Invalid" result: check the status, and show Apple's log when it isn't Accepted.
notarize() {
    echo "+ xcrun notarytool submit $1 --keychain-profile <profile> --wait"
    ((dry)) && return
    local result id status
    result=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
    id=$(plutil -extract id raw - <<<"$result")
    status=$(plutil -extract status raw - <<<"$result")
    if [[ "$status" != "Accepted" ]]; then
        echo "error: notarization $status" >&2
        xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        exit 1
    fi
}

echo "==> Takely $version ($build_number)"
run rm -rf "$dist"
run mkdir -p "$dist" "$updates"
run xcodegen generate --quiet --spec project.pro.yml

echo "==> Archive (Developer ID, hardened runtime, secure timestamp)"
run xcodebuild archive -project Takely.xcodeproj -scheme Takely -configuration Release \
    -destination "generic/platform=macOS" -archivePath "$dist/Takely.xcarchive" -derivedDataPath build \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVELOPER_ID" DEVELOPMENT_TEAM="$TEAM_ID" \
    ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp \
    TAKELY_APPCAST_URL="$TAKELY_APPCAST_URL" TAKELY_SPARKLE_PUBLIC_KEY="$TAKELY_SPARKLE_PUBLIC_KEY" \
    TAKELY_LICENSE_URL="$TAKELY_LICENSE_URL" TAKELY_LICENSE_PRODUCT_IDS="$TAKELY_LICENSE_PRODUCT_IDS" \
    TAKELY_BUY_URL="$TAKELY_BUY_URL"

options="$dist/ExportOptions.plist"
if ((!dry)); then
    cat >"$options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>teamID</key><string>$TEAM_ID</string>
<key>signingStyle</key><string>manual</string>
<key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
PLIST
fi
run xcodebuild -exportArchive -archivePath "$dist/Takely.xcarchive" -exportPath "$dist/export" -exportOptionsPlist "$options"
run codesign --verify --deep --strict --verbose=2 "$app"

echo "==> Notarize the app"
run ditto -c -k --keepParent "$app" "$dist/Takely.zip"
notarize "$dist/Takely.zip"
run xcrun stapler staple "$app"

echo "==> DMG"
run hdiutil create -volname "Takely" -srcfolder "$app" -ov -format UDZO "$dmg"
run codesign --sign "$DEVELOPER_ID" --timestamp "$dmg"
notarize "$dmg"
run xcrun stapler staple "$dmg"
run spctl --assess --type open --context context:primary-signature --verbose "$dmg"

echo "==> Sparkle appcast (EdDSA signatures from the private key in your keychain)"
run cp "$dmg" "$updates/"
run "$sparkle_bin/generate_appcast" --download-url-prefix "$TAKELY_DOWNLOAD_BASE" "$updates"

echo "==> Done: upload $updates/ (the DMGs and appcast.xml) to $TAKELY_DOWNLOAD_BASE"
