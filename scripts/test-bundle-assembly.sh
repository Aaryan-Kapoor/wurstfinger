#!/usr/bin/env bash
#
# test-bundle-assembly.sh
# Runs the iOS bundle assembly (scripts/lib/ios-bundle.sh) on a fake app layout
# and asserts the result. Needs macOS (plutil, codesign, sips) but no Xcode and
# no iOS SDK: the fake app stands in for what Swift Bundler writes, with a
# placeholder executable instead of a real build.
#
# What it exercises, with the same functions scripts/bundle-ios.sh calls:
#   - the keyboard appex: executable moved in, Info.plist rendered
#   - string catalogs compiled into <locale>.lproj for the app and the appex
#   - privacy manifests, resource-bundle pruning, icons (actool when present,
#     loose PNGs otherwise), ad-hoc signing with entitlements, verification
#   - the Bundler.toml reader, the device entitlement merge, bundle-ios.sh --dry-run
#
# Usage: scripts/test-bundle-assembly.sh [--keep]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/ios-bundle.sh
source "$SCRIPT_DIR/lib/ios-bundle.sh"

KEEP=0
if [ "${1:-}" = "--keep" ]; then KEEP=1; fi

FAILURES=0
CHECKS=0

pass() {
    CHECKS=$((CHECKS + 1))
    printf '  ok   %s\n' "$1"
}
fail() {
    CHECKS=$((CHECKS + 1))
    FAILURES=$((FAILURES + 1))
    printf '  FAIL %s\n' "$1"
}

# check DESCRIPTION COMMAND...: passes when the command succeeds.
check() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then pass "$description"; else fail "$description"; fi
}

# check_eq DESCRIPTION EXPECTED ACTUAL
check_eq() {
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1 (expected '$2', got '$3')"
    fi
}

