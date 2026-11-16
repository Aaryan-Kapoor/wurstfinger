#!/usr/bin/env bash
#
# bundle-ios.sh
# Builds Wurstfinger.app for iOS with Swift Bundler and assembles the keyboard
# extension that Swift Bundler cannot (see scripts/lib/ios-bundle.sh).
#
# Usage:
#   scripts/bundle-ios.sh [--simulator [NAME]] [--device]
#                         [--configuration debug|release]
#                         [--install] [--launch] [--ipa OUT] [--sideload]
#                         [--identity ID] [--keychain PATH]
#                         [--app-profile PATH] [--keyboard-profile PATH]
#                         [--build-number N] [--dry-run]
#
# --simulator [NAME]  Build for the iOS simulator (the default). NAME picks the
#                     simulator for --install/--launch; default: the first
#                     available iPhone.
# --device            Build for a device: signs with --identity and the two
#                     provisioning profiles. This is the App Store build.
# --sideload          Build an IPA for a sideloader (Impactor, SideStore, AltStore):
#                     a device build signed with a throwaway identity and profiles
#                     made on the spot. The sideloader replaces both with your own
#                     Apple ID's, so the IPA only has to be well formed. Implies
#                     --device, and --ipa defaults to .build/Wurstfinger-sideload.ipa.
# --ipa OUT           Zip Payload/Wurstfinger.app into an IPA at OUT.
# --keychain PATH     Keychain holding the identity (CI uses a temporary one).
# --build-number N    CFBundleVersion for app and keyboard (default: Bundler.toml).
# --dry-run           Print every command instead of running it.
#
# Environment: SWIFT_BUNDLER names the Swift Bundler executable (default:
# swift-bundler).
#
# iOS needs Xcode: the SDKs, xcodebuild (Swift Bundler builds iOS products with
# it), simctl and, when present, actool. Nothing here is needed for the macOS
# app, which `swift bundler run Wurstfinger` builds without Xcode.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/ios-bundle.sh
source "$SCRIPT_DIR/lib/ios-bundle.sh"

usage() {
    sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---- arguments -------------------------------------------------------------------

KIND=simulator
SIMULATOR_NAME=""
SIDELOAD=0
CONFIGURATION=debug
INSTALL=0
LAUNCH=0
IPA_OUT=""
IDENTITY=""
KEYCHAIN=""
APP_PROFILE=""
KEYBOARD_PROFILE=""
BUILD_NUMBER=""

while [ $# -gt 0 ]; do
    case "$1" in
        --simulator)
            KIND=simulator
            if [ $# -gt 1 ] && [ "${2#--}" = "$2" ]; then
                SIMULATOR_NAME="$2"
                shift
            fi
            ;;
        --device) KIND=device ;;
        --sideload)
            SIDELOAD=1
            KIND=device
            ;;
        --configuration | -c)
            [ $# -gt 1 ] || die "$1 needs debug or release"
            CONFIGURATION="$2"
            shift
            ;;
        --install) INSTALL=1 ;;
        --launch) LAUNCH=1 ;;
        --ipa)
            [ $# -gt 1 ] || die "--ipa needs an output path"
            IPA_OUT="$2"
            shift
            ;;
        --identity)
            [ $# -gt 1 ] || die "--identity needs a name or SHA-1"
            IDENTITY="$2"
            shift
            ;;
        --keychain)
            [ $# -gt 1 ] || die "--keychain needs a path"
            KEYCHAIN="$2"
            shift
            ;;
        --app-profile)
            [ $# -gt 1 ] || die "--app-profile needs a path"
            APP_PROFILE="$2"
            shift
            ;;
        --keyboard-profile)
            [ $# -gt 1 ] || die "--keyboard-profile needs a path"
            KEYBOARD_PROFILE="$2"
            shift
            ;;
        --build-number)
            [ $# -gt 1 ] || die "--build-number needs a number"
            BUILD_NUMBER="$2"
            shift
            ;;
        --dry-run) DRY_RUN=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
    shift
done

case "$CONFIGURATION" in
    debug | release) ;;
    *) die "--configuration must be debug or release, not $CONFIGURATION" ;;
esac

if [ "$SIDELOAD" = 1 ]; then
    [ -z "$IDENTITY$APP_PROFILE$KEYBOARD_PROFILE$KEYCHAIN" ] || die "--sideload makes its own identity and profiles; drop --identity, --keychain and the profile options"
    [ -n "$IPA_OUT" ] || IPA_OUT="$REPO_ROOT/.build/$APP_NAME-sideload.ipa"
elif [ "$KIND" = device ]; then
    [ -n "$IDENTITY" ] || [ "$DRY_RUN" = 1 ] || die "--device needs --identity"
    [ -n "$APP_PROFILE" ] || [ "$DRY_RUN" = 1 ] || die "--device needs --app-profile"
    [ -n "$KEYBOARD_PROFILE" ] || [ "$DRY_RUN" = 1 ] || die "--device needs --keyboard-profile"
