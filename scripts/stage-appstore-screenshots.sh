#!/usr/bin/env bash
#
# stage-appstore-screenshots.sh
# Lays rendered App Store screenshots out the way `deliver` uploads them:
#
#   fastlane/screenshots/<locale>/<size>_<NN>.png
#
# deliver infers the device class from the pixel dimensions, so the files must
# sit directly below the locale folder (nested folders are silently ignored).
# The size prefix is read from each PNG's width, and the number follows the
# files' sorted order within its size:
#
#   69  1320, 1290 or 1260 px wide   (6.9")
#   65  1284 or 1242 px wide         (6.5")
#
# The screenshot content is locale independent (the chat mock is English), so
# the en-US set is mirrored to the other locales.
#
# Usage: scripts/stage-appstore-screenshots.sh SOURCE_DIR [DESTINATION_ROOT]
#   SOURCE_DIR        PNGs from `swift run WurstfingerSnapshots --out SOURCE_DIR`
#   DESTINATION_ROOT  default: fastlane/screenshots

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="${1:-}"
DESTINATION="${2:-$SCRIPT_DIR/../fastlane/screenshots}"
PRIMARY_LOCALE="en-US"
MIRROR_LOCALES=("de-DE")

if [ -z "$SOURCE" ] || [ ! -d "$SOURCE" ]; then
    echo "usage: $0 SOURCE_DIR [DESTINATION_ROOT]" >&2
    exit 2
fi

FILES="$(find "$SOURCE" -name '*.png' -type f | sort)"
if [ -z "$FILES" ]; then
    echo "error: no PNG files under $SOURCE" >&2
    exit 1
fi

# Validate every size before touching the destination: a half-staged set must
# never replace what is committed (deliver overwrites the store's screenshots).
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/appstore-screenshots.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
COUNT_69=0
COUNT_65=0
while IFS= read -r file; do
    width="$(sips -g pixelWidth "$file" | awk '/pixelWidth/ { print $2 }')"
    case "$width" in
        1320 | 1290 | 1260)
            COUNT_69=$((COUNT_69 + 1))
            cp "$file" "$STAGE/$(printf '69_%02d.png' "$COUNT_69")"
            ;;
        1284 | 1242)
            COUNT_65=$((COUNT_65 + 1))
            cp "$file" "$STAGE/$(printf '65_%02d.png' "$COUNT_65")"
            ;;
        *)
            echo "error: $file is $width px wide, which is no App Store screenshot size this script knows" >&2
            exit 1
            ;;
    esac
done <<<"$FILES"

PRIMARY_DIR="$DESTINATION/$PRIMARY_LOCALE"
mkdir -p "$PRIMARY_DIR"
rm -f "$PRIMARY_DIR"/*.png
cp "$STAGE"/*.png "$PRIMARY_DIR/"
for locale in "${MIRROR_LOCALES[@]}"; do
    mkdir -p "$DESTINATION/$locale"
    rm -f "$DESTINATION/$locale"/*.png
    cp "$PRIMARY_DIR"/*.png "$DESTINATION/$locale/"
done

echo "Staged $COUNT_69 x 6.9\" and $COUNT_65 x 6.5\" screenshots into $DESTINATION/{$PRIMARY_LOCALE,${MIRROR_LOCALES[*]}}"
