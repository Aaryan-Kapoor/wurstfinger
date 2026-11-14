"""Tests for xcstrings_to_strings.py (Python 3.9+, standard library only)."""
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import xcstrings_to_strings as converter  # noqa: E402


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


CATALOG = {
    "sourceLanguage": "en",
    "version": "1.0",
    "strings": {
        "Settings": {"localizations": {"de": unit("Einstellungen"), "fr": unit("Réglages")}},
        "Only German": {"localizations": {"de": unit("Nur Deutsch")}},
        "Say \"hi\"\nnow": {"localizations": {"de": unit('Sag "hi"\njetzt')}},
        "Wurstfinger": {"shouldTranslate": False},
        "Path \\ here": {"localizations": {"de": unit("Pfad \\ hier")}},
        "Empty": {"localizations": {"de": {"stringUnit": {"state": "new", "value": ""}}}},
    },
}

PLURAL_CATALOG = {
    "sourceLanguage": "en",
    "version": "1.0",
    "strings": {
        "%lld keys": {
            "localizations": {
                "en": {
                    "variations": {
                        "plural": {
                            "one": unit("%lld key"),
                            "other": unit("%lld keys"),
                        }
                    }
                },
                "de": {
                    "variations": {
                        "plural": {
                            "one": unit("%lld Taste"),
                            "other": unit("%lld Tasten"),
                        }
                    }
                },
            }
        }
    },
}


class ConverterTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def write_catalog(self, catalog, name="Localizable.xcstrings"):
        path = self.root / name
        path.write_text(json.dumps(catalog), encoding="utf-8")
        return path

    def test_locales_include_source_and_every_translation(self):
        catalog = converter.load_catalog(self.write_catalog(CATALOG))
        self.assertEqual(converter.locales_in(catalog), ["de", "en", "fr"])

    def test_writes_one_lproj_per_locale(self):
        out = self.root / "out"
        converter.convert(self.write_catalog(CATALOG), out)
        self.assertEqual(
            sorted(p.name for p in out.iterdir()), ["de.lproj", "en.lproj", "fr.lproj"]
        )
        for lproj in out.iterdir():
            self.assertTrue((lproj / "Localizable.strings").is_file())
            self.assertFalse((lproj / "Localizable.stringsdict").exists())

    def test_translation_is_used_and_source_is_the_fallback(self):
        out = self.root / "out"
        converter.convert(self.write_catalog(CATALOG), out)
        german = (out / "de.lproj/Localizable.strings").read_text(encoding="utf-8")
        french = (out / "fr.lproj/Localizable.strings").read_text(encoding="utf-8")
        english = (out / "en.lproj/Localizable.strings").read_text(encoding="utf-8")
        self.assertIn('"Settings" = "Einstellungen";', german)
        self.assertIn('"Only German" = "Nur Deutsch";', german)
        self.assertIn('"Settings" = "Réglages";', french)
        # French has no entry for "Only German": the key (source string) stands in.
        self.assertIn('"Only German" = "Only German";', french)
        self.assertIn('"Settings" = "Settings";', english)

    def test_empty_translation_falls_back_to_source(self):
        out = self.root / "out"
        converter.convert(self.write_catalog(CATALOG), out)
        german = (out / "de.lproj/Localizable.strings").read_text(encoding="utf-8")
        self.assertIn('"Empty" = "Empty";', german)

    def test_should_translate_false_is_skipped(self):
        out = self.root / "out"
        converter.convert(self.write_catalog(CATALOG), out)
        for lproj in out.iterdir():
            text = (lproj / "Localizable.strings").read_text(encoding="utf-8")
            self.assertNotIn('"Wurstfinger"', text)

    def test_escaping_round_trips_through_plutil_when_available(self):
        out = self.root / "out"
        converter.convert(self.write_catalog(CATALOG), out, locales=["de"])
        text = (out / "de.lproj/Localizable.strings").read_text(encoding="utf-8")
        self.assertIn(r'"Say \"hi\"\nnow" = "Sag \"hi\"\njetzt";', text)
        self.assertIn(r'"Path \\ here" = "Pfad \\ hier";', text)
        try:
            result = subprocess.run(
                ["plutil", "-lint", str(out / "de.lproj/Localizable.strings")],
                capture_output=True,
                text=True,
            )
        except FileNotFoundError:
            self.skipTest("plutil is not available")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_locale_filter(self):
        out = self.root / "out"
        written = converter.convert(self.write_catalog(CATALOG), out, locales=["de"])
        self.assertEqual(written, ["de"])
        self.assertEqual([p.name for p in out.iterdir()], ["de.lproj"])

    def test_table_name_defaults_to_the_catalog_name(self):
        out = self.root / "out"
        converter.convert(self.write_catalog(CATALOG, "Other.xcstrings"), out, locales=["de"])
        self.assertTrue((out / "de.lproj/Other.strings").is_file())

    def test_plural_variations_become_a_stringsdict(self):
        out = self.root / "out"
        converter.convert(self.write_catalog(PLURAL_CATALOG), out)
        with (out / "de.lproj/Localizable.stringsdict").open("rb") as handle:
            data = plistlib.load(handle)
        entry = data["%lld keys"]
        self.assertEqual(entry["NSStringLocalizedFormatKey"], "%#@arg@")
        self.assertEqual(entry["arg"]["NSStringFormatSpecTypeKey"], "NSStringPluralRuleType")
        self.assertEqual(entry["arg"]["NSStringFormatValueTypeKey"], "lld")
        self.assertEqual(entry["arg"]["one"], "%lld Taste")
        self.assertEqual(entry["arg"]["other"], "%lld Tasten")
        # The .strings file still carries the key so a plain lookup resolves.
        strings = (out / "de.lproj/Localizable.strings").read_text(encoding="utf-8")
        self.assertIn('"%lld keys" = "%lld Tasten";', strings)

    def test_plural_in_source_locale(self):
        out = self.root / "out"
        converter.convert(self.write_catalog(PLURAL_CATALOG), out, locales=["en"])
        with (out / "en.lproj/Localizable.stringsdict").open("rb") as handle:
            data = plistlib.load(handle)
        self.assertEqual(data["%lld keys"]["arg"]["one"], "%lld key")

    def test_device_variation_uses_iphone(self):
        catalog = {
            "sourceLanguage": "en",
            "strings": {
                "Tap": {
                    "localizations": {
                        "de": {
                            "variations": {
                                "device": {
                                    "iphone": unit("Tippen"),
                                    "ipad": unit("Klicken"),
                                    "other": unit("Auswahl"),
                                }
                            }
                        }
                    }
                }
            },
        }
        out = self.root / "out"
        converter.convert(self.write_catalog(catalog), out, locales=["de"])
        text = (out / "de.lproj/Localizable.strings").read_text(encoding="utf-8")
        self.assertIn('"Tap" = "Tippen";', text)

    def test_rejects_a_file_that_is_not_a_catalog(self):
        path = self.write_catalog({"nope": True})
        with self.assertRaises(converter.CatalogError):
            converter.load_catalog(path)

    def test_command_line_exit_codes(self):
        catalog = self.write_catalog(CATALOG)
        out = self.root / "out"
        self.assertEqual(converter.main([str(catalog), str(out)]), 0)
        self.assertEqual(converter.main([str(self.root / "missing.xcstrings"), str(out)]), 1)

    def test_the_repository_catalogs_convert(self):
        repository = Path(__file__).resolve().parent.parent
        catalogs = sorted(repository.glob("Sources/*/Resources/Localizable.xcstrings"))
        if not catalogs:
            self.skipTest("no catalogs in this checkout")
        for catalog in catalogs:
            out = self.root / catalog.parent.parent.name
            locales = converter.convert(catalog, out)
            self.assertIn("de", locales)
            for locale in locales:
                self.assertTrue((out / ("%s.lproj" % locale) / "Localizable.strings").is_file())


if __name__ == "__main__":
    unittest.main()
