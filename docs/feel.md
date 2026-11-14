# Feel: haptics, animation and shaders

How the keyboard feels under a finger: the haptic vocabulary, the motion of
keys and overlays, and the shaders that light them. The code is in
`Keyboard/Settings/HapticPatterns.swift`, `CoreHapticsPlayer.swift`,
`HapticFeedbackPlayer.swift`, `Keyboard/Runtime/Feel/`,
`Keyboard/Runtime/View/Feel/` and `Keyboard/Runtime/View/Shaders/`.

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
        KeyboardViewModel+Feel  (resolves: would the release type? what? is it a mode key?)
                   ▼
              KeyboardFeel ──▶ HapticFeedbackPlayer ──▶ CoreHapticsRenderer | GeneratorRenderer
                   └──────────▶ FeelBoard (@Observable: pops, ring, ratchet) ──▶ FeelOverlay
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
  | mode switch | 14 (every key changes label, as before) |

- **Transient visuals** live on `FeelBoard` and are drawn by `FeelOverlay`, a
  grid overlay with one part per property, so a commit re-renders the pops, a long press the ring, a slide step the ratchet — never a key.
- **No timelines when idle.** Everything is a SwiftUI animation that ends
  (keyframes, springs, `withAnimation(…completion:)`); the only
  `TimelineView` is the pre-existing trail, which runs only while a trail is
  visible. The ripple's distortion is disabled whenever it is not running, so
  an idle key costs no offscreen pass.

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
- one player per cue, built ahead of time with the user's strength baked in:
  when the keyboard appears and when a slider or the Detailed Haptics switch
  changes (observed with `withObservationTracking`, rebuilt in its own
  main-actor turn — never inside a touch).
- the long-press swell is an advanced player, scheduled ahead at touch-down
  (`start(atTime: engine.currentTime + delay)`) and `cancel()`ed if the finger
  moves or lifts first. No timer of our own.

**Full Access.** The controller passes `hasFullAccess` before preparing; without
it nothing is started or played (the generators would be silent anyway).

### Vocabulary

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

## Animation

All parameters live in `FeelMotion`. Springs are (response s, damping fraction).

| Element | Animation | Reduce Motion | Why |
| --- | --- | --- | --- |
| Key press | none: fill, light and sink on the touch-down frame | same | Never lag the finger. |
| Key release (fill, light fade, sink back) | spring(0.24, 0.82) | easeOut 0.14 s, fill only | Back before the next keystroke at 8–10 keys/s; damped so the 3.5 % sink never bounces. |
| Press sink | scale 0.965 anchored at the touch point | none | Reads as "pushed where you pressed", not "shrunk"; hints near the edge stay put. |
| Press light (`KeyLight`) | appears instantly, fades with the release | same (not motion) | Glass catches light (0.62 light / 0.34 dark peak), classic caps a little (0.24 / 0.13). |
| Glass ripple (liquid glass only) | one wavelet, 0.46 s cubic keyframe, 1.1 pt max displacement, travels 1.1× the key's long side | off | A hint of refraction; on an opaque cap a refraction reads as a glitch, so classic has none. |
| Hint emphasis on the key | spring(0.18, 0.84) (was easeOut 0.08 s) | same | Reads at once, settles without a wobble while the finger still moves. |
| Labels on mode / language change | easeInOut 0.16 s, `.contentTransition(.interpolate)` (a → A morphs) | same (a cross-fade, not motion) | The change is seen as a change, not a flash. |
| Guide card: lit target appears | spring(0.20, 0.74), scale from 0.55 anchored on the side facing the key, + fade | fade only | Grows out from under the thumb. |
| Guide card: lit target moves between cells | spring(0.18, 0.86); its label swaps instantly | instant | Tracks the finger without swinging past it; the text is never cross-faded behind the moving bubble. |
| Guide card: map reveal after 0.35 s rest | spring(0.28, 0.86), scale 0.92 → 1 + fade | fade only | A render-server animation with a delay: no timer. |
| Commit pop (swipe, return, circle, long swipe, long press) | 0.30 s, timingCurve(0.2, 0.7, 0.3, 1): rises 0.42 cell (clamped inside the keyboard), scales to 1.16, fades out | easeOut 0.18 s fade in place | The lit bubble seems to float off instead of vanishing. Taps get no pop: a ghost of the label at typing speed reads as flicker. |
| Long-press ring | fades in (easeOut 0.12 s) after 0.22 s rest; fills linearly, clockwise from the top, to the fire; fire flash easeOut 0.22 s (+8 % scale, fade); cancel easeOut 0.10 s | flash without scale | A progress indicator, so it stays under Reduce Motion. Taps (80–200 ms) never see it. |
| Slide ratchet | each step moves the 7 pt notch strip one notch, spring(0.14, 0.70); fades in/out 0.18 s | notches still, centre mark only | The visual twin of the slide ticks: a thumbwheel turning under the finger. |
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

The Haptics screen's slider previews now play exactly what the keyboard plays
(`HapticPreview`): the touch-down pattern for Tap Feedback, a cursor tick for
Drag Feedback.

## Verification

- Tests: `FeelHapticsTests` (vocabulary, strength, fallback, player routing
  with recording fakes, settings), `KeyboardFeelTests` (cue precedence,
  spacing, swell and ring, ratchet, board, engine hooks, view-model
  resolution through the real engine), `FeelVisualsTests` (shader compile and
  render, trail ink, overlay geometry).
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
  Measure the one-off compile time in the extension.
