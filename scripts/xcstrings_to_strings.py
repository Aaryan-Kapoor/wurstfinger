#!/usr/bin/env python3
"""Compile a String Catalog (.xcstrings) into per-locale .strings/.stringsdict.

Xcode does this while building an app target. The iOS bundle assembled by
scripts/bundle-ios.sh is not built by Xcode's resource pipeline, and every
lookup in the app goes through `Bundle.main`, so the catalogs have to end up as

    <output>/<locale>.lproj/Localizable.strings
    <output>/<locale>.lproj/Localizable.stringsdict   (only when plurals exist)

at the root of the .app (and of the .appex for the keyboard's own catalog).

Rules, matching what Xcode produces closely enough for runtime lookups:

- The source language has no explicit localization in a catalog; its value is
  the key itself, so the source locale gets `"key" = "key";`.
- A locale that lacks a translation for a key falls back to the source string,
  so a partly translated catalog never shows a raw lookup failure.
- Entries marked `"shouldTranslate": false` are skipped (the caller gets the
  key back, which is what such entries are for).
- `variations.plural` becomes a .stringsdict entry. `variations.device` is
  flattened to the iPhone (else "other") variant for the .strings file.
- Only the standard library is used, and the code stays Python 3.9 compatible.

Usage:
    xcstrings_to_strings.py CATALOG OUTPUT_DIR [--locale LOCALE ...] [--table NAME]
    xcstrings_to_strings.py CATALOG --list-locales
"""
from __future__ import annotations

import argparse
import json
import plistlib
import re
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

PLURAL_CATEGORIES = ("zero", "one", "two", "few", "many", "other")
FORMAT_SPECIFIER = re.compile(
    r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?((?:hh|h|ll|l|q|L|z|t|j)?[@dDuUxXoOfeEgGcCsSpaA])"
)


class CatalogError(Exception):
    """The catalog is not something this converter understands."""


class Compiled:
    """The compiled form of one locale: flat strings plus plural entries."""

    def __init__(self) -> None:
        self.strings: Dict[str, str] = {}
        self.plurals: Dict[str, Dict[str, Any]] = {}


def load_catalog(path: Path) -> Dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        catalog = json.load(handle)
    if not isinstance(catalog, dict) or "strings" not in catalog:
        raise CatalogError("%s is not a string catalog (no `strings` table)" % path)
    return catalog


def locales_in(catalog: Dict[str, Any]) -> List[str]:
    """The source language plus every locale any entry localizes into."""
    found = {catalog.get("sourceLanguage", "en")}
    for entry in catalog["strings"].values():
        found.update(entry.get("localizations", {}).keys())
    return sorted(found)


def _unit_value(unit: Optional[Dict[str, Any]]) -> Optional[str]:
    if not isinstance(unit, dict):
        return None
    value = unit.get("value")
    if isinstance(value, str) and value != "":
        return value
    return None


def _plural_forms(variations: Dict[str, Any]) -> Optional[Dict[str, str]]:
    plural = variations.get("plural")
    if not isinstance(plural, dict):
        return None
    forms = {}
    for category in PLURAL_CATEGORIES:
        value = _unit_value(plural.get(category, {}).get("stringUnit"))
        if value is not None:
            forms[category] = value
    return forms or None


def _value_type(*samples: str) -> str:
    """The printf length+type (`lld`, `@`, ...) of the first specifier found."""
    for sample in samples:
        match = FORMAT_SPECIFIER.search(sample)
        if match:
            return match.group(1)
    return "lld"


def _plural_entry(forms: Dict[str, str], value_type: str) -> Dict[str, Any]:
    entry = {
        "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
        "NSStringFormatValueTypeKey": value_type,
    }
    entry.update(forms)
    if "other" not in entry:
        # CLDR requires `other`; reuse the last form defined rather than fail.
        entry["other"] = list(forms.values())[-1]
    return entry


def _flat_device_value(variations: Dict[str, Any]) -> Optional[str]:
    device = variations.get("device")
    if not isinstance(device, dict):
        return None
    for name in ("iphone", "other"):
        value = _unit_value(device.get(name, {}).get("stringUnit"))
        if value is not None:
            return value
    return None


