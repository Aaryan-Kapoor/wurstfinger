# Feel: haptics, animation and shaders

How the keyboard feels under a finger: the derived voices every key plays as
haptics and sound, the motion of keys and overlays, and the shaders that light
them. The code is in `Keyboard/Settings/HapticPatterns.swift`,
`CoreHapticsPlayer.swift`, `HapticFeedbackPlayer.swift`,
`Keyboard/Runtime/Feel/` (`FeelVoice.swift`, `KeySound.swift`,
`KeyboardFeel.swift`, `FrameRateBoost.swift`), `Keyboard/Runtime/View/Feel/`
and `Keyboard/Runtime/View/Shaders/`.

## Two rules

1. **Feel never adds latency.** Nothing in this layer sits between a touch and
   `insertText`, and nothing in it is awaited. Every cue is issued in the same
   synchronous main-actor call as the touch event that caused it: a haptic is
   one `start(atTime: CHHapticTimeImmediate)` on a player built ahead of time,
   a visual is one write to an observed property. A release is *resolved*
   before its keystroke is dispatched (dispatching can change the mode — a
   shifted letter releases shift) but its click and pop are *issued* after,
   at the end of the same touch event (`released` / `releaseHandled`), so
   feedback never goes out ahead of the text. The feel layer only watches;
   it never decides what gets typed.
2. **Nothing the user is waiting for animates in.** A pressed key, the lit
   target of a flick and the typed text appear on the first frame. Only exits
   (a key coming back up, a glyph lifting off) and movement *between* targets
   are animated, with springs, so a fast typist interrupting an animation
   never sees a jump.

## How it is wired

```
TouchSurface ─▶ TouchEngine ──(existing)──▶ KeyboardViewModel ─▶ pipeline ─▶ insertText
                   │  feel hooks (TouchEngineActions)
                   │   candidateChanged(key, from, to)   speculation changed target
                   │   released(key, classification)     at the lift: resolve (before dispatch)
                   │   releaseHandled()                  same event, after dispatch: issue
                   │   longPressPhase(key, armed/cancelled/fired)
                   │  KeyPressCell.touchPoint            where the finger landed (unit coords)
                   ▼
        KeyboardViewModel+Feel  (resolves: would the release type? what? is it a mode key?
                   │             derives the key's voice and the moment's FeelStroke)
                   ▼
              KeyboardFeel ──▶ HapticFeedbackPlayer ──▶ CoreHapticsRenderer (click bank | cue players)
                   │                                    └▶ GeneratorRenderer (fallback)
                   ├──────────▶ FeelBoard (@Observable: pops, ring, ratchet) ──▶ FeelOverlay
                   ├──────────▶ FrameRateBoost (CADisplayLink, 80–120 Hz while a finger is busy)
                   └─ stroke ─▶ KeyClickPlayer ──▶ KeySoundEngine ──lock──▶ KeySoundMixer (audio thread)
```

- **Per-key visuals** (`KeyPressSurface`, `KeyLight`, `KeyPressFeel`) read only
  the key's own `KeyPressCell`. Body evaluations measured with
  `swift run WurstfingerBench --bodies` (14 keys on screen):

  | Event | KeyView bodies |
  | --- | --- |
  | engine touch-down on one key | 1 |
  | engine release (a tap commits) | 1 |
  | engine flick: down / 8 moves / release | 1 / 1 / 1 |
  | tap keystroke, settings reload, haptic slider | 0 / 0 / 0 (unchanged) |
  | mode switch | 12 (every key that changes label, as before) |

- **Allocation-free.** A keystroke with the derived haptics — and with key
  sounds on — allocates nothing (release bench `--alloc`: 8a/8b/8h 0, 8j tap
  with key clicks 0, 8k flick with key clicks 0, 8l deriving a voice and a
  return-swipe stroke 0). A stroke is a fixed-size value (three inline hits),
  a hit is one `start` on a prebuilt player and one append to a reserved
  queue.

- **Transient visuals** live on `FeelBoard` and are drawn by `FeelOverlay`, a
  grid overlay with one part per property, so a commit re-renders the pops, a long press the ring, a slide step the ratchet — never a key.
