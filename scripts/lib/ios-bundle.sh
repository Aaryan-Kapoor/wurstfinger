#!/usr/bin/env bash
#
# ios-bundle.sh
# The steps that turn a Swift Bundler iOS build into a complete app with its
# keyboard extension. Sourced by scripts/bundle-ios.sh (the real build) and
# scripts/test-bundle-assembly.sh (which runs the same functions on a fake
# layout, with no Xcode).
#
# Swift Bundler has no app-extension support. For `-p iOS`/`-p iOSSimulator` it
# builds the keyboard executable because Bundler.toml lists it in
# `dependencies`, and copies it next to the app executable. Everything that
# makes it an extension happens here:
#
#   Wurstfinger.app/
#     Wurstfinger                         app executable (Swift Bundler)
#     Info.plist, Assets.car, icons       app (Swift Bundler + actool/sips)
#     <locale>.lproj/Localizable.strings  app strings (xcstrings_to_strings.py)
#     PrivacyInfo.xcprivacy
#     FeelShaders.metallib                the feel shaders, when a Metal toolchain exists
#     PlugIns/WurstfingerKeyboard.appex/
#       WurstfingerKeyboard               moved here from the app root
#       Info.plist                        rendered from Bundling/Keyboard-Info.plist
#       <locale>.lproj/Localizable.strings
#       PrivacyInfo.xcprivacy
#       FeelShaders.metallib
#
# Every command that changes the filesystem goes through `run`, so with
# DRY_RUN=1 the whole sequence prints instead of executing.
#
# Written for the bash 3.2 that macOS ships: no mapfile, no associative arrays.

# ---- configuration (callers may override before sourcing) -------------------

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$LIB_DIR/../.." && pwd)}"
DRY_RUN="${DRY_RUN:-0}"

APP_NAME="Wurstfinger"
KEYBOARD_NAME="WurstfingerKeyboard"
MINIMUM_OS_VERSION="17.0"
APP_ENTITLEMENTS="$REPO_ROOT/Bundling/wurstfinger.entitlements"
KEYBOARD_ENTITLEMENTS="$REPO_ROOT/Bundling/wurstfingerKeyboard.entitlements"
KEYBOARD_PLIST_TEMPLATE="$REPO_ROOT/Bundling/Keyboard-Info.plist"
APP_CATALOG="$REPO_ROOT/Sources/$APP_NAME/Resources/Localizable.xcstrings"
KEYBOARD_CATALOG="$REPO_ROOT/Sources/$KEYBOARD_NAME/Resources/Localizable.xcstrings"
APP_PRIVACY="$REPO_ROOT/Sources/$APP_NAME/Resources/PrivacyInfo.xcprivacy"
KEYBOARD_PRIVACY="$REPO_ROOT/Sources/$KEYBOARD_NAME/Resources/PrivacyInfo.xcprivacy"
ICON_ASSETS="$REPO_ROOT/Bundling/Assets.xcassets"
ICON_COMPOSER="$REPO_ROOT/Bundling/AppIcon.icon"
ICON_PNG="$REPO_ROOT/Bundling/AppIcon.png"
STRINGS_CONVERTER="$REPO_ROOT/scripts/xcstrings_to_strings.py"
SHADER_SOURCE="$REPO_ROOT/Sources/WurstfingerKit/Keyboard/Runtime/View/Shaders/FeelShaderSource.swift"
BUNDLER_TOML="$REPO_ROOT/Bundler.toml"

# ---- output helpers ----------------------------------------------------------

step() { printf '\n== %s\n' "$*"; }
note() { printf '# %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

# Runs a command, or prints it when DRY_RUN=1. Commands are printed with shell
# quoting, so they can be copied and run by hand.
run() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '+'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

# Like `run`, for commands whose failure is acceptable (already booted, ...).
run_soft() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '+'
        printf ' %q' "$@"
        printf '   # failure ignored\n'
    else
        "$@" || true
    fi
}

# ---- Bundler.toml ------------------------------------------------------------

