# Wurstfinger

[![App Store](https://img.shields.io/badge/App%20Store-Available-black?logo=apple&logoColor=white)](https://apps.apple.com/de/app/wurstfinger/id6754844184)
[![TestFlight](https://img.shields.io/badge/TestFlight-Beta-blue?logo=apple&logoColor=white)](https://testflight.apple.com/join/trX4rBPf)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

*The keyboard for fat fingers.*

The name “Wurstfinger” is a nod to the “fat finger” problem—thumb-heavy typing on small screens.

Wurstfinger is a MessagEase-inspired keyboard for iOS written in SwiftUI. It
brings thumb-friendly gestures from Thumb-Key and the original MessagEase
layout to Apple devices, including circular gestures for uppercase letters,
return swipes for typographic punctuation, and compose rules to generate
accented characters.

## Download

[![Download on the App Store](https://img.shields.io/badge/App%20Store-Download-black?logo=apple&logoColor=white)](https://apps.apple.com/de/app/wurstfinger/id6754844184)

**Requirements:** iOS 17.0 or later

<table>
  <tr>
    <td width="50%">
      <img src="docs/images/keyboard-lower-light.webp" alt="Lower case layout (light)" width="100%">
      <p align="center"><i>Light Theme</i></p>
    </td>
    <td width="50%">
      <img src="docs/images/keyboard-lower-dark.webp" alt="Lower case layout (dark)" width="100%">
      <p align="center"><i>Dark Theme</i></p>
    </td>
  </tr>
  <tr>
    <td width="50%">
      <img src="docs/images/keyboard-numbers-light.webp" alt="Numbers layout (light)" width="100%">
      <p align="center"><i>Numbers Layer</i></p>
    </td>
    <td width="50%">
      <img src="docs/images/keyboard-numbers-dark.webp" alt="Numbers layout (dark)" width="100%">
      <p align="center"><i>Numbers Layer (Dark)</i></p>
    </td>
  </tr>
</table>

## Why Wurstfinger?

Traditional QWERTY keyboards waste screen space and require precise tapping. Wurstfinger uses a 3×3 grid with swipe gestures, so your thumbs travel less and hit the right key more often—even on small screens. Once you get past the learning curve (a few days of practice), you'll type faster and with fewer errors.

## Beta Testing

Want to try the latest features before they hit the App Store? Join our public TestFlight beta!

[![Join TestFlight Beta](https://img.shields.io/badge/TestFlight-Join%20Beta-blue?logo=apple&logoColor=white)](https://testflight.apple.com/join/trX4rBPf)

- Nightly builds with the latest features from the `develop` branch
- Help shape the keyboard with your feedback
- Early access to experimental features

## Features

- **Multi-language support**: 28 keyboard layouts — Arabic, Croatian, English, English (Optimized), English (Thumb-Key), Estonian-Finnish, Finnish, French, German, Greek, Hebrew, Hindi, Italian, Japanese (Hiragana), Japanese (Katakana), Korean, Persian, Polish, Portuguese, Russian, Spanish, Spanish-Catalan, Swedish, Tagalog, Thai, Ukrainian, Urdu, and Vietnamese (with Telex input)
- **MessagEase layout** with symbol and numeric layers, and every gesture of Flickboard, the Android keyboard it is modelled on: dead keys for every accent, line and word movement, word-case steps, one-shot Ctrl and Alt for terminals ([parity inventory](docs/layout-parity.md))
- **English (Optimized)**, a second English layout whose letters were placed from letter-pair statistics and a model of the keyboard's real geometry; MessagEase English stays the default ([how, and how much it helps](docs/layout-science.md))
- **Compose engine** that reproduces Thumb-Key's combination triggers (e.g. `' + a → á`)
- **Return swipes** for punctuation and math symbols (`?`→`¿`, `*`→`†`, `/`→`÷`, ...)
- **Circular gestures** on keys to insert uppercase letters
- **Drag gestures** for cursor movement and progressive deletion
- **Customizable settings**: Adjust haptic feedback intensity, keyboard scale, and key aspect ratio
- **Onboarding flow** with interactive setup guide

## FAQ

Wondering why something doesn't work as expected? Check out the [Frequently Asked Questions](docs/FAQ.md) for common issues and their solutions.

## Localization

The app UI is localized into 23 languages. The Expert section and the imprint
are English only — see [Localization Scope](docs/localization.md).

## Getting Started

Wurstfinger is a Swift package. There is no Xcode project: the app and its
keyboard extension are built with [Swift Bundler](https://github.com/moreSwift/swift-bundler),
and `scripts/bundle-ios.sh` assembles the iOS keyboard extension, which Swift
Bundler cannot do on its own.

### Prerequisites

- A Swift 6 toolchain (Xcode 16 or newer, or the open-source toolchain)
- [Swift Bundler](https://github.com/moreSwift/swift-bundler) 3.0 — the
  commit CI builds is pinned in `.github/actions/setup-swift-bundler/action.yml`:

  ```bash
  brew install mint
  mint install moreSwift/swift-bundler@d97771d6af71784497749b34c4f71460abf9aa4b
  ```

- **Xcode, for iOS only.** The iOS SDKs, the simulator and `actool` ship with
  Xcode (26 for the Icon Composer app icon); the Command Line Tools are enough
  for everything else on this page.

### Building the macOS app

The quickest way to try the keyboard needs no simulator. The package also
builds a Mac app whose **Test** tab hosts the live keyboard in a window:

```bash
swift bundler run Wurstfinger
```

`swift bundler bundle Wurstfinger` builds the same app without launching it,
into `.build/bundler/apps/Wurstfinger/Wurstfinger.app`.

> **Note:** SwiftUI's `#Preview` macro is implemented by a compiler plugin that
> only ships with Xcode, so `Package.swift` compiles previews out when no Xcode
> is selected (the sources guard them with `#if !WURSTFINGER_NO_PREVIEWS`).
> CI runners have Xcode, so nothing changes there. Set
> `WURSTFINGER_NO_PREVIEWS=1` or `=0` in the environment to force the choice.

### Running Tests

The project includes unit tests for gesture handling, compose logic and
localization. They run on the Mac, with no simulator:

```bash
swift test --parallel
```

> **Note:** The XCUITest sources in `UITests/` are not part of the package and
> do not run under `swift test`. Screenshots no longer come from UI tests: see
> [Screenshots](#screenshots).

### Building and Installing for iOS

```bash
scripts/bundle-ios.sh --simulator --install --launch
```

This needs Xcode. The script:

1. Runs `swift bundler bundle Wurstfinger -p iOSSimulator`, which builds the app
   and the `WurstfingerKeyboard` executable (Bundler.toml lists it as a
   dependency of the iOS app).
2. Assembles `PlugIns/WurstfingerKeyboard.appex` around that executable, renders
   its `Info.plist` from `Bundling/Keyboard-Info.plist`, compiles both
   `Localizable.xcstrings` catalogs into `<locale>.lproj/Localizable.strings`
   (`scripts/xcstrings_to_strings.py`) and installs the privacy manifests and
   the icons.
3. Signs the extension, then the app, with their entitlements (ad hoc on the
   simulator).
4. Installs and launches the app on a simulator (`--simulator "iPhone 16"`
   picks one by name; the default is the first available iPhone).

`--dry-run` prints every command instead of running it. Without Xcode the
script stops at its preflight check and says so. The assembly steps themselves
need no Xcode, and `scripts/test-bundle-assembly.sh` runs them on a fake app
layout.

### Installing the Keyboard

1. Run the app on a device or simulator as above.
2. The app includes an interactive onboarding guide that walks you through:
   - Adding the keyboard in **Settings › General › Keyboard › Keyboards**
   - Enabling "Allow Full Access" for cursor control and deletion features
   - Testing the keyboard in the practice view

### Screenshots

The README and App Store screenshots are rendered headlessly on the Mac, with
SwiftUI's `ImageRenderer`, by the `WurstfingerSnapshots` tool:

```bash
swift run WurstfingerSnapshots --out /tmp/wurstfinger-snapshots
```

The `Update Screenshots` workflow regenerates `docs/images/` from it, and
`Generate App Store Screenshots` writes the sets `deliver` uploads to
`fastlane/screenshots/` (`scripts/stage-appstore-screenshots.sh`).

### Releasing

Releases follow [RELEASE.md](RELEASE.md). The version lives in `Bundler.toml`.
On a published release the `App Store Release` workflow runs
`fastlane ios release`, and the nightly `iOS Beta` workflow runs
`fastlane ios beta`. Both lanes sign with `match`, call
`scripts/bundle-ios.sh --device --ipa` to build the signed IPA, and upload it
with `upload_to_testflight(ipa:)` / `upload_to_app_store(ipa:)`.

### Linting

SwiftFormat, SwiftLint and markdownlint run in CI on every pull request. To get
the same checks before committing, install the tools and the pre-commit hook:

```bash
brew install swiftformat swiftlint markdownlint-cli2
./scripts/install-hooks.sh
```

The hook formats staged Swift files, auto-fixes what it can in staged Markdown,
and fails the commit on whatever is left. To check every Markdown file by hand,
run this from the repository root:

```bash
markdownlint-cli2 "**/*.md"
```

### Project Layout

```text
wurstfinger/
├─ README.md
├─ LICENSE
├─ Package.swift               # SwiftPM manifest
├─ Bundler.toml                # Swift Bundler: bundle id, version, Info.plist, iOS overlays
├─ Bundling/                   # Keyboard Info.plist template, entitlements, icon, asset catalog
├─ Sources/
│  ├─ WurstfingerKit/          # App and keyboard code, in one module
│  ├─ Wurstfinger/             # App executable and its Localizable.xcstrings
│  └─ WurstfingerKeyboard/     # Keyboard extension executable and its Localizable.xcstrings
├─ Tests/
│  └─ WurstfingerKitTests/     # Swift Testing unit tests
├─ UITests/                    # XCUITest sources (Xcode only, not built by SwiftPM)
├─ scripts/                    # bundle-ios.sh, bundle assembly test, naming checker, hooks
└─ fastlane/                   # Lanes, match config, store metadata
```

Naming across the codebase follows [`docs/GLOSSARY.md`](docs/GLOSSARY.md) — the canonical
vocabulary for modes, slots, gestures, and the pipeline. Check it before adding a type.
Its machine-checkable half lives in [`glossary.toml`](glossary.toml); run
`python3 scripts/check_naming.py check` to see where you stand, which is what CI and the
pre-commit hook do.

## License

This project is licensed under the [MIT License](LICENSE).

## Acknowledgements

- [MessagEase](https://www.exideas.com/ME/) for the original layout concepts
- [Thumb-Key](https://github.com/dessalines/thumb-key) for inspiration and
  compose rules