plist_value() { plist_get "$1" "$2"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wurstfinger-assembly.XXXXXX")"
cleanup() {
    if [ "$KEEP" = 1 ]; then
        echo "kept: $TMP"
    else
        rm -rf "$TMP"
    fi
}
trap cleanup EXIT

[ "$(uname -s)" = Darwin ] || {
    echo "test-bundle-assembly.sh needs macOS (plutil, codesign)" >&2
    exit 1
}

# ---- a fake app, laid out the way Swift Bundler lays out an iOS app ---------------

APP="$TMP/Wurstfinger.app"
WORK="$TMP/work"
mkdir -p "$APP" "$WORK"

make_executable() {
    # A real Mach-O (a trivial C program) so codesign accepts it. Without a C
    # compiler, fall back to a copy of a system tool.
    if command -v cc >/dev/null 2>&1; then
        printf 'int main(void) { return 0; }\n' | cc -x c - -o "$1" 2>/dev/null && return 0
    fi
    cp "$(command -v true)" "$1"
}
make_executable "$APP/Wurstfinger"
make_executable "$APP/WurstfingerKeyboard"
printf 'APPL????' >"$APP/PkgInfo"
printf 'not an icns' >"$APP/AppIcon.icns"
mkdir -p "$APP/Wurstfinger_Wurstfinger.bundle"
printf 'raw' >"$APP/Wurstfinger_Wurstfinger.bundle/Localizable.xcstrings"

plutil -create xml1 "$APP/Info.plist"
plutil -insert CFBundleExecutable -string Wurstfinger "$APP/Info.plist"
plutil -insert CFBundleIdentifier -string "$(app_identifier)" "$APP/Info.plist"
plutil -insert CFBundleName -string Wurstfinger "$APP/Info.plist"
plutil -insert CFBundlePackageType -string APPL "$APP/Info.plist"
plutil -insert CFBundleIconFile -string AppIcon "$APP/Info.plist"
plutil -insert CFBundleIconName -string AppIcon "$APP/Info.plist"
plutil -insert CFBundleShortVersionString -string 0.0.0 "$APP/Info.plist"
plutil -insert CFBundleVersion -string 0 "$APP/Info.plist"
plutil -insert CFBundleSupportedPlatforms -json '["iPhoneOS"]' "$APP/Info.plist"

# ---- configuration readers -------------------------------------------------------------

echo "Bundler.toml"
APP_ID="$(app_identifier)"
VERSION="$(app_version)"
BUILD="$(app_build_number)"
check_eq "identifier" "de.akator.wurstfinger" "$APP_ID"
check "version looks like x.y.z" test -n "$(printf '%s' "$VERSION" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' || true)"
check "build number is a number" test -n "$(printf '%s' "$BUILD" | grep -E '^[0-9]+$' || true)"

# ---- assemble --------------------------------------------------------------------------------

echo "Assembling"
ios_assemble "$APP" "$APP_ID" "$VERSION" "99" simulator "$WORK" >"$TMP/assemble.log" 2>&1 ||
    {
        cat "$TMP/assemble.log"
        fail "ios_assemble ran"
    }
APPEX="$APP/PlugIns/$KEYBOARD_NAME.appex"

echo "Structure"
check "appex directory" test -d "$APPEX"
check "keyboard executable moved into the appex" test -x "$APPEX/$KEYBOARD_NAME"
check "keyboard executable no longer at the app root" test ! -e "$APP/$KEYBOARD_NAME"
check "app executable stays" test -x "$APP/Wurstfinger"
check "appex Info.plist" test -f "$APPEX/Info.plist"
check "app privacy manifest" test -f "$APP/PrivacyInfo.xcprivacy"
check "appex privacy manifest" test -f "$APPEX/PrivacyInfo.xcprivacy"
check "SwiftPM resource bundle pruned" test ! -e "$APP/Wurstfinger_Wurstfinger.bundle"
check "macOS-style AppIcon.icns removed" test ! -e "$APP/AppIcon.icns"
check "no .xcstrings left in the bundles" test -z "$(find "$APP" -name '*.xcstrings')"

echo "Info.plists"
check "app Info.plist lints" plutil -lint "$APP/Info.plist"
check "appex Info.plist lints" plutil -lint "$APPEX/Info.plist"
check_eq "appex bundle identifier" "$APP_ID.keyboard" "$(plist_value "$APPEX/Info.plist" CFBundleIdentifier)"
check_eq "appex package type" "XPC!" "$(plist_value "$APPEX/Info.plist" CFBundlePackageType)"
check_eq "appex executable" "$KEYBOARD_NAME" "$(plist_value "$APPEX/Info.plist" CFBundleExecutable)"
check_eq "appex version" "$VERSION" "$(plist_value "$APPEX/Info.plist" CFBundleShortVersionString)"
check_eq "appex build" "99" "$(plist_value "$APPEX/Info.plist" CFBundleVersion)"
check_eq "app build matches" "99" "$(plist_value "$APP/Info.plist" CFBundleVersion)"
check_eq "appex development region" "en" "$(plist_value "$APPEX/Info.plist" CFBundleDevelopmentRegion)"
check_eq "appex minimum OS" "17.0" "$(plist_value "$APPEX/Info.plist" MinimumOSVersion)"
check_eq "appex platform" "iPhoneSimulator" "$(plist_value "$APPEX/Info.plist" CFBundleSupportedPlatforms.0)"
check_eq "appex device family" "1" "$(plist_value "$APPEX/Info.plist" UIDeviceFamily.0)"
check_eq "appex runs on iPad" "2" "$(plist_value "$APPEX/Info.plist" UIDeviceFamily.1)"
check_eq "appex extension point" "com.apple.keyboard-service" "$(plist_value "$APPEX/Info.plist" NSExtension.NSExtensionPointIdentifier)"
check_eq "appex principal class" "KeyboardViewController" "$(plist_value "$APPEX/Info.plist" NSExtension.NSExtensionPrincipalClass)"
check_eq "appex export compliance" "false" "$(plist_value "$APPEX/Info.plist" ITSAppUsesNonExemptEncryption)"
check_eq "app platform" "iPhoneSimulator" "$(plist_value "$APP/Info.plist" CFBundleSupportedPlatforms.0)"
check "obsolete CFBundleIconFile gone" test -z "$(plist_value "$APP/Info.plist" CFBundleIconFile)"
check "app declares icons" test -n "$(plist_value "$APP/Info.plist" CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName)"
if ios_have_actool; then
    check "actool compiled Assets.car" test -f "$APP/Assets.car"
else
    check "loose icon AppIcon60x60@2x.png" test -f "$APP/AppIcon60x60@2x.png"
    check_eq "icon is 120 px wide" "120" "$(sips -g pixelWidth "$APP/AppIcon60x60@2x.png" | awk '/pixelWidth/ { print $2 }')"
    check "iPad icon 76x76@2x" test -f "$APP/AppIcon76x76@2x.png"
fi

echo "Localized strings"
locale_check() {
    local catalog="$1" root="$2" label="$3" locale count=0 missing=""
    while IFS= read -r locale; do
        count=$((count + 1))
        if [ ! -s "$root/$locale.lproj/Localizable.strings" ]; then missing="$missing $locale"; fi
        if ! plutil -lint "$root/$locale.lproj/Localizable.strings" >/dev/null 2>&1; then missing="$missing $locale(invalid)"; fi
    done < <(python3 "$STRINGS_CONVERTER" "$catalog" --list-locales)
    if [ -z "$missing" ] && [ "$count" -gt 1 ]; then
        pass "$label: $count locales, each a valid Localizable.strings"
    else
        fail "$label: missing$missing (of $count)"
    fi
}
locale_check "$APP_CATALOG" "$APP" "app"
locale_check "$KEYBOARD_CATALOG" "$APPEX" "appex"
check "app .strings carry a translation (de)" grep -q '^"Settings" = "' "$APP/de.lproj/Localizable.strings"

# ---- signing -------------------------------------------------------------------------------------

echo "Signing (ad hoc)"
ios_sign "$APP" "-" "$APP_ENTITLEMENTS" "$KEYBOARD_ENTITLEMENTS" "" >"$TMP/sign.log" 2>&1 ||
    {
        cat "$TMP/sign.log"
        fail "ios_sign ran"
    }
check "codesign verify --deep --strict" codesign --verify --deep --strict "$APP"
check "appex verifies on its own" codesign --verify --strict "$APPEX"
group_id="group.de.akator.wurstfinger.shared"
check "app signature carries the app group" bash -c "codesign -d --entitlements :- '$APP' 2>/dev/null | grep -q '$group_id'"
check "appex signature carries the app group" bash -c "codesign -d --entitlements :- '$APPEX' 2>/dev/null | grep -q '$group_id'"
check "plist verification step" ios_verify "$APP" 1

# ---- device entitlements merge ----------------------------------------------------------------

echo "Device entitlement merge"
GRANTED="$TMP/granted.plist"
plutil -create xml1 "$GRANTED"
plutil -insert application-identifier -string "TEAM123456.$APP_ID" "$GRANTED"
plutil -insert 'com\.apple\.developer\.team-identifier' -string TEAM123456 "$GRANTED"
plutil -insert get-task-allow -bool false "$GRANTED"
ios_merge_entitlements "$APP_ENTITLEMENTS" "$GRANTED" "$TMP/merged.entitlements"
check "merged entitlements lint" plutil -lint "$TMP/merged.entitlements"
check_eq "application identifier from the profile" "TEAM123456.$APP_ID" "$(plist_value "$TMP/merged.entitlements" application-identifier)"
check_eq "team identifier from the profile" "TEAM123456" "$(plist_get "$TMP/merged.entitlements" 'com\.apple\.developer\.team-identifier')"
check_eq "get-task-allow from the profile" "false" "$(plist_value "$TMP/merged.entitlements" get-task-allow)"
check_eq "app group kept from the repository file" "$group_id" "$(plist_get "$TMP/merged.entitlements" 'com\.apple\.security\.application-groups.0')"

# ---- the driver script ---------------------------------------------------------------------------

echo "bundle-ios.sh --dry-run"
DRY_OUT="$TMP/dry.log"
if "$SCRIPT_DIR/bundle-ios.sh" --simulator --dry-run >"$DRY_OUT" 2>&1; then pass "simulator dry run exits 0"; else fail "simulator dry run exits 0"; fi
check "dry run builds with Swift Bundler" grep -q '^+ swift-bundler bundle Wurstfinger -p iOSSimulator' "$DRY_OUT"
FIRST_SIGN="$(grep 'codesign --force' "$DRY_OUT" | sed -n 1p)"
SECOND_SIGN="$(grep 'codesign --force' "$DRY_OUT" | sed -n 2p)"
check "dry run signs the appex first" test -n "$(printf '%s' "$FIRST_SIGN" | grep 'PlugIns/WurstfingerKeyboard.appex$' || true)"
check "dry run signs the app second" test -n "$(printf '%s' "$SECOND_SIGN" | grep 'Wurstfinger.app$' || true)"
check "dry run never uses --deep to sign" bash -c "! grep -q 'codesign --force.*--deep' '$DRY_OUT'"
if "$SCRIPT_DIR/bundle-ios.sh" --device --ipa out/Wurstfinger.ipa --build-number 7 --identity "Apple Distribution" \
    --app-profile a.mobileprovision --keyboard-profile k.mobileprovision --dry-run >"$TMP/dry-device.log" 2>&1; then
    pass "device dry run exits 0"
else
    fail "device dry run exits 0"
fi
check "device dry run passes the profile to Swift Bundler" grep -q -- '--provisioning-profile a.mobileprovision' "$TMP/dry-device.log"
check "device dry run zips an IPA" grep -q 'zip -qry' "$TMP/dry-device.log"
check "device dry run uses the build number" grep -q 'CFBundleVersion -string 7' "$TMP/dry-device.log"
check "rejects --device without a profile" bash -c "! '$SCRIPT_DIR/bundle-ios.sh' --device --identity x >/dev/null 2>&1"

# ---- result -----------------------------------------------------------------------------------------

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "All $CHECKS checks passed."
else
    echo "$FAILURES of $CHECKS checks failed (rerun with --keep to inspect $TMP)." >&2
    exit 1
fi