# toml_value SECTION KEY: the string value of `KEY = "..."` inside the table
# `[SECTION]`. Enough TOML for the flat scalar keys this repository reads.
toml_value() {
    awk -v section="[$1]" -v key="$2" '
        /^\[/ { in_section = ($0 == section); next }
        in_section && $1 == key && $2 == "=" {
            value = $0
            sub(/^[^=]*=[ \t]*"/, "", value)
            sub(/".*$/, "", value)
            print value
            exit
        }' "$BUNDLER_TOML"
}

app_identifier() { toml_value "apps.$APP_NAME" identifier; }
app_version() { toml_value "apps.$APP_NAME" version; }
app_build_number() { toml_value "apps.$APP_NAME.plist" CFBundleVersion; }

# ---- Info.plist --------------------------------------------------------------

# plist_get PLIST KEYPATH: the value, or nothing when the key is absent
# (plutil reports a missing key on stdout, which must not leak out as a value).
plist_get() {
    local value
    if value="$(plutil -extract "$2" raw -o - "$1" 2>/dev/null)"; then
        printf '%s' "$value"
    fi
}

# Renders the keyboard extension's Info.plist from the template.
#   ios_render_keyboard_plist OUT APP_ID VERSION BUILD PLATFORM
# PLATFORM is the CFBundleSupportedPlatforms value: iPhoneSimulator or iPhoneOS.
ios_render_keyboard_plist() {
    local out="$1" app_id="$2" version="$3" build="$4" platform="$5"
    run mkdir -p "$(dirname "$out")"
    run cp "$KEYBOARD_PLIST_TEMPLATE" "$out"
    run chmod u+w "$out"
    run plutil -replace CFBundleIdentifier -string "$app_id.keyboard" "$out"
    run plutil -replace CFBundleExecutable -string "$KEYBOARD_NAME" "$out"
    run plutil -replace CFBundleShortVersionString -string "$version" "$out"
    run plutil -replace CFBundleVersion -string "$build" "$out"
    run plutil -replace CFBundleDevelopmentRegion -string en "$out"
    run plutil -replace MinimumOSVersion -string "$MINIMUM_OS_VERSION" "$out"
    run plutil -replace CFBundleSupportedPlatforms -json "[\"$platform\"]" "$out"
    run plutil -replace UIDeviceFamily -json '[1,2]' "$out"
    run plutil -replace ITSAppUsesNonExemptEncryption -bool false "$out"
}

# Brings the plist Swift Bundler wrote for the app in line with what the
# keyboard's plist says, so the two can never disagree about version or build.
#   ios_adjust_app_plist PLIST VERSION BUILD PLATFORM
ios_adjust_app_plist() {
    local plist="$1" version="$2" build="$3" platform="$4"
    run plutil -replace CFBundleShortVersionString -string "$version" "$plist"
    run plutil -replace CFBundleVersion -string "$build" "$plist"
    # Swift Bundler writes iPhoneOS for both; Xcode writes iPhoneSimulator for
    # simulator builds.
    run plutil -replace CFBundleSupportedPlatforms -json "[\"$platform\"]" "$plist"
}

# Adds the DT* keys Xcode stamps into every Info.plist (App Store Connect
# validates their presence on uploads). Best effort: without Xcode there is
# nothing to read them from, and a simulator build does not need them.
#   ios_add_toolchain_keys PLIST SDK        SDK is iphoneos or iphonesimulator
ios_add_toolchain_keys() {
    local plist="$1" sdk="$2"
    if [ "$DRY_RUN" = 1 ]; then
        note "add DTPlatformName/DTSDKName/DTXcode/... to $(basename "$(dirname "$plist")")/Info.plist, read from xcrun --sdk $sdk and the selected Xcode"
        return 0
    fi
    local version build developer xcode_info xcode xcode_build
    if ! version="$(xcrun --sdk "$sdk" --show-sdk-version 2>/dev/null)" ||
        ! build="$(xcrun --sdk "$sdk" --show-sdk-build-version 2>/dev/null)"; then
        warn "no $sdk SDK found, so $plist gets no DT* keys"
        return 0
    fi
    developer="$(xcode-select -p 2>/dev/null || true)"
    xcode_info="$(dirname "$developer")/Info.plist"
    if [ ! -f "$xcode_info" ]; then
        warn "no Xcode Info.plist at $xcode_info, so $plist gets no DT* keys"
        return 0
    fi
    xcode="$(plist_get "$xcode_info" DTXcode)"
    xcode_build="$(plist_get "$xcode_info" DTXcodeBuild)"
    plutil -replace DTPlatformName -string "$sdk" "$plist"
    plutil -replace DTPlatformVersion -string "$version" "$plist"
    plutil -replace DTPlatformBuild -string "$build" "$plist"
    plutil -replace DTSDKName -string "$sdk$version" "$plist"
    plutil -replace DTSDKBuild -string "$build" "$plist"
    plutil -replace DTCompiler -string com.apple.compilers.llvm.clang.1_0 "$plist"
    plutil -replace BuildMachineOSBuild -string "$(sw_vers -buildVersion)" "$plist"
    if [ -n "$xcode" ]; then plutil -replace DTXcode -string "$xcode" "$plist"; fi
    if [ -n "$xcode_build" ]; then plutil -replace DTXcodeBuild -string "$xcode_build" "$plist"; fi
}

# ---- the extension -----------------------------------------------------------

# Moves the keyboard executable into PlugIns/WurstfingerKeyboard.appex and
# gives it its Info.plist.
#   ios_assemble_appex APP APP_ID VERSION BUILD PLATFORM
ios_assemble_appex() {
    local app="$1" app_id="$2" version="$3" build="$4" platform="$5"
    local appex="$app/PlugIns/$KEYBOARD_NAME.appex"
    run mkdir -p "$appex"
    if [ "$DRY_RUN" != 1 ] && [ ! -f "$app/$KEYBOARD_NAME" ]; then
        die "$app/$KEYBOARD_NAME is missing: does the iOS overlay in Bundler.toml still list $KEYBOARD_NAME in \`dependencies\`?"
    fi
    run mv "$app/$KEYBOARD_NAME" "$appex/$KEYBOARD_NAME"
    ios_render_keyboard_plist "$appex/Info.plist" "$app_id" "$version" "$build" "$platform"
}

# ---- strings and privacy manifests -------------------------------------------

# Every lookup in the app goes through Bundle.main, so each catalog becomes
# <locale>.lproj/Localizable.strings at the root of its own bundle.
#   ios_install_strings CATALOG DESTINATION_ROOT
ios_install_strings() {
    run python3 "$STRINGS_CONVERTER" "$1" "$2"
}

ios_install_privacy() {
    run cp "$1" "$2/PrivacyInfo.xcprivacy"
}

# SwiftPM resource bundles hold only what the steps above install at the bundle
# root (compiled strings, privacy manifests), so the copies Swift Bundler makes
# are dead weight - unless something loads them through `Bundle.module`.
#   ios_prune_resource_bundles APP
ios_prune_resource_bundles() {
    local app="$1" name
    if grep -rqs 'Bundle\.module' "$REPO_ROOT/Sources"; then
        warn "Sources use Bundle.module, so the SwiftPM resource bundles stay in the app"
        return 0
    fi
    for name in "${APP_NAME}_${APP_NAME}.bundle" "${APP_NAME}_${KEYBOARD_NAME}.bundle"; do
        if [ "$DRY_RUN" = 1 ] || [ -d "$app/$name" ]; then
            run rm -rf "$app/$name"
        fi
    done
}

# ---- feel shaders --------------------------------------------------------------

# Writes the Metal source embedded in FeelShaderSource.swift (the lines between
# its begin/end marker comments, indentation removed) to OUT.
#   ios_extract_shader_source SWIFT_FILE OUT
ios_extract_shader_source() {
    local swift="$1" out="$2"
    if [ "$DRY_RUN" = 1 ]; then
        note "extract the Metal source between the wurstfinger-feel-shaders markers of $swift into $out"
        return 0
    fi
    awk '/wurstfinger-feel-shaders: begin/ { inside = 1 }
         inside { sub(/^    /, ""); print }
         /wurstfinger-feel-shaders: end/ { inside = 0 }' "$swift" >"$out"
    [ -s "$out" ] || die "no Metal source between the markers in $swift"
}

# Compiles the feel shaders into FeelShaders.metallib with Xcode's Metal
# toolchain and puts it in the app and the keyboard appex, where FeelShaders
# loads it before anything else: no iPhone, however old, then compiles shaders
# at runtime. Without the toolchain (Command Line Tools only, or Xcode 26
# without `xcodebuild -downloadComponent MetalToolchain`) the step is skipped
# with a warning: the app compiles the shaders at runtime instead and caches
# them. METAL and METALLIB override the two tools (the assembly test uses
# stand-ins).
#   ios_compile_shaders APP SDK WORKDIR       SDK is iphoneos or iphonesimulator
ios_compile_shaders() {
    local app="$1" sdk="$2" work="$3"
    local appex="$app/PlugIns/$KEYBOARD_NAME.appex"
    local metal="${METAL:-}" metallib="${METALLIB:-}"
    if [ -z "$metal" ] && xcrun --sdk "$sdk" --find metal >/dev/null 2>&1; then metal="xcrun --sdk $sdk metal"; fi
    if [ -z "$metallib" ] && xcrun --sdk "$sdk" --find metallib >/dev/null 2>&1; then metallib="xcrun --sdk $sdk metallib"; fi
    # Xcode 26 ships `metal` as a shim that only fails when run, until the
    # toolchain is downloaded: found is not enough, it has to answer.
    # shellcheck disable=SC2086
    if [ -n "$metal" ] && [ "$DRY_RUN" != 1 ] && [ -z "${METAL:-}" ] && ! $metal -v >/dev/null 2>&1; then metal=""; fi
    if [ -z "$metal" ] || [ -z "$metallib" ]; then
        warn "no Metal toolchain for $sdk: FeelShaders.metallib is not built (the app compiles the shaders at runtime and caches them)"
        return 0
    fi
    local minimum="-mios-version-min=$MINIMUM_OS_VERSION"
    if [ "$sdk" = iphonesimulator ]; then minimum="-mios-simulator-version-min=$MINIMUM_OS_VERSION"; fi
    run mkdir -p "$work"
    ios_extract_shader_source "$SHADER_SOURCE" "$work/FeelShaders.metal"
    # shellcheck disable=SC2086 # $metal / $metallib may be "xcrun --sdk ... metal"
    run $metal -c "$work/FeelShaders.metal" -o "$work/FeelShaders.air" "$minimum"
    # shellcheck disable=SC2086
    run $metallib "$work/FeelShaders.air" -o "$work/FeelShaders.metallib"
    run cp "$work/FeelShaders.metallib" "$app/FeelShaders.metallib"
    run cp "$work/FeelShaders.metallib" "$appex/FeelShaders.metallib"
}

# ---- icons and accent colour -------------------------------------------------

ios_have_actool() { xcrun --find actool >/dev/null 2>&1; }

# Compiles Bundling/Assets.xcassets (accent colour) and Bundling/AppIcon.icon
# with actool and merges the partial Info.plist into the app's. Without Xcode
# there is no actool: the icon is then written as loose PNGs from
# Bundling/AppIcon.png with sips. Fine for a simulator, but not for an upload
# (the App Store wants the compiled catalog, and no alpha channel).
#   ios_install_icons APP PLATFORM_SDK WORKDIR
# PLATFORM_SDK is iphonesimulator or iphoneos.
ios_install_icons() {
    local app="$1" sdk="$2" work="$3"
    local plist="$app/Info.plist" partial="$work/actool-partial.plist"
    # The macOS-style icon Swift Bundler makes from the PNG means nothing on iOS.
    run rm -f "$app/AppIcon.icns"
    run_soft plutil -remove CFBundleIconFile "$plist"

    if ios_have_actool; then
        note "actool found: compiling the asset catalog and the Icon Composer icon"
        run mkdir -p "$work"
        run xcrun actool \
            --compile "$app" \
            --platform "$sdk" \
            --minimum-deployment-target "$MINIMUM_OS_VERSION" \
            --target-device iphone --target-device ipad \
            --app-icon AppIcon \
            --accent-color AccentColor \
            --enable-on-demand-resources NO \
            --include-all-app-icons \
            --output-partial-info-plist "$partial" \
            "$ICON_ASSETS" "$ICON_COMPOSER"
        # Merge only adds keys that are missing, so clear the icon keys first.
        local key
        for key in CFBundleIconName CFBundleIcons 'CFBundleIcons~ipad'; do
            run_soft plutil -remove "$key" "$plist"
        done
        run /usr/libexec/PlistBuddy -c "Merge $partial" "$plist"
    else
        note "no actool (Xcode is not selected): writing loose PNG icons with sips"
        local spec size name
        for spec in 120:AppIcon60x60@2x 180:AppIcon60x60@3x 152:AppIcon76x76@2x 167:AppIcon83.5x83.5@2x; do
            size="${spec%%:*}"
            name="${spec#*:}"
            run sips -z "$size" "$size" "$ICON_PNG" --out "$app/$name.png"
        done
        run plutil -replace CFBundleIcons -json \
            '{"CFBundlePrimaryIcon":{"CFBundleIconFiles":["AppIcon60x60"],"CFBundleIconName":"AppIcon"}}' "$plist"
        run plutil -replace 'CFBundleIcons~ipad' -json \
            '{"CFBundlePrimaryIcon":{"CFBundleIconFiles":["AppIcon60x60","AppIcon76x76","AppIcon83.5x83.5"],"CFBundleIconName":"AppIcon"}}' "$plist"
    fi
}

# ---- everything that needs no Xcode ------------------------------------------

# Steps 3 to 5 in one call: the extension, both Info.plists, strings, privacy
# manifests, icons.
#   ios_assemble APP APP_ID VERSION BUILD PLATFORM_KIND WORKDIR
# PLATFORM_KIND is `simulator` or `device`.
ios_assemble() {
    local app="$1" app_id="$2" version="$3" build="$4" kind="$5" work="$6"
    local supported sdk
    if [ "$kind" = simulator ]; then
        supported=iPhoneSimulator
        sdk=iphonesimulator
    else
        supported=iPhoneOS
        sdk=iphoneos
    fi
    local appex="$app/PlugIns/$KEYBOARD_NAME.appex"

    step "Assembling $KEYBOARD_NAME.appex"
    ios_assemble_appex "$app" "$app_id" "$version" "$build" "$supported"
    ios_adjust_app_plist "$app/Info.plist" "$version" "$build" "$supported"

    step "Compiling string catalogs into .lproj directories"
    ios_install_strings "$APP_CATALOG" "$app"
    ios_install_strings "$KEYBOARD_CATALOG" "$appex"

    step "Privacy manifests"
    ios_install_privacy "$APP_PRIVACY" "$app"
    ios_install_privacy "$KEYBOARD_PRIVACY" "$appex"
    ios_prune_resource_bundles "$app"

    step "Feel shaders"
    ios_compile_shaders "$app" "$sdk" "$work/shaders"

    step "Icons and accent colour"
    ios_install_icons "$app" "$sdk" "$work"

    step "Toolchain keys"
    ios_add_toolchain_keys "$app/Info.plist" "$sdk"
    ios_add_toolchain_keys "$appex/Info.plist" "$sdk"
}

# ---- signing -------------------------------------------------------------------

# ios_codesign TARGET IDENTITY ENTITLEMENTS_OR_EMPTY KEYCHAIN_OR_EMPTY
# IDENTITY `-` signs ad hoc (simulator). Never `--deep`: each piece of code is
# signed on its own, innermost first, with its own entitlements.
ios_codesign() {
    local target="$1" identity="$2" entitlements="$3" keychain="$4"
    local args=(--force --sign "$identity" --generate-entitlement-der)
    if [ "$identity" = "-" ]; then
        args+=(--timestamp=none)
    else
        args+=(--timestamp)
    fi
    if [ -n "$entitlements" ]; then args+=(--entitlements "$entitlements"); fi
    if [ -n "$keychain" ]; then args+=(--keychain "$keychain"); fi
    run codesign "${args[@]}" "$target"
}

# Signs nested code, then the appex, then the app.
#   ios_sign APP IDENTITY APP_ENTITLEMENTS KEYBOARD_ENTITLEMENTS KEYCHAIN
ios_sign() {
    local app="$1" identity="$2" app_ent="$3" keyboard_ent="$4" keychain="$5"
    local nested
    if [ "$DRY_RUN" = 1 ]; then
        note "dylibs/frameworks under Libraries/ and Frameworks/ (none expected today) would be signed first"
    else
        for nested in "$app"/Frameworks/*.framework "$app"/Frameworks/*.dylib "$app"/Libraries/*.dylib; do
            if [ -e "$nested" ]; then ios_codesign "$nested" "$identity" "" "$keychain"; fi
        done
    fi
    ios_codesign "$app/PlugIns/$KEYBOARD_NAME.appex" "$identity" "$keyboard_ent" "$keychain"
    ios_codesign "$app" "$identity" "$app_ent" "$keychain"
}

# Plist and signature checks. `--deep` belongs to verification only.
ios_verify() {
    local app="$1" signed="$2" appex="$1/PlugIns/$KEYBOARD_NAME.appex"
    run plutil -lint "$app/Info.plist" "$appex/Info.plist"
    if [ "$signed" = 1 ]; then
        run codesign --verify --deep --strict --verbose=2 "$app"
    fi
}

# ---- device signing inputs --------------------------------------------------

# Resolves an identity (name fragment or SHA-1) to the SHA-1 codesign wants.
#   ios_resolve_identity QUERY [KEYCHAIN]
ios_resolve_identity() {
    local query="$1" keychain="${2:-}" listing
    if [ -n "$keychain" ]; then
        listing="$(security find-identity -v -p codesigning "$keychain")"
    else
        listing="$(security find-identity -v -p codesigning)"
    fi
    printf '%s\n' "$listing" | awk -v q="$query" '
        $1 ~ /^[0-9]+\)$/ && (index($0, q) > 0) { print $2; exit }'
}

# Entitlements to sign with: the repository's file, plus the identity-bearing
# keys the provisioning profile dictates (application-identifier, team id,
# get-task-allow). The app group stays whatever Bundling/*.entitlements says and
# must be one the profile grants.
#   ios_merge_entitlements BASE PROFILE_ENTITLEMENTS OUT
ios_merge_entitlements() {
    local base="$1" granted="$2" out="$3" key type value
    run cp "$base" "$out"
    run chmod u+w "$out"
    if [ "$DRY_RUN" = 1 ]; then
        note "copy application-identifier, com.apple.developer.team-identifier, get-task-allow and beta-reports-active from the profile into $out"
        return 0
    fi
    for key in application-identifier 'com\.apple\.developer\.team-identifier' get-task-allow beta-reports-active; do
        type="$(plutil -type "$key" "$granted" 2>/dev/null)" || continue
        value="$(plist_get "$granted" "$key")"
        case "$type" in
            bool) plutil -replace "$key" -bool "$value" "$out" ;;
            string) plutil -replace "$key" -string "$value" "$out" ;;
        esac
    done
}

# Writes the profile's Entitlements dictionary to OUT (needs `security`, so a Mac).
#   ios_profile_entitlements PROFILE OUT
ios_profile_entitlements() {
    local profile="$1" out="$2" decoded="$2.profile.plist"
    run security cms -D -i "$profile" -o "$decoded"
    run plutil -extract Entitlements xml1 -o "$out" "$decoded"
}

ios_embed_profile() {
    run cp "$1" "$2/embedded.mobileprovision"
}

# ---- sideload inputs ---------------------------------------------------------

# A sideloader (Impactor, SideStore, AltStore) signs the app with the user's own
# Apple ID and replaces the signature and the profile, so the build only has to
# get through Swift Bundler, which will not build an iOS app without an identity
# and a profile. This makes throwaway ones: a self-signed code-signing
# certificate in a temporary keychain, and one CMS-signed profile per bundle
# that grants the repository's app group and nothing else. None of it is
# trusted by a device; it never leaves WORK.
#   ios_make_sideload_inputs WORK
# Sets SIDELOAD_KEYCHAIN, SIDELOAD_IDENTITY, APP_PROFILE and KEYBOARD_PROFILE;
# ios_drop_sideload_inputs undoes the keychain part.
ios_make_sideload_inputs() {
    local work="$1" team=SIDELOAD00 password cert_name="Wurstfinger Sideload"
    SIDELOAD_KEYCHAIN="$work/sideload.keychain-db"
    APP_PROFILE="$work/app.mobileprovision"
    KEYBOARD_PROFILE="$work/keyboard.mobileprovision"
    if [ "$DRY_RUN" = 1 ]; then
        note "make a self-signed code-signing certificate in a temporary keychain, and two profiles granting $(ios_app_group)"
        SIDELOAD_IDENTITY="<sideload identity>"
        return 0
    fi
    run mkdir -p "$work"
    password="$(uuidgen)"
    printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=%s\n[ext]\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' \
        "$cert_name" >"$work/cert.cnf"
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 2 -config "$work/cert.cnf" \
        -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
        -out "$work/identity.p12" -passout "pass:$password" 2>/dev/null
    security create-keychain -p "$password" "$SIDELOAD_KEYCHAIN"
    security set-keychain-settings "$SIDELOAD_KEYCHAIN"
    security unlock-keychain -p "$password" "$SIDELOAD_KEYCHAIN"
    security import "$work/identity.p12" -k "$SIDELOAD_KEYCHAIN" -P "$password" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$SIDELOAD_KEYCHAIN" >/dev/null 2>&1 || true
    # codesign only finds an identity in a keychain on the search list.
    SIDELOAD_PREVIOUS_KEYCHAINS="$(security list-keychains -d user | tr -d '"' | tr '\n' ' ')"
    # shellcheck disable=SC2086
    security list-keychains -d user -s "$SIDELOAD_KEYCHAIN" $SIDELOAD_PREVIOUS_KEYCHAINS
    # A self-signed certificate is not "valid" to find-identity, so name the
    # certificate by its hash instead of asking for valid identities only.
    SIDELOAD_IDENTITY="$(security find-certificate -c "$cert_name" -Z "$SIDELOAD_KEYCHAIN" | awk '/^SHA-1 hash:/ { print $3; exit }')"
    [ -n "$SIDELOAD_IDENTITY" ] || die "could not find the throwaway certificate in $SIDELOAD_KEYCHAIN"
    ios_write_sideload_profile "$APP_PROFILE" "$APP_ID" "$team" "$work"
    ios_write_sideload_profile "$KEYBOARD_PROFILE" "$APP_ID.keyboard" "$team" "$work"
}

# Puts the search list back and deletes the throwaway keychain.
ios_drop_sideload_inputs() {
    [ "$DRY_RUN" != 1 ] || return 0
    [ -n "${SIDELOAD_KEYCHAIN:-}" ] || return 0
    if [ -n "${SIDELOAD_PREVIOUS_KEYCHAINS:-}" ]; then
        # shellcheck disable=SC2086
        security list-keychains -d user -s $SIDELOAD_PREVIOUS_KEYCHAINS || true
    fi
    security delete-keychain "$SIDELOAD_KEYCHAIN" 2>/dev/null || true
}

ios_app_group() {
    plist_get "$APP_ENTITLEMENTS" 'com\.apple\.security\.application-groups.0'
}

# ios_write_sideload_profile OUT BUNDLE_ID TEAM WORK
ios_write_sideload_profile() {
    local out="$1" bundle_id="$2" team="$3" work="$4" plist group
    plist="$work/$(basename "$out").plist"
    group="$(ios_app_group)"
    plutil -create xml1 "$plist"
    plutil -insert Name -string "Wurstfinger sideload" "$plist"
    plutil -insert UUID -string "$(uuidgen)" "$plist"
    plutil -insert TeamIdentifier -json "[\"$team\"]" "$plist"
    plutil -insert ApplicationIdentifierPrefix -json "[\"$team\"]" "$plist"
    plutil -insert Platform -json '["iOS"]' "$plist"
    plutil -insert CreationDate -date "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "$plist"
    plutil -insert ExpirationDate -date "$(/bin/date -u -v+1d +%Y-%m-%dT%H:%M:%SZ)" "$plist"
    plutil -insert Entitlements -json '{}' "$plist"
    plutil -insert Entitlements.application-identifier -string "$team.$bundle_id" "$plist"
    plutil -insert 'Entitlements.com\.apple\.developer\.team-identifier' -string "$team" "$plist"
    plutil -insert Entitlements.get-task-allow -bool true "$plist"
    plutil -insert 'Entitlements.com\.apple\.security\.application-groups' -json "[\"$group\"]" "$plist"
    # openssl signs the CMS envelope: `security cms -S` wants a trusted identity.
    /usr/bin/openssl cms -sign -binary -outform DER -nodetach -signer "$work/cert.pem" -inkey "$work/key.pem" \
        -in "$plist" -out "$out"
}

# ---- packaging -------------------------------------------------------------------

# Zips Payload/Wurstfinger.app into an IPA.
#   ios_make_ipa APP OUT_IPA WORKDIR
ios_make_ipa() {
    local app="$1" ipa="$2" work="$3" absolute
    case "$ipa" in
        /*) absolute="$ipa" ;;
        *) absolute="$PWD/$ipa" ;;
    esac
    run mkdir -p "$(dirname "$absolute")"
    run rm -rf "$work/ipa" "$absolute"
    run mkdir -p "$work/ipa/Payload"
    run ditto "$app" "$work/ipa/Payload/$APP_NAME.app"
    if [ "$DRY_RUN" = 1 ]; then
        printf '+ (cd %q && zip -qry %q Payload)\n' "$work/ipa" "$absolute"
    else
        (cd "$work/ipa" && zip -qry "$absolute" Payload)
    fi
}