else
    [ -z "$APP_PROFILE$KEYBOARD_PROFILE" ] || die "provisioning profiles only apply to --device"
fi
if [ "$KIND" = device ] && { [ "$INSTALL" = 1 ] || [ "$LAUNCH" = 1 ]; }; then
    die "--install/--launch work on the simulator; install an IPA on a device with Xcode or Apple Configurator"
fi
if [ "$KIND" = device ] && [ "$SIDELOAD" != 1 ]; then
    IDENTITY="${IDENTITY:-<identity>}"
    APP_PROFILE="${APP_PROFILE:-<app.mobileprovision>}"
    KEYBOARD_PROFILE="${KEYBOARD_PROFILE:-<keyboard.mobileprovision>}"
fi

# ---- configuration -----------------------------------------------------------------

BUNDLER="${SWIFT_BUNDLER:-swift-bundler}"
APP_ID="$(app_identifier)"
VERSION="$(app_version)"
BUILD="${BUILD_NUMBER:-$(app_build_number)}"
if [ -z "$APP_ID" ] || [ -z "$VERSION" ] || [ -z "$BUILD" ]; then
    die "could not read identifier, version and CFBundleVersion for $APP_NAME from Bundler.toml"
fi

if [ "$KIND" = simulator ]; then
    BUNDLER_PLATFORM=iOSSimulator
    SDK=iphonesimulator
else
    BUNDLER_PLATFORM=iOS
    SDK=iphoneos
fi
# Swift Bundler writes its output here whatever the platform
# (`swift bundler bundle --show-bundle-path` prints the same path).
APP="$REPO_ROOT/.build/bundler/apps/$APP_NAME/$APP_NAME.app"
APPEX="$APP/PlugIns/$KEYBOARD_NAME.appex"
WORK="${TMPDIR:-/tmp}"
WORK="${WORK%/}/wurstfinger-bundle-ios.$$"

cd "$REPO_ROOT"
note "kind=$KIND configuration=$CONFIGURATION version=$VERSION build=$BUILD app-id=$APP_ID"
[ "$DRY_RUN" != 1 ] || note "dry run: nothing below is executed"

# ---- 1. preflight -------------------------------------------------------------------

step "Preflight"
if ! xcrun --sdk "$SDK" --show-sdk-path >/dev/null 2>&1; then
    if [ "$DRY_RUN" = 1 ]; then
        warn "the $SDK SDK is not available here (Xcode is required for iOS builds); a real run would stop"
    else
        die "the $SDK SDK was not found. Building for iOS needs Xcode (not just the Command Line Tools): install it and run \`sudo xcode-select -s /Applications/Xcode.app\`."
    fi
else
    note "$SDK SDK: $(xcrun --sdk "$SDK" --show-sdk-path)"
fi
if ! command -v "$BUNDLER" >/dev/null 2>&1; then
    if [ "$DRY_RUN" = 1 ]; then
        warn "$BUNDLER is not on PATH (set SWIFT_BUNDLER, or install moreSwift/swift-bundler); a real run would stop"
    else
        die "$BUNDLER is not on PATH. Install Swift Bundler (see README) or set SWIFT_BUNDLER."
    fi
fi

# ---- device signing inputs ------------------------------------------------------------

APP_ENT="$APP_ENTITLEMENTS"
KEYBOARD_ENT="$KEYBOARD_ENTITLEMENTS"
SIGN_IDENTITY="-"
if [ "$KIND" = device ]; then
    step "Signing inputs"
    if [ "$SIDELOAD" = 1 ]; then
        run mkdir -p "$WORK"
        trap ios_drop_sideload_inputs EXIT
        ios_make_sideload_inputs "$WORK"
        IDENTITY="$SIDELOAD_IDENTITY"
        KEYCHAIN="$SIDELOAD_KEYCHAIN"
    fi
    if [ "$DRY_RUN" = 1 ] || [ "$SIDELOAD" = 1 ]; then
        # The throwaway certificate is self-signed, so `find-identity -v` would
        # not list it; it is already named by its hash.
        SIGN_IDENTITY="$IDENTITY"
        note "resolve \"$IDENTITY\" to a SHA-1 with: security find-identity -v -p codesigning${KEYCHAIN:+ $KEYCHAIN}"
    else
        SIGN_IDENTITY="$(ios_resolve_identity "$IDENTITY" "$KEYCHAIN")"
        [ -n "$SIGN_IDENTITY" ] || die "no valid code-signing identity matches \"$IDENTITY\""
        [ -f "$APP_PROFILE" ] || die "app provisioning profile not found: $APP_PROFILE"
        [ -f "$KEYBOARD_PROFILE" ] || die "keyboard provisioning profile not found: $KEYBOARD_PROFILE"
    fi
    run mkdir -p "$WORK"
    ios_profile_entitlements "$APP_PROFILE" "$WORK/app-granted.plist"
    ios_profile_entitlements "$KEYBOARD_PROFILE" "$WORK/keyboard-granted.plist"
    ios_merge_entitlements "$APP_ENTITLEMENTS" "$WORK/app-granted.plist" "$WORK/app.entitlements"
    ios_merge_entitlements "$KEYBOARD_ENTITLEMENTS" "$WORK/keyboard-granted.plist" "$WORK/keyboard.entitlements"
    APP_ENT="$WORK/app.entitlements"
    KEYBOARD_ENT="$WORK/keyboard.entitlements"