- **No timelines when idle.** Everything is a SwiftUI animation that ends
  (keyframes, springs, `withAnimation(…completion:)`); the only
  `TimelineView` is the pre-existing trail, which runs only while a trail is
  visible. The ripple's distortion is disabled whenever it is not running, so
  an idle key costs no offscreen pass.

## Derived voices: one model for haptics and sound

Every touch moment is a `FeelStroke` — up to three hits, each with a delay,
a pitch, a weight and an instrument — derived by `FeelVoiceModel` from the
key and the gesture. The haptics play its hits as clicks, the key sounds play
them as notes; it is one value, so what a key feels like and sounds like
always agree. The rules are few and global, so the keyboard is learnable as
an instrument: "up and right is higher, numbers are higher still, letters are
wood, punctuation is glass, a flick moves the note by its direction".

`swift run WurstfingerSnapshots --filter feel-voicemap` draws the result for
every key of a mode (note, instrument, haptic intensity / sharpness);
`--sound-demo FILE.wav` renders the sounds of a typed phrase through the real
engine and mixer, to listen to without a device.

### A key's voice

| Input | Rule |
| --- | --- |
| Where the key sits (centre of its touch frame in the grid, x and y in 0…1) | `16·(1 − y) + 10·x` semitones, plus the role's offset, **snapped to a major pentatonic scale** (any two keys consonant). The nine letter keys of the 3×3 grid land on seven notes: G5 A5 C6 / C6 D6 E6 / E6 G6 A6 bottom to top. |
| Role (`KeyRole`, from the key's slide type and tap action) | letter: wood, weight 0.62 · digit: bell, 0.58 · punctuation: glass, 0.52 · space: thump, 0.70, fixed C4 · delete: dull, 0.64, fixed E5 · return: felt, 0.60, −3 st · modifier (shift, 123, globe): felt, 0.50, −5 st |
| Mode | numbers +5 semitones, symbols / emoji +7 (the whole keyboard transposed, so it stays in tune with itself); capitals the same note, +0.08 weight |

### A moment's stroke

Intervals by direction: up +7, up-right +9, right +4, down-right −3, down −7,
down-left −9, left −4, up-left +5 (up is higher, right a little higher, every
direction distinct).

| Moment | Hits (delay: pitch, weight) | Haptic | Sound (gain) |
| --- | --- | --- | --- |
| Touch-down | 0: key note, key weight | ✓ | 1.0 |
| Tap released | 0: note −5, weight × 0.48 — the key coming back up | ✓ | — (felt only) |
| Flick released | 0: note + interval, weight × (0.78 + 0.18 × reach, reach in key sizes ≤ 1.2); instrument of what it types | ✓ | 0.75 |
| Return swipe | 0: note + interval; 34 ms: key note (out and home) | ✓ | 0.75 |
| Circle | arpeggio 0 / 4 / 7 semitones clockwise, 7 / 4 / 0 counter-clockwise, at 0 / 26 / 52 ms | ✓ | 0.70 |
| Long press fired | 0: note + 12 (the hidden character, an octave up), instrument of what it types | ✓ | 0.80 |
| Long swipe | haptic: the designed thunk-with-tail (same on every key); sound: thump at note − 12 + interval / 2 | pattern | 0.80 |
| Direction detent | 0: note + interval, weight 0.32, tick | ✓ (sharpness differs per sector) | — |
| Centre / return detent | note − 3, 0.24 / note + 2, 0.36, tick | ✓ | — |
| Circle closing | note + 4, then + 7 at 24 ms, tick | ✓ | — |
| Caret step | space note + 19 ± 2 (right up, left down), weight by pace 0.52 / 0.44 / 0.36 / 0.28, tick | ✓ | 0.40 |
| Character deleted | delete note − (count mod 4) (walks down), weight by pace + 0.06, dull | ✓ | 0.45 |
| Mode change | two felt notes 40 ms apart, **rising** into a mode further from letters (a fourth to a neighbour, a fifth for a jump), **falling** back | ✓ | 0.70 |
| Language change | rising triad 0 / 4 / 7 at 0 / 45 / 90 ms | ✓ | 0.70 |
| Clipboard success / dismiss | glass 12 → 19 / felt 5 → 0, plus their designed haptic patterns | pattern | 0.60 |

### How a hit becomes a click and a note

| | Haptic (`FeelHit.intensity` / `.sharpness`) | Sound (`KeySoundMixer`) |
| --- | --- | --- |
| Pitch | sharpness = 0.34 + 0.021 · pitch + instrument bias, floor 0.12 (higher notes feel crisper) | rate = 2^(pitch / 12) on the instrument's sample (higher notes are also shorter, like any struck object) |
| Weight | intensity = weight × instrument strength | gain = weight × instrument loudness × stroke gain × 0.32 master |
| Instrument | bias / strength: wood 0 / 1 · glass +0.16 / 0.86 · bell +0.10 / 0.90 · felt −0.12 / 0.82 · thump −0.10 / 1.08 · dull −0.14 / 1 · tick +0.22 / 0.62 | its own synthesized sample (below) |
| User level | intensity × gain, sharpness + shift (Strength table) | the Key Clicks switch |

## Haptics

### Players

`HapticFeedbackPlayer` is the façade. It routes each cue to
`CoreHapticsRenderer` when Detailed Haptics is on and the engine is running,
and otherwise to the UIKit generators (`GeneratorRenderer`, the keyboard's
original feel). On macOS Core Haptics compiles but the hardware reports no
support, so the generator shims (NSHapticFeedbackManager) play.

`CoreHapticsRenderer`:

- one `CHHapticEngine` with `playsHapticsOnly = true` (never touches the host
  app's audio session) and `isAutoShutdownEnabled = false`: started when the
  keyboard appears (`viewWillAppear` → `prepareHaptics`, and on host
  foreground return), kept running while it is on screen, stopped in
  `shedMemoryBeforeSuspension`. A cold engine takes tens of milliseconds to
  start, which would otherwise land on the first keystroke after a pause.
- the start is asynchronous (`start(completionHandler:)`); until it completes
  `play` returns false and the generators cover the cue.
- `stoppedHandler` (interruption, idle timeout, system error) restarts the
  engine; `resetHandler` (haptic server restart) restarts it and rebuilds every
  player, as Apple requires. Both hop to the main actor; the closures are
  `@Sendable` so Swift 6's runtime isolation check cannot trap when Core
  Haptics calls them off the main thread.
- **the click bank** for derived hits: 8 intensities (0.10 → 0.94, about a
  third louder each) × 6 sharpnesses (0.10 → 1.00), two players per cell used
  in turn (so a hit scheduled ahead — a return swipe's echo — is not cut off
  by the next keystroke on the same cell): 96 one-transient players, built
  once per engine, independent of the user's strength (gain is applied before
  quantizing). A hit plays the nearest cell; a stroke whose hits the bank
  cannot play falls back to its cue's designed pattern, then to the
  generators.
- one player per cue, built ahead of time with the user's strength baked in:
  when the keyboard appears and when a slider or the Detailed Haptics switch
  changes (observed with `withObservationTracking`, rebuilt in its own
  main-actor turn — never inside a touch).
- the long-press swell is an advanced player, scheduled ahead at touch-down
  (`start(atTime: engine.currentTime + delay)`) and `cancel()`ed if the finger
  moves or lifts first. No timer of our own.

**Full Access.** The controller passes `hasFullAccess` before preparing; without
it nothing is started or played (the generators would be silent anyway).

### Designed patterns

Touch-downs, commits (except long swipes), detents, the circle closing, slide
ticks and mode and language changes now play **derived strokes** (above). The
designed patterns below remain for the moments that mean the same on every
key — the long-swipe thresholds and landing, the long-press swell, dismissal,
clipboard — and as the fallback for a derived stroke the click bank cannot
play.

Intensities are authored for "Strong" (gain 1) and scaled by the user's level.
Transients are Core Haptics clicks (~10 ms, shorter the sharper). Times are
from the start of the pattern.

| Event | Cue | Pattern | Intensity | Sharpness | Duration | Why |
| --- | --- | --- | --- | --- | --- | --- |
| Finger lands on a key | `touchDown` | transient | 0.62 | 0.60 | ~10 ms | The key's tactile bump: crisp enough to register under a fast thumb, not so sharp that 8 keystrokes a second rattle. |
| Tap released | `commit(.tap)` | transient | 0.30 | 0.22 | ~10 ms | The key coming back up. Softer and duller than the press, so press + release read as one physical keystroke, not two clicks. |
| Flick released | `commit(.swipe)` | transient | 0.50 | 0.82 | ~10 ms | A flick snapping off the key: sharper than the press. |
| Return swipe released | `commit(.returnSwipe)` | 2 transients, 0 / 34 ms | 0.46 / 0.30 | 0.70 / 0.95 | 34 ms | There and back: a click and a lighter, crisper echo. |
| Circle released | `commit(.circle)` | 3 transients, 0 / 26 / 52 ms | 0.26 / 0.36 / 0.50 | 0.40 / 0.56 / 0.76 | 52 ms | A roll, like a dial turning past its detents. |
| Long swipe released | `commit(.longSwipe)` | transient + buzz 60 ms at 12 ms (release 50 ms) | 0.78 / 0.30 | 0.32 / 0.18 | 72 ms | A global action fired: heavy, dull landing with a short tail. Silent when the action confirms itself (dismiss, mode/language switch). |
| Long press fired | `commit(.longPress)` | transient | 0.80 | 0.66 | ~10 ms | The swell's resolution: a firm click. |
| Flick passes into another direction | `directionDetent` | transient | 0.30 | 0.96 | ~10 ms | The lightest tick in the set: the eight sectors are felt passing without competing with the press or commit. At most one per 30 ms. |
| Flick back to the centre (a tap again) | `centerDetent` | transient | 0.22 | 0.60 | ~10 ms | Slightly softer and duller than a direction. |
| Flick turns back (return swipe armed) | `returnDetent` | transient | 0.34 | 1.00 | ~10 ms | The turn registers as its own crisp tick. |
| Circle recognised while drawing | `circleClosed` | 2 transients, 0 / 24 ms | 0.36 / 0.28 | 0.62 / 0.92 | 24 ms | The loop closing: a quick two-step. |
| Flick crosses the long-swipe threshold | `longSwipeArmed` | transient + buzz 50 ms at 8 ms (release 40 ms) | 0.66 / 0.26 | 0.24 / 0.12 | 58 ms | Crossing into "do something else": a thunk, unmistakably heavier than a detent. Never rate-limited. |
| Flick drops back under it | `longSwipeDisarmed` | transient | 0.28 | 0.50 | ~10 ms | A light confirmation of stepping back. |
| Finger resting toward a long press | `longPressRamp` | buzz 260 ms (attack 40 ms, release 20 ms); intensity curve ×0.12 → ×0.5 (156 ms) → ×1; sharpness curve ×0.3 → ×1 | 0.55 peak | 0.30 → ~0.30·1 | 260 ms, ending at the fire | The long press is felt approaching; it starts 260 ms before the fire so ordinary taps never reach it. Cancelled the moment the finger moves or lifts. |
| One character deleted by sliding | `deleteTick` | transient | 0.50 | 0.45 | ~10 ms | Each character eaten: slightly dull, firm. |
| One caret step, slow (> 90 ms apart) | `cursorTick(.deliberate)` | transient | 0.52 | 0.86 | ~10 ms | Crisp detents when placing the caret character by character. |
| … 45–90 ms apart | `cursorTick(.steady)` | transient | 0.44 | 0.80 | ~10 ms | |
| … 22–45 ms apart | `cursorTick(.brisk)` | transient | 0.36 | 0.72 | ~10 ms | |
| … under 22 ms apart | `cursorTick(.rapid)` | transient | 0.28 | 0.64 | ~10 ms | A fling becomes a fine texture, not a buzz. Slide ticks closer than 12 ms share one click (the ratchet still counts every step). |
| Mode switch, label toggle | `modeSwitch` | 2 transients, 0 / 40 ms | 0.52 / 0.34 | 0.52 / 0.90 | 40 ms | A firm click and a crisp echo: the keys change. |
| Language / input-mode switch | `languageSwitch` | transient, buzz 60 ms at 20 ms, transient at 90 ms | 0.46 / 0.20 / 0.40 | 0.42 / 0.20 / 0.82 | 90 ms | A slide-over: click, soft swell, crisp landing. |
| Keyboard dismissed | `dismiss` | 2 transients, 0 / 45 ms | 0.46 / 0.30 | 0.60 / 0.20 | 45 ms | Going away: a click falling off into a dull one. |
| Copy / cut / paste succeeded | `clipboardSuccess` | 2 transients, 0 / 55 ms | 0.40 / 0.60 | 0.58 / 0.90 | 55 ms | "Got it": two rising pops. Only on real success (the middleware's success paths). |

A keystroke never plays two patterns at once: a release whose action has its
own cue (mode keys, globe, dismiss) plays no commit click, and unbound
directions play nothing at all.

### Strength

The two sliders keep their six detents. Slide cues follow **Drag Feedback**,
everything else **Tap Feedback**. Off silences the channel (no players are
built for it); the levels scale intensity and nudge sharpness:

| Level (stored) | Gain | Sharpness shift | Why |
| --- | --- | --- | --- |
| Off (0) | 0 | – | silent |
| Minimal (0.1) | 0.40 | +0.08 | Core Haptics' low end is very faint; 0.4 is still felt. Crisper when light, like the selection tick this level used to be. |
| Soft (0.3, tap default) | 0.58 | +0.04 | |
| Light (0.5) | 0.72 | 0 | |
| Medium (0.7) | 0.86 | −0.04 | |
| Strong (0.9) | 1.00 | −0.08 | Rounder when strong, like the heavy impact it used to be. |

### Fallback (generators)

| Cues | Pulse |
| --- | --- |
| `touchDown`, `deleteTick`, `cursorTick` | the original impact ladder for the slider level (`HapticPulse.pulse(for:)`) |
| detents, `circleClosed`, long-swipe armed/disarmed, long-swipe and long-press commits, mode/language/dismiss, clipboard | selection tick |
| tap/swipe/return/circle commits, `longPressRamp` | silent — a second generator impact per keystroke reads as a double buzz, and generators cannot swell |

## Sound

`KeySoundEngine` plays strokes when **Key Clicks** is on (it replaced the
system-sound `KeyClickPlayer`; the setting, the `KeyClickPlayer` seam and its
three families stay, and the system sounds remain the fallback while the
engine starts or if it cannot).

- **Instruments** (`KeySoundSynth`): seven short samples synthesized once at
  the output's sample rate — modal partials with their own decays, a filtered
  noise strike, a soft attack, a cosine fade over the last 15 % — tuned to C5
  (523.25 Hz), 90 ms long: wood (letters), glass (punctuation), bell (digits),
  felt (modifiers, return), thump (space), dull (delete), tick (slides).
- **Mixer** (`KeySoundMixer`): up to 8 voices, oldest stolen, each reading its
  sample at its rate with linear interpolation, a soft limiter for pile-ups.
  Runs inside an `AVAudioSourceNode` render block on the audio thread and
  allocates nothing.
- **Hand-off**: `play` appends one `KeySoundTrigger` per hit to an
  `OSAllocatedUnfairLock`-guarded queue with reserved capacity (16); the
  render block only ever *tries* the lock (`withLockIfAvailable`), so the
  real-time thread never waits — at worst a note starts one buffer later.
- **Latency**: the IO buffer is set to 5 ms, so a note starts within about one
  buffer of its touch.
- **Session**: `.ambient` with `.mixWithOthers` — never interrupts or ducks the
  host app's audio, follows the ring/silent switch like the system's clicks.
- **Lifecycle**: the graph is built, started and stopped in `KeySoundHost` (an
  actor), off the main thread: started when the keyboard appears with Key
  Clicks on, stopped when it goes away. Never started in the unit-test runner.
- **Full Access**: needed. A keyboard extension's sandbox gives it audio output
  only with Full Access (the system's own `AudioServicesPlaySystemSound`
  clicks need it too); without it the controller marks the engine and nothing
  is started or played. Verified only by reading reports, not on a device.
- Demo: `swift run WurstfingerSnapshots --sound-demo feel-demo.wav` (peak
  −14.7 dBFS, no clipping, for "Hello, world! 123").

## Animation

All parameters live in `FeelMotion`. Every spring is one of five, given as
(duration, bounce) — the same terms as the layout's `LayoutMotion`:
`track` (0.18, 0.15) follows a finger, `settle` (0.24, 0.15) brings a key to
rest, `land` (0.20, 0.25) lets the lit cell arrive with a little life,
`unfold` (0.28, 0.15) opens the guide map, `detent` (0.14, 0.30) is the slide
ratchet. Springs keep their velocity when interrupted, so re-pressing a key
mid-release never jumps.

**ProMotion.** While a finger is busy (`FrameRateBoost`, engaged by every feel
moment, lingering 0.45 s), a paused-when-idle `CADisplayLink` asks for 80–120
Hz, and `CADisableMinimumFrameDurationOnPhone` is set in the keyboard's and
the app's Info.plist (without it an iPhone caps every app at 60 Hz). The
press, the lit cell, the release spring and the pops then render at 120 Hz
on a ProMotion iPhone; nothing is requested while the keyboard is idle.

| Element | Animation | Reduce Motion | Why |
| --- | --- | --- | --- |
| Key press | none: fill, light and sink on the touch-down frame | same | Never lag the finger. |
| Key release (fill, light fade, sink back) | `settle` | easeOut 0.14 s, fill only | Back before the next keystroke at 8–10 keys/s; damped so the 3.5 % sink never bounces. |
| Press sink | scale 0.965 anchored at the touch point | none | Reads as "pushed where you pressed", not "shrunk"; hints near the edge stay put. |
| Press light (`KeyLight`) | appears instantly, fades with the release | same (not motion) | Glass catches light (0.62 light / 0.34 dark peak), classic caps a little (0.24 / 0.13). |
| Glass ripple (liquid glass only, shader tier `full`) | one wavelet, 0.46 s cubic keyframe, 1.1 pt max displacement, travels 1.1× the key's long side | off | A hint of refraction; on an opaque cap a refraction reads as a glitch, so classic has none. The view structure no longer changes when the shader library arrives (it used to rebuild a glass key's whole subtree on its first press, in the very frame the press had to show). |
| Hint emphasis on the key | `track` | same | Reads at once, settles without a wobble while the finger still moves. |
| Labels on mode / language change | easeInOut 0.16 s, `.contentTransition(.interpolate)` (a → A morphs), keyed by the key's label rather than its whole definition (one string compare per key per update instead of every binding) | same (a cross-fade, not motion) | The change is seen as a change, not a flash. |
| Guide card: appears | on the first frame (insertion transition `.identity`) | same | Never lag the finger. |
| Guide card: lit target appears | `land`, scale from 0.55 anchored on the side facing the key, + fade | fade only | Grows out from under the thumb. |
| Guide card: lit target moves between cells | `track`; its label swaps instantly | instant | Tracks the finger without swinging past it; the text is never cross-faded behind the moving bubble. |
| Guide card: map reveal after 0.35 s rest | `unfold`, scale 0.92 → 1 + fade | fade only | A render-server animation with a delay: no timer. |
| Guide card: leaves | easeOut 0.10 s fade (removal transition only) | same | A revealed map no longer blinks out; a lit bubble overlaps the pop lifting off from it for a frame or two. |
| Commit pop (swipe, return, circle, long swipe, long press) | 0.30 s, timingCurve(0.2, 0.7, 0.3, 1): rises 0.42 cell (clamped inside the keyboard), scales to 1.16, fades out | easeOut 0.18 s fade in place | The lit bubble seems to float off instead of vanishing. Taps get no pop: a ghost of the label at typing speed reads as flicker. |
| Long-press ring | fades in (easeOut 0.12 s) after 0.22 s rest; fills linearly, clockwise from the top, to the fire; fire flash easeOut 0.22 s (+8 % scale, fade); cancel easeOut 0.10 s | flash without scale | A progress indicator, so it stays under Reduce Motion. Taps (80–200 ms) never see it. |
| Slide ratchet | each step moves the 7 pt notch strip one notch, `detent`; fades in/out 0.18 s | notches still, centre mark only | The visual twin of the slide ticks: a thumbwheel turning under the finger. |
| Trail ink | width × 0.6…1 by speed (smoothstep 220 → 1500 pt/s, EMA 0.55); opacity fades to 30 % over 9 head widths; glow at the head on dark/accent ink | – | A pen line: thin where the hand was fast, full where it lingered. |

The **Key Animations** setting (Style screen, on by default) turns the press
light, sink, ripple, pops, ring and ratchet off; the trail and guide card
keep their own settings.

## Shaders

`FeelShaderSource.metal`, three `[[stitchable]]` functions, each a handful of
ALU operations per pixel:

| Function | Use | Effect |
| --- | --- | --- |
| `feelKeySheen` | shape style on the pressed key | Gaussian bloom at the touch, rim along the top edge, faint top-down lift. |
| `feelRipple` | `distortionEffect` on a pressed glass key | One wavelet from the touch, fading over its run. |
| `feelTrailInk` | Canvas shading of the trail ribbon | Opacity fading toward the tail, brighter core at the head. |

Every one has a pure-SwiftUI fallback drawn when the library is not (yet)
available or Reduce Transparency is on: an elliptical + linear gradient for
the sheen, no ripple, a radial gradient for the ink.

### How they ship without a Metal compiler

The package builds with SwiftPM and this machine has no `metal` compiler, so
no `.metallib` exists at build time; `ShaderLibrary` has no initializer for a
runtime-compiled `MTLLibrary` object. `FeelShaderCompiler` (run once per
process at `.utility` priority when the keyboard first appears) does:

1. `MTLDevice.makeLibrary(source:options:)` on the embedded source;
2. adds each function to an `MTLBinaryArchive` with
   `MTLFunctionOptions.compileToBinary` and serializes the archive;
3. the serialized archive embeds the functions' AIR as an ordinary
   **executable metallib** container (magic `MTLB`, byte length at offset 16).
   That container is located and validated by Metal itself — it must load with
   `makeLibrary(data:)`, be `.executable`, and hold every expected function as
   a `.visible` function — then handed to `ShaderLibrary(data:)`. On iOS 18 /
   macOS 15 the effects are precompiled (`Shader.compile(as:)`).

Nothing is patched. The archive layout is the one undocumented step, so it is
checked rather than trusted; any failure throws and the fallbacks draw.
Rejected alternatives, tried on this Mac: Metal source as `ShaderLibrary(data:)`
or `(url:)` (silently renders nothing); a serialized `MTLDynamicLibrary` (it is
a GPU binary; SwiftUI hits a Metal assertion on its functions).

### Precompiled, cached, tiered

`FeelShaders.prepare()` loads the library from the cheapest source that
Metal validates (`FeelShaderStore`):

1. **`FeelShaders.metallib` in the bundle.** `scripts/bundle-ios.sh` (step
   "Feel shaders", `ios_compile_shaders` in `scripts/lib/ios-bundle.sh`)
   extracts the Metal source between the `wurstfinger-feel-shaders` markers of
   `FeelShaderSource.swift` and compiles it with `xcrun --sdk iphoneos metal`
   / `metallib` (`-mios-version-min=17.0`; the simulator flavour for
   simulator builds) into the app and the keyboard appex. With the library in
   the bundle no iPhone, however old, compiles a shader. Without the Metal
   toolchain (Command Line Tools only, or Xcode 26 without
   `xcodebuild -downloadComponent MetalToolchain`) the step warns and is
   skipped.
2. **The persistent cache**: `FeelShaders-<hash of source and OS>.metallib`
   in the app group's `Library/Caches/FeelShaders` (shared with the host app)
   and in the process's own Caches. A corrupt or stale file is deleted and
   rebuilt.
3. **Compiling at runtime** (below), then writing both caches.

The **host app** calls `prepare()` at launch, so it compiles once and leaves
the result in the app group's cache: a keyboard with Full Access finds it
there and never compiles. (Without Full Access the extension cannot reach the
app group's container; it compiles once and keeps the result in its own
cache.)

**Tiers** (`FeelShaderTier`, re-read at every appearance):

| GPU (Metal family) | iPhones | Tier | Effects |
| --- | --- | --- | --- |
| Apple7+ (A14 and later), Mac | 12 and later | `full` | sheen, ripple, trail ink |
| Apple6 (A13) | 11, SE 2 | `essential` | sheen, trail ink — no ripple (its offscreen pass is the one real cost) |
| Apple5 (A12) | XS, XR | `off` | the gradient fallbacks, which look nearly the same and compile nothing |
| Low Power Mode | any | one tier lower | the user asked the phone to do less |

**Proven here** (M3 Pro, macOS 15.7): `ImageRenderer` renders `colorEffect`,
`distortionEffect` and shape-style shaders from the extracted library
(`FeelShaderTests.swiftUIRendersTheSheen` checks pixels in the test suite; the
snapshot tool's `feel-*` scenarios differ from their `-fallback` twins only
inside the pressed key). Not proven: iOS devices (see open questions).

## Settings

| Setting | Key | Default | Where |
| --- | --- | --- | --- |
| Detailed Haptics | `detailedHapticsEnabled` | on | Haptics screen. Off = the generator fallback only. The escape hatch if Core Haptics starts but stays silent in the extension. |
| Key Animations | `keyAnimationsEnabled` | on | Style screen. Read once in `DataDrivenKeyboardRootView` into `KeyRenderSettings`. |
| Key Clicks | `keyClicksEnabled` | off | Haptics screen. The derived key sounds (above); needs Full Access in the keyboard. |

The Haptics screen's previews play exactly what the keyboard plays
(`HapticPreview`): the derived touch-down of a key in the middle of the
keyboard for Tap Feedback, a caret tick for Drag Feedback, and turning Key
Clicks on plays three keys from the bottom left to the top right.

## Verification

- Tests: `FeelHapticsTests` (vocabulary, strength, fallback, player routing
  with recording fakes, settings), `KeyboardFeelTests` (cue precedence,
  spacing, swell and ring, ratchet, board, engine hooks, view-model
  resolution through the real engine), `FeelVisualsTests` (shader compile and
  render, trail ink, overlay geometry), `FeelVoiceTests` (the mapping's
  properties: up/right higher, every direction distinct, modes transpose,
  return and circle shapes, detents per sector, haptics and sound read the
  same hit; the click bank; the synth, mixer, queue and engine; derived sounds
  through the real engine; the frame-rate window), `FeelShaderStoreTests`
  (bundle → cache → compile order, the host app warming the keyboard's cache,
  corrupt caches, the tiers, the script's source markers).
- `scripts/test-bundle-assembly.sh` runs the shader step with stand-in tools
  (the metallib lands in the app and the appex, extracted cleanly) and, with no
  Metal toolchain installed, checks that the step is skipped, not failed.
- Snapshots: `swift run WurstfingerSnapshots --filter feel-` poses press light
  (both styles, both schemes, fallback, Reduce Transparency/Motion, setting
  off), the ripple mid-run, pops (swipe, circle, long swipe, long press,
  Reduce Motion), the ring (charging, fired), the cursor and delete ratchets,
  and the trail ink (slow, fast, armed, fallback). `feelStillFrame` freezes
  transient animations at a fraction for these stills.

## Open questions (need a device)

- **Core Haptics inside the keyboard extension.** The original code reports
  CHHapticEngine failing to initialize there. If it throws, the generators take
  over automatically. If it starts but stays silent, Detailed Haptics must be
  switched off (or defaulted off) — verify on a device with Full Access.
- Every intensity, sharpness and spring above is reasoned, not felt; tune on
  device, especially the detent (0.30 / 0.96) against the touch-down.
- Runtime shader compilation on iOS: binary archives of visible functions
  need GPU support (expected on A13+); on older devices the fallbacks draw.
  Measure the one-off compile time in the extension. With the precompiled
  library from `bundle-ios.sh` this path is only the fallback.
- The `xcrun metal` invocation (flags, Xcode 26's separate Metal toolchain) is
  unverified here: there is no Metal compiler on this machine.
- `AVAudioEngine` playback from a keyboard extension with Full Access is
  expected to work (custom sounds through `AVAudioPlayer` are reported to);
  without Full Access it is silent by design. Verify, and measure the
  touch-to-sound latency with the 5 ms IO buffer.
- The click bank's 96 players and the derived sharpness spread are reasoned:
  check on a device that neighbouring keys feel different and that the bank's
  cell steps are not felt as unevenness.
