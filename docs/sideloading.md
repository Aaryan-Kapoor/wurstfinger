# Putting Wurstfinger on your own iPhone

For a free Apple ID and no Xcode. The build runs on a GitHub macOS runner,
which has Xcode; [Impactor](https://github.com/claration/impactor) (a Rust
sideloader) signs it with your Apple ID and installs it over USB.

## Steps

1. **Build.** Run the *Sideload IPA* workflow (Actions tab, or
   `gh workflow run sideload-ipa.yml`), then
   `gh run download --name Wurstfinger-sideload-ipa`.
2. **Install Impactor.** Download `Impactor-macos-universal.dmg` from its
   [releases](https://github.com/claration/impactor/releases) (or
   `brew install --cask impactor`).
3. **Install.** Plug in the iPhone and trust the computer, drop the IPA on
   Impactor, choose the Apple ID, and install. Turn on Developer Mode on the
   phone first if iOS asks (Settings > Privacy & Security).
4. **Trust the profile**, if asked: Settings > General > VPN & Device
   Management.
5. **Add the keyboard:** Settings > General > Keyboard > Keyboards > Add New
   Keyboard > Wurstfinger, then allow Full Access.

With a free Apple ID the install lasts seven days; run Impactor again to renew
it. Apple also limits a free account to a few App IDs per week; the app and its
keyboard take two.

## What the build does differently

`scripts/bundle-ios.sh --sideload` is the App Store device build with throwaway
signing inputs (a self-signed certificate and two profiles made in a temporary
keychain), because Swift Bundler will not build an iOS app without them. Impactor
replaces both. It also renames the bundle identifiers (`de.akator.wurstfinger`
becomes `de.akator.wurstfinger.<TEAM>`) and registers the app group as
`group.de.akator.wurstfinger.shared.<TEAM>`, since your team does not own the
original. `SharedDefaults.resolvedAppGroup` reads the team out of the bundle
identifier so the app and the keyboard still share settings.

## Not verified

None of this has run on a device. Check on the first install:

- Settings made in the app show up in the keyboard (the shared group resolved).
- Impactor accepts the app group on a free account. If it does not, the keyboard
  still loads but the two stop sharing settings.
- The build job itself: `--sideload` is dry-run tested here, but Swift Bundler's
  device build has only been exercised on the App Store path.
