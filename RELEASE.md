# Release Checklist

## Before the release

- [ ] All relevant PRs merged into `develop`
- [ ] CI green on `develop`
- [ ] Update `fastlane/metadata/en-US/release_notes.txt` (source text) and `fastlane/metadata/de-DE/release_notes.txt`
- [ ] Translate the notes into every other `fastlane/metadata/<locale>/release_notes.txt` (a locale left untouched ships the previous version's notes); limit 4000 characters each
- [ ] Update `CHANGELOG.md` — rename "Unreleased" to `v X.Y.Z — YYYY-MM-DD`, add empty "Unreleased" section
- [ ] Bump `version` under `[apps.Wurstfinger]` in `Bundler.toml` (the app and the keyboard extension both take it from there)
- [ ] Verify version bump: `grep -n '^version' Bundler.toml`
- [ ] Commit: `Bump version to X.Y.Z`
- [ ] Push `develop`

## Create the release

- [ ] Merge `develop` → `main`: `git checkout main && git merge develop --no-edit`
- [ ] Push `main`
- [ ] Tag: `git tag vX.Y.Z && git push origin vX.Y.Z`
- [ ] Create GitHub release: `gh release create vX.Y.Z --title "vX.Y.Z" --notes "..."`
- [ ] Verify `vX.Y.Z` is marked as "Latest": `gh release list --limit 3`
  - If not: `gh release edit vX.Y.Z --latest`

## After the release

- [ ] Verify App Store Release workflow succeeds: `gh run list --workflow="App Store Release" --limit 3`
- [ ] Check App Store Connect: correct version, release notes, and build
- [ ] Switch back to `develop`: `git checkout develop`

## Troubleshooting

### Fastlane fails with "version number has been previously used"

The `version` bump is missing from `Bundler.toml`. Verify with:

```bash
grep -n '^version' Bundler.toml
```

Fix, commit, force-update the tag, and re-trigger the workflow.

### App Store Connect asks to "select a build"

The release lane uploads the IPA that `scripts/bundle-ios.sh` built (`upload_to_app_store(ipa:)`) and deliberately passes no `build_number:` (that option would select an existing build instead of uploading). If no build is attached anyway, check the workflow log for the upload step, and that the lane's build number (latest App Store build + 1, passed to the script as `--build-number`) is higher than the previous one.

### Build shows "missing compliance" in App Store Connect

The `ITSAppUsesNonExemptEncryption` flag must be set in both the host app and the keyboard extension. The host app gets it from the `plist` tables in `Bundler.toml`; the keyboard extension gets it when `scripts/bundle-ios.sh` renders its `Info.plist` from `Bundling/Keyboard-Info.plist`.

### The IPA is rejected for a missing icon, a bad signature or a missing key

The IPA is assembled by `scripts/bundle-ios.sh`, not by Xcode, so check what it
produced: `unzip -l build/Wurstfinger.ipa`, and `codesign --verify --deep --strict`
on the unpacked app. Both `Info.plist`s must carry the `DT*` keys the script
copies from the selected Xcode, and `Assets.car` must be present (it needs
`actool` from Xcode 26). Build the same thing locally with
`scripts/bundle-ios.sh --dry-run --device` to see every step.

### Wrong release notes in App Store Connect

Fastlane reads from `fastlane/metadata/*/release_notes.txt` (every locale directory). Update them before creating the release. If already submitted, edit directly in App Store Connect or re-run the workflow after fixing.

### Wrong release marked as "Latest" on GitHub

```bash
gh release edit vX.Y.Z --latest
```
