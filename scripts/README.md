# Scripts

Developer tooling: the iOS bundling scripts, screenshot staging, the naming
checker, and the git hooks that run them.

## bundle-ios.sh

Builds the iOS app with Swift Bundler and assembles the keyboard extension that
Swift Bundler has no support for. Needs Xcode (iOS SDK, simulator, `actool`).

```bash
scripts/bundle-ios.sh --simulator --install --launch      # build, install and start on a simulator
scripts/bundle-ios.sh --simulator "iPhone 16" --install   # a named simulator
scripts/bundle-ios.sh --dry-run                           # print every command, run none
scripts/bundle-ios.sh --device --configuration release --ipa build/Wurstfinger.ipa \
    --identity "Apple Distribution" --build-number 42 \
    --app-profile app.mobileprovision --keyboard-profile keyboard.mobileprovision
```

The steps, in order:

1. Preflight: the iOS SDK must be installed, else the script exits and says that
   iOS needs Xcode.
2. `swift bundler bundle Wurstfinger -p iOSSimulator|iOS`. The iOS overlay in
   `Bundler.toml` lists `WurstfingerKeyboard` as a dependency, so Swift Bundler
   builds it too and copies the executable next to the app's.
3. The executable moves into `PlugIns/WurstfingerKeyboard.appex`, whose
   `Info.plist` is rendered from `Bundling/Keyboard-Info.plist` (bundle id,
   version and build, executable, platform, minimum OS).
4. Both `Localizable.xcstrings` catalogs become `<locale>.lproj/Localizable.strings`
   (plus `.stringsdict` for plurals) at the root of the app and of the appex,
   with `xcstrings_to_strings.py`: every lookup goes through `Bundle.main`, so
   it cannot rely on SwiftPM resource bundles. The privacy manifests are copied
   to the same roots, and the SwiftPM resource bundles are dropped (unless
   `Sources` starts using `Bundle.module`).
5. Icons: `actool` compiles `Bundling/Assets.xcassets` and
   `Bundling/AppIcon.icon` and its partial `Info.plist` is merged into the
   app's. Without `actool`, loose PNGs are cut from `Bundling/AppIcon.png` with
   `sips`, which is fine for a simulator but not for an upload.
6. Signing: the extension first, then the app, each with its own entitlements,
   never `--deep`. The simulator uses an ad-hoc signature; `--device` signs with
   `--identity`, embeds the two provisioning profiles, and merges the profile's
   team and application identifiers into the entitlements.
7. `--install`/`--launch` use `xcrun simctl`; `--ipa OUT` zips
   `Payload/Wurstfinger.app`.
8. `plutil -lint` on both `Info.plist`s and `codesign --verify --deep --strict`.

The functions live in `lib/ios-bundle.sh`. `SWIFT_BUNDLER` names the Swift
Bundler executable if it is not `swift-bundler` on `PATH`. The scripts run on
the bash 3.2 that macOS ships.

## test-bundle-assembly.sh

Runs steps 3 to 6 (extension, strings, privacy, icons, ad-hoc signing) on a fake
app layout, with placeholder executables, and asserts the result: the structure,
both `Info.plist`s, a valid `Localizable.strings` for every locale of both
catalogs, and the signatures. It also dry-runs `bundle-ios.sh`. Needs macOS but
no Xcode; CI runs it before the real simulator build.

```bash
scripts/test-bundle-assembly.sh          # --keep leaves the fake app behind
```

## xcstrings_to_strings.py

Compiles a String Catalog into `<locale>.lproj/Localizable.strings` and
`Localizable.stringsdict`, the way Xcode would. Source strings stand in for
missing translations, `shouldTranslate: false` entries are skipped, and plural
variations become `.stringsdict`. Python 3.9+, standard library only.

```bash
python3 scripts/xcstrings_to_strings.py Sources/Wurstfinger/Resources/Localizable.xcstrings out/
python3 scripts/xcstrings_to_strings.py Sources/Wurstfinger/Resources/Localizable.xcstrings --list-locales
python3 -m unittest discover -s scripts -p 'test_xcstrings*.py'
```

## stage-appstore-screenshots.sh

Lays PNGs rendered by `swift run WurstfingerSnapshots --out DIR` out as
`fastlane/screenshots/<locale>/<size>_<NN>.png`, the flat layout `deliver`
uploads. The size prefix (`69` for 6.9", `65` for 6.5") comes from each PNG's
pixel width, so an unexpected size fails the script instead of shipping.

```bash
scripts/stage-appstore-screenshots.sh DIR [fastlane/screenshots]
```

Screenshots are rendered on the Mac with `ImageRenderer`: no simulator, no UI
tests. The old simulator scripts (`generate-screenshots.sh`,
`generate-appstore-screenshots.sh`, `lib/simulator-capture.sh`) are gone.

## check_naming.py

Checks Swift identifiers against the domain vocabulary in `glossary.toml` and
reports every spelling that vocabulary rejects. Needs Python 3.11 or newer for
`tomllib`; no third-party packages.

```bash
python3 scripts/check_naming.py check            # what CI and the pre-commit hook run
python3 scripts/check_naming.py list <path>      # the findings in one file or directory
python3 scripts/check_naming.py list --statistics # a tally per rejected spelling
python3 scripts/check_naming.py update           # re-freeze the budget after a rename
python3 scripts/check_naming.py render           # regenerate docs/GLOSSARY.md sections 7-9
python3 scripts/check_naming.py sync-lint        # regenerate the glossary_* rules in .swiftlint.yml
```

A backlog, while there is one, lives in `.naming-budget.json`: one entry per
file, holding the number of rejected names it carries. A file may not exceed its
entry, and a file without one may not carry a single rejected name — so legacy
code is grandfathered while new code is not. `update` writes the current counts,
refuses to record a number that grew unless `--allow-raise` says why, and deletes
the file once the last entry reaches zero. That has happened: there is no budget
file today, and the check allows no rejected spelling anywhere.

`sync-lint` writes one SwiftLint custom rule per rejected spelling, so a
violation shows up in Xcode while typing rather than only in CI. A rule with a
backlog excludes the files carrying it — CI lints with `--strict`, and a warning
in legacy code would block every commit — while the budget keeps those same files
from growing. With the backlog empty, no rule carries exclusions.

The vocabulary itself, the zones, and the reasoning are in
[`docs/GLOSSARY.md`](../docs/GLOSSARY.md).

## gen_compose_marks.py

Writes `ComposeRuleSet+Marks.swift`: every dead-key composition Unicode defines
(a base letter plus the key's combining mark has a precomposed form) that the
hand-written `ComposeRuleSet.global` lacks. It parses the existing table from
the Swift source, so its output only ever adds. Stdlib only.

```bash
python3 -I scripts/gen_compose_marks.py \
    > Sources/WurstfingerKit/Keyboard/Definition/Compose/ComposeRuleSet+Marks.swift
```

Why the rules are kept out of the accent cycle: [`docs/layout-parity.md`](../docs/layout-parity.md).

## layout-science/

The data, cost model, search and tests behind the English (Optimized) layout,
all stdlib-only Python 3.9 and deterministic. See
[`docs/layout-science.md`](../docs/layout-science.md) for what they do and how far
to trust them.

```bash
python3 -I scripts/layout-science/model.py        # score every layout under the model
python3 -I scripts/layout-science/test_model.py   # unit tests, about a second
python3 -I scripts/layout-science/optimize.py     # the full search (about 13 minutes); rewrites results.json and optimized_layout*.json
```
