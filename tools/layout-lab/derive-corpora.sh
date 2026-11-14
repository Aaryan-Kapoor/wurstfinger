#!/bin/bash
# Rebuilds tools/layout-lab/corpora/*.tsv from the FrequencyWords 2018 word lists.
#
#   tools/layout-lab/derive-corpora.sh [RAW_DIR]
#
# RAW_DIR holds <code>_full.txt downloaded from
#   https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/<code>/<code>_full.txt
# (not checked in: only the derived tables are). Needs a release build of layoutlab:
#   swift build -c release --product layoutlab
set -euo pipefail
RAW="${1:-raw}"
LAB="${LAB:-.build/release/layoutlab}"
OUT="$(dirname "$0")/corpora"
SOURCE="source=OpenSubtitles 2018 via FrequencyWords 2018 (hermitdave); license=CC-BY-SA-4.0; url=https://github.com/hermitdave/FrequencyWords"

# layout id : FrequencyWords code
for pair in en_US:en de_DE:de fr_FR:fr es_ES:es ca_ES:ca it_IT:it pt_PT:pt pl_PL:pl hr_HR:hr sv_SE:sv \
            fi_FI:fi et_EE:et tl_PH:tl vi_VN:vi ru_RU:ru uk_UA:uk el_GR:el; do
  id="${pair%%:*}"; code="${pair##*:}"
  sha="$(shasum -a 256 "$RAW/${code}_full.txt" | cut -d' ' -f1)"
  "$LAB" derive --language "$id" --words "$RAW/${code}_full.txt" --out "$OUT/$id.tsv" \
    --source "$SOURCE; list=${code}_full.txt; sha256=$sha"
done
