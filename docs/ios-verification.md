# Verifying on iOS

Most of Wurstfinger is built and tested on macOS (`swift build`, `swift test`, the headless
`WurstfingerSnapshots` renderer), because the keyboard's logic lives in one platform-neutral module.
A few things only exist on an iPhone or iPad. This is the checklist for them, in the order worth doing.

## Build and install

```sh
scripts/bundle-ios.sh --simulator --install --launch      # simulator
scripts/bundle-ios.sh --device --identity "Apple Development: …" \
  --app-profile app.mobileprovision --keyboard-profile keyboard.mobileprovision --ipa Wurstfinger.ipa
```

Then enable the keyboard in Settings → General → Keyboard → Keyboards, and grant Full Access (haptics and the
clipboard need it).

## Input engine (`Sources/WurstfingerKit/Keyboard/Runtime/Input`)

| Check | How | Expected |
| --- | --- | --- |
| Touches reach the engine | Type a sentence | Every key responds; the pressed key lights on touch-down |
| No touch-down delay at the bottom edge | Tap space / return rapidly | Highlight appears immediately (the window's gesture recognizers no longer delay touches — `KeyboardViewController.stopDelayingTouches`) |
| Rollover | Type fast with two thumbs, overlapping | Text comes out in press order |
| Resting thumb | Rest one thumb on a key, type with the other | Typing is not delayed |
| Coalesced samples | Draw a fast circle | Circle recognized; trail is smooth |
| Predicted touches | Fast flick with the trail on | Trail head stays under the finger |
| System gesture | Swipe up from the home indicator mid-flick | Nothing typed, no stuck pressed key |
| VoiceOver | Turn VoiceOver on, double-tap keys, use the rotor's actions | Activation types the key; custom actions work |
| Guide card | Flick slowly, pause on a key | Bubble shows the target; after a pause the key's map appears above the thumb |
| VoiceOver actions (#231) | VoiceOver on, focus a letter key, open the rotor's Actions | Every character on the key is listed as "character, gesture" ("v, swipe down right"); a lone mark is read by name ("period") |
| Gesture typing with VoiceOver | Settings → VoiceOver → Gesture Typing on; VoiceOver on; flick slowly | The key's character is spoken on touch-down, each new target as the finger moves, and lifting types it (VoiceOver echoes it). Check that the rotor's Direct Touch item, if shown, toggles it, and that VoiceOver's own touch sounds stay quiet (`silentOnTouch`) |
| Sensitive fields | A field with `textContentType` password (shown in clear), one-time code or card number, trail on | No trail, no guide card, no glyph lifting off; the key's own hint still lights. Back in a normal field everything returns |
| Key clicks | Settings → Haptics → Key Clicks on (needs Full Access) | The system click on letters, the delete sound on delete, the modifier sound on space/return/123/globe; silent in silent mode |

## Responsiveness, measured on the device

- **Health log** (Settings → Expert → Keyboard Health): after typing for a while and dismissing the keyboard, look
  for `touchLatency p50 … p95 … p99 … max … ms n=…` and any `hitch NNms` entries (`InputLatencyProbe`). Touch latency
  is hardware timestamp → engine done, including `insertText` on release.
- **Instruments**: the `os_signpost` instrument, subsystem `de.akator.wurstfinger`, category `input` — intervals
  `keystroke` (touch-down → text delivered) with `classify` and `dispatch` nested inside.

## Haptics

Requires Full Access. Check tap/drag intensity settings take effect, the first keystroke after a pause is not
late (generators are prepared on appearance and touch-down).

| Check | How | Expected |
| --- | --- | --- |
| Click bank build | Kill the keyboard (switch keyboards, reopen the host), then type the moment it appears | The first touches are not late; derived clicks take over from the designed patterns within a few frames (`CoreHapticsRenderer.rebuildClickBank`, eight players per main-actor turn) |
| Derived clicks | Tap neighbouring letter keys, then flick in each direction | Neighbours feel different; a flick's detent sharpens and softens with its direction; nothing feels stepped between bank cells |
| Key sounds | Haptics › Key Clicks on, Full Access on; type, flick, return-swipe, circle | Each key its own pitch, rising up and to the right; no click, dropout or delay against the touch (`KeySoundMixer`, 5 ms IO buffer); other audio keeps playing; silent switch silences it |
| Height spring | Drag the keyboard-size slider in the app, then toggle the numpad column | Keys and the keyboard's top edge move as one (`KeyboardSpring`), no wobble, no lag behind the slider |

## Settings sync

With the keyboard visible in a split-view or Slide Over host, change a setting in the Wurstfinger app: the keyboard
should update within a frame or two (Darwin notification, debounced 50 ms), not only on the next appearance.

## Memory

The health log records the footprint at every lifecycle point. A normal session should stay far below the
extension's jetsam limit (~48–66 MB depending on device); the `postShedSettled` entry after dismissal shows what
survives into suspension.

Before dismissing, type a new name twice (word suggestions on) and a few emoji, then dismiss within five seconds and
kill the keyboard process (switch to another keyboard and back from a fresh host). On reopening, the name is still
offered and the emoji are on the recent key: both are written in `prepareForSuspension`, not only by their timers.

## Word suggestions (`Sources/WurstfingerKit/Keyboard/Runtime/Completion`)

Everything iOS-specific here is unverified on this machine: `SystemCompletionSource`'s `UITextChecker` calls and the
field mapping in `KeyboardViewController.completionPolicy(for:)`.

| Check | How | Expected |
| --- | --- | --- |
| Completions appear | Settings › Word Suggestions on; type "hel" | Up to three words above the keys within a frame or two; `UITextChecker.availableLanguages` contains the layout's language |
| First lookup per language | Switch language with the globe, type two letters | No visible stall of the next touch (the first lookup loads a dictionary; measured about 300 ms with `NSSpellChecker`). If it stalls, warm the checker at appearance or move lookups off the main actor once `UITextChecker`'s isolation in the SDK is known |
| Accept | Tap a completion; swipe down on the space bar | Rest of the word and a space; the next space press types nothing, a period removes the space |
| Hidden fields | Password field, Safari address bar, email field, phone pad, a field with autocorrection off | No row, keyboard height shrinks back; row returns in an ordinary field |
| Height change | Switch from a note to the address bar | Keyboard height follows without a jump (`textDidChange` calls `updateKeyboardHeight`) |
| Learned words | Type a name twice, then its first letters | The name is offered; Settings › Clear Learned Words, then reopen the keyboard: gone |
| VoiceOver | Row buttons read as words with a hint; custom action "Accept suggestion" on the space bar; with gesture typing on, the top word is spoken after a one second pause | As described |