fi

# ---- 2. build and bundle -----------------------------------------------------------

step "Swift Bundler: build $APP_NAME and $KEYBOARD_NAME, bundle the app"
BUNDLE_ARGS=(bundle "$APP_NAME" -p "$BUNDLER_PLATFORM" -c "$CONFIGURATION")
# Xcode would generate Swift symbols from the string catalog, and keys that
# differ only by case or punctuation (Down-Left, Down Left) collide there. The
# code looks strings up by key, so the symbols are not wanted.
BUNDLE_ARGS+=(--Xxcodebuild STRING_CATALOG_GENERATE_SYMBOLS=NO)
if [ "$KIND" = simulator ]; then
    # Swift Bundler signs simulator builds ad hoc by itself; it is signed again
    # below once the extension is inside.
    BUNDLE_ARGS+=(--no-codesign)
else
    # Swift Bundler refuses --no-codesign for devices. Its own signature (and
    # the profile it embeds) is replaced below, once the extension is inside.
    BUNDLE_ARGS+=(--identity "$SIGN_IDENTITY" --provisioning-profile "$APP_PROFILE" --entitlements "$APP_ENT")
fi
run "$BUNDLER" "${BUNDLE_ARGS[@]}"
if [ "$DRY_RUN" != 1 ] && [ ! -d "$APP" ]; then
    die "Swift Bundler did not produce $APP"
fi

# ---- 3-5. assemble ------------------------------------------------------------------

ios_assemble "$APP" "$APP_ID" "$VERSION" "$BUILD" "$KIND" "$WORK"

# ---- 6. sign -----------------------------------------------------------------------------

step "Signing (appex first, then the app)"
if [ "$KIND" = device ]; then
    # Swift Bundler already embedded the app's profile; replace it all the same
    # so the two always come from the files named on the command line.
    ios_embed_profile "$APP_PROFILE" "$APP"
    ios_embed_profile "$KEYBOARD_PROFILE" "$APPEX"
fi
ios_sign "$APP" "$SIGN_IDENTITY" "$APP_ENT" "$KEYBOARD_ENT" "$KEYCHAIN"

# ---- 8. verify ------------------------------------------------------------------------------

step "Verifying"
ios_verify "$APP" 1

# ---- 7. install, launch, package ----------------------------------------------------

if [ "$INSTALL" = 1 ] || [ "$LAUNCH" = 1 ]; then
    step "Simulator"
    UDID=""
    if [ "$DRY_RUN" != 1 ] || xcrun simctl help >/dev/null 2>&1; then
        UDID="$(
            xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
runtimes = json.load(sys.stdin)["devices"]
devices = [d for key in sorted(runtimes) if "iOS" in key for d in runtimes[key] if d.get("isAvailable", True)]
if name:
    devices = [d for d in devices if d["name"] == name]
else:
    devices = [d for d in devices if d["name"].startswith("iPhone")]
booted = [d for d in devices if d.get("state") == "Booted"]
for d in booted or devices[:1]:
    print(d["udid"])
' "$SIMULATOR_NAME" || true
        )"
    fi
    if [ -z "$UDID" ]; then
        if [ "$DRY_RUN" = 1 ]; then
            UDID="<udid of ${SIMULATOR_NAME:-the first available iPhone}>"
        else
            die "no available iOS simulator${SIMULATOR_NAME:+ named \"$SIMULATOR_NAME\"}. List them with \`xcrun simctl list devices available\`."
        fi
    fi
    run_soft xcrun simctl boot "$UDID"
    run xcrun simctl bootstatus "$UDID" -b
    run open -a Simulator
    run xcrun simctl install "$UDID" "$APP"
    if [ "$LAUNCH" = 1 ]; then
        run xcrun simctl launch "$UDID" "$APP_ID"
    fi
    note "the keyboard still has to be enabled once: Settings > General > Keyboard > Keyboards > Add New Keyboard > Wurstfinger"
fi

if [ -n "$IPA_OUT" ]; then
    step "IPA"
    ios_make_ipa "$APP" "$IPA_OUT" "$WORK"
fi

if [ "$DRY_RUN" != 1 ]; then rm -rf "$WORK"; fi
step "Done: $APP"
