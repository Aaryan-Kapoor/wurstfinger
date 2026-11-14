# Localization Scope

The app UI ships in 23 languages: English plus the 22 the catalogs
translate into (`de fr es it ru pl sv fi hr he vi fil el pt uk ar fa ur th hi
ja ko`). This document records where the strings live and which screens are
deliberately left in English.

## Catalogs

| Catalog | Holds |
| --- | --- |
| `Sources/Wurstfinger/Resources/Localizable.xcstrings` | Everything the host app displays: settings, onboarding, the test area — plus the keyboard's own strings, because the app renders real keyboards in its previews and showcase. |
| `Sources/WurstfingerKeyboard/Resources/Localizable.xcstrings` | Only the strings the keyboard extension itself displays, today the VoiceOver labels of the utility keys. |

The code in `Sources/WurstfingerKit/Keyboard/` is linked into **both**
executables, so a string used there is looked up in whichever bundle is running
and must exist in **both** catalogs. A string that only ever appears in
settings therefore belongs in the host app's catalog — that is why
`KeyboardStyle.displayName` lives in `StyleSettingsView.swift` and
`HapticIntensityLevel.displayName` in `HapticSettingsView.swift`, next to the
screens that show them, rather than next to the enums in
`Sources/WurstfingerKit/Keyboard/Settings/`.

Every lookup goes through `Bundle.main`. On iOS, `scripts/bundle-ios.sh`
therefore compiles each catalog into `<locale>.lproj/Localizable.strings` at the
root of its own bundle (the app and the keyboard extension) with
`scripts/xcstrings_to_strings.py`, instead of relying on SwiftPM resource
bundles. On macOS, Swift Bundler compiles the app's catalog itself.

## English-only screens

The Expert section is English by decision. Its vocabulary — jitter threshold,
angular span, oriented compactness — cannot be reviewed by anyone on the team
in 22 translations, and the whole section is a diagnostic tool for power users
behind an acknowledgement gate:

- `ExpertSettingsView`
- `GesturePlaygroundView` (reachable only from the Expert screen)
- `KeyboardHealthView` (reachable only from the Expert screen)

Two more screens are English today, inherited rather than decided — worth
revisiting:

- `ImprintView` — legal notice, kept in a single authoritative wording. It is a
  § 5 DDG notice for a German company, currently shown to German users in
  English.
- `AppStoreScreenshotView` — marketing screenshot chrome, not app UI.

## What the tests guard

- `LocalizationCompletenessTests` — every catalog entry is translated into all
  22 languages, with no empty values, stale states, or stray languages.
- `LocalizationUsageTests` — every `String(localized:)` key exists in the
  catalog of every target that compiles the file using it.
- `LocalizedViewLiteralTests` — every literal a view hands to a
  `LocalizedStringKey` parameter exists in a catalog, unless its file is listed
  in `englishOnlyViewFiles` with a reason. Adding an English-only screen means
  adding it there and to the list above.