def compile_locale(catalog: Dict[str, Any], locale: str) -> Compiled:
    source = catalog.get("sourceLanguage", "en")
    result = Compiled()
    for key, entry in sorted(catalog["strings"].items()):
        if entry.get("shouldTranslate") is False:
            continue
        localization = entry.get("localizations", {}).get(locale)
        if localization is None and locale != source:
            localization = entry.get("localizations", {}).get(source)
        if localization is None:
            # Source locale without an explicit entry, or a locale that skipped
            # this key: the key is the source string.
            localization = {}

        variations = localization.get("variations") or {}
        substitutions = localization.get("substitutions") or {}

        forms = _plural_forms(variations)
        if forms is not None:
            sample = forms.get("other") or next(iter(forms.values()))
            result.plurals[key] = {
                "NSStringLocalizedFormatKey": "%#@arg@",
                "arg": _plural_entry(forms, _value_type(sample)),
            }
            result.strings[key] = forms.get("other", sample)
            continue

        if substitutions:
            template = _unit_value(localization.get("stringUnit")) or key
            record = {"NSStringLocalizedFormatKey": template}
            for name, substitution in substitutions.items():
                sub_forms = _plural_forms(substitution.get("variations") or {})
                if sub_forms is None:
                    raise CatalogError(
                        "%r: substitution %r has no plural variations" % (key, name)
                    )
                spec = substitution.get("formatSpecifier") or _value_type(
                    *sub_forms.values()
                )
                record[name] = _plural_entry(sub_forms, spec)
            result.plurals[key] = record
            result.strings[key] = template
            continue

        value = _unit_value(localization.get("stringUnit"))
        if value is None:
            value = _flat_device_value(variations)
        result.strings[key] = value if value is not None else key
    return result


def escape(text: str) -> str:
    out = []
    for char in text:
        if char == "\\":
            out.append("\\\\")
        elif char == '"':
            out.append('\\"')
        elif char == "\n":
            out.append("\\n")
        elif char == "\r":
            out.append("\\r")
        elif char == "\t":
            out.append("\\t")
        else:
            out.append(char)
    return "".join(out)


def render_strings(strings: Dict[str, str]) -> str:
    lines = ["/* Generated by scripts/xcstrings_to_strings.py. Do not edit. */"]
    for key in sorted(strings):
        lines.append('"%s" = "%s";' % (escape(key), escape(strings[key])))
    return "\n".join(lines) + "\n"


def write_locale(
    compiled: Compiled, destination: Path, table: str
) -> Tuple[Path, Optional[Path]]:
    destination.mkdir(parents=True, exist_ok=True)
    strings_file = destination / ("%s.strings" % table)
    strings_file.write_text(render_strings(compiled.strings), encoding="utf-8")
    dict_file = None
    if compiled.plurals:
        dict_file = destination / ("%s.stringsdict" % table)
        with dict_file.open("wb") as handle:
            plistlib.dump(compiled.plurals, handle, fmt=plistlib.FMT_XML, sort_keys=True)
    return strings_file, dict_file


def convert(
    catalog_path: Path,
    output: Path,
    locales: Optional[Iterable[str]] = None,
    table: Optional[str] = None,
) -> List[str]:
    """Write `<locale>.lproj` directories; return the locales written."""
    catalog = load_catalog(catalog_path)
    wanted = sorted(set(locales)) if locales else locales_in(catalog)
    table_name = table or catalog_path.stem
    for locale in wanted:
        write_locale(compile_locale(catalog, locale), output / ("%s.lproj" % locale), table_name)
    return wanted


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("catalog", type=Path, help="path to a .xcstrings file")
    parser.add_argument("output", type=Path, nargs="?", help="directory to write <locale>.lproj into")
    parser.add_argument("--locale", action="append", help="only this locale (repeatable)")
    parser.add_argument("--table", help="table name (default: the catalog's file name)")
    parser.add_argument("--list-locales", action="store_true", help="print the catalog's locales and exit")
    args = parser.parse_args(argv)

    try:
        if args.list_locales:
            print("\n".join(locales_in(load_catalog(args.catalog))))
            return 0
        if args.output is None:
            parser.error("OUTPUT_DIR is required unless --list-locales is given")
        written = convert(args.catalog, args.output, args.locale, args.table)
    except (CatalogError, OSError, ValueError) as error:
        print("xcstrings_to_strings: %s" % error, file=sys.stderr)
        return 1
    print("%s: wrote %d locales to %s" % (args.catalog.name, len(written), args.output))
    return 0


if __name__ == "__main__":
    sys.exit(main())
