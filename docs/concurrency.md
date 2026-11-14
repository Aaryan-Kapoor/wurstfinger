# Concurrency architecture

Wurstfinger builds in **Swift 6 language mode** (`swiftLanguageModes: [.v6]`
for every target) with complete data-race safety. This page is the map: which
isolation domain every piece of state lives in, the rules that keep the typing
path fast, and the recipe for adding a setting without breaking either.

Measured effects of all of this are in [performance.md](performance.md).

## The one rule

> **Nothing between a touch and `insertText` suspends.**

A keystroke is a chain of plain synchronous main-actor calls:

```
TouchSurfaceView.touchesBegan / Moved / Ended           one native view, all fingers
  -> TouchEngine.began / moved / ended                  hit map, per-finger PointerTrack
       moved: KeyGestureRecognizer.classify(path:…scratch:)   speculation, zero allocations
       ended: KeyGestureSequence.handleEnded(… scratch:)      classify, arithmetic only
       -> CommitQueue, flushed in press order            bounded rollover hold
  -> TouchEngineActions.gesture                         closure into the view model
  -> KeyboardViewModel.handleClassification(...)        CompiledMode table: one hash, one index
  -> ActionPipeline.process(...)                        middlewares, in order
  -> TextInputTarget.insertText(...)                    UITextDocumentProxy
```

There is no `await`, no `DispatchQueue.main.sync`, no semaphore, no
`Thread.sleep`, and no `UserDefaults` read anywhere on it. A second finger or a
settings change can never land *inside* a keystroke, because the keystroke never
yields the main actor. If you are about to add an `await` to this chain, stop:
what you need is almost certainly a background task that *publishes* into the
main actor ahead of time (see "Background work" below).

The chain is bracketed by `OSSignposter` intervals (`InputSignposts`, subsystem
`de.akator.wurstfinger`, category `input`): `keystroke` from touch-down to the
pipeline returning, with `classify` and `dispatch` nested inside. They cost
nothing unless Instruments is recording.

## Isolation domains

### 1. Value domain: nonisolated, `Sendable`

Plain values and pure functions. They can be used from any isolation, which is
what makes everything else cheap to reason about.

- Definition model: `KeyAction`, `KeyBinding`, `KeyDefinition`, `KeyboardMode`,
  `KeyboardDefinition`, `CustomLayout`, `CustomLayoutError`, `CustomLayoutStore`, `GridArrangement`, `KeyPlacement`, `ComposeRuleSet`,
  `LanguageDescriptor`, `LanguageMetadata`, `KeyboardLayoutMetrics`.
- Gesture values: `GestureFeatures`, `GestureClassification`,
  `GesturePreprocessorConfiguration`, `GestureClassificationThresholds`,
  `GestureTuning`, `TypingBehavior`, `RingBuffer` (when its element is
  `Sendable`).
- Pure engines: `GesturePreprocessor`, the classification statics on
  `KeyGestureRecognizer` (marked `nonisolated`), `ComposeEngine`,
  `HangulComposer`, `GridLayoutSolver`'s math, `GestureResolver`s, and the
  tables compiled from them (`CompiledMode`, `CompiledDefinition`: built once
  per definition, immutable, `Sendable`).
- The one deliberately non-`Sendable` helper on the touch path:
  `ClassificationScratch`, the classifier's working memory (one buffer,
  allocated once). It is owned by the `@MainActor` `TouchEngine` and handed
  to the `nonisolated` classifier by reference for the duration of one call;
  the array-based `classify(positions:)` entry points (tests, tools) make a
  temporary one. It is never stored in a value type and never crosses an
  isolation boundary, which is what lets the per-sample classification run
  without a single heap allocation.

Prefer a real `Sendable` conformance. `@unchecked Sendable` needs a comment that
proves it (the two that exist are listed at the bottom).

### 2. `@MainActor`

Everything that touches UIKit, SwiftUI state, or the text proxy:

- `KeyboardViewController`, `KeyboardViewModel`, every SwiftUI view/modifier
  that holds state.
- The action pipeline and **all middlewares** (`@MainActor protocol
  ActionMiddleware`): they drive the text proxy, which is main-thread-only.
- `TextInputTarget` (a `@MainActor` protocol), `DocumentProxyTarget`.
- `HapticFeedbackPlayer`, `GestureTrailRecorder`, the `TimerSource`s, and the
  settings objects `HapticSettings`, `LayoutSettings`, `LanguageSettings`.
- The macOS stand-ins for UIKit types (`UIScreen`, `UIDevice`, the feedback
  generators, `UIPasteboard`) are `@MainActor` too, mirroring the real ones, so
  shared code is isolation-checked identically on both platforms.

Observable state uses the **Observation framework** (`@Observable`), not
`ObservableObject`. SwiftUI tracks which properties a view's `body` reads and
invalidates only those views. State the gesture runtime mutates per keystroke
(drag residuals, the pipeline, the settings snapshots) is
`@ObservationIgnored`: no view draws from it, and ignoring it keeps the hot
writes free of observation bookkeeping.

### 3. Background, never awaited from the input path

| Piece | What it is | Why it is off the main thread |
| --- | --- | --- |
| `KeyboardRegistry` cache (`LockedCache`) | `Sendable` cache over `OSAllocatedUnfairLock`; the dictionary lock covers only get/insert, the build runs under a per-key lock | a prewarm can build language B while the main thread hits language A |
| `KeyboardRegistry.prewarm(_:)` | `withDiscardingTaskGroup`, one child per enabled language, `.utility`; each child also compiles the language's `CompiledDefinition` (phone numpad) | turns a language switch — definition *and* resolution tables — into a cache hit |
| `CustomLayoutRegistry` | `Sendable` class over an `OSAllocatedUnfairLock`: the user's decoded, validated custom layouts. Replaced wholesale when the set changes (host app after an edit; keyboard extension when `customLayoutsRevision` differs, on a settings reload). `KeyboardRegistry.load` builds their definitions lazily through the same `LockedCache` | the JSON is decoded and validated when the set changes, never per keystroke; a hit costs the cache lookup |
| `KeyboardHealthLog` | `actor` on a utility-QoS `DispatchSerialQueue`; callers `yield` into an `AsyncStream(.bufferingNewest(256))` and never await | file I/O must not sit in the launch or typing path |
| `DarwinNotificationCenter` | `notify_register_dispatch` wrapped as `AsyncStream<Void>` | cross-process "settings changed" signal |

Background work flows **toward** the main actor, never the other way: a prewarm
fills a cache the main actor later *reads synchronously*; the Darwin stream is
consumed by a `@MainActor` task that calls `reloadSettings()`. The main thread
is never made to wait for a background result.

## Where each piece of state lives

| State | Lives in | Read by the touch path via |
| --- | --- | --- |
| Active mode, current definition, locale | `KeyboardViewModel` (`@MainActor @Observable`) | direct property access |
| Gesture thresholds, preprocessor config, long-press timing, trail on/off, long-swipe distance and actions | `KeyboardViewModel.gestureTuning` (`GestureTuning`, `Sendable`) | the value threaded to the recognizers; **never `UserDefaults`** |
| Auto-capitalize, double-space period, cut-all, cursor-movement style, text-replacement table (decoded once per change, dictionary lookup per word) | `KeyboardViewModel.typingBehavior` (`TypingBehavior`, `Sendable`) | direct property access |
| Per-key render settings (label visibility, style) | `@AppStorage` in `DataDrivenKeyboardRootView`, passed down as `KeyRenderSettings` | n/a (rendering) |
| Layout wish (width, aspect ratio, position) | `LayoutSettings` | `layoutMetrics` (pure `KeyboardLayoutMetrics.resolve`) |
| Haptic intensities | `HapticSettings` | `HapticFeedbackPlayer` |
| Language selection | `LanguageSettings` (host app and extension each hold one) | `KeyboardViewModel.enabledLanguageIds` |
| Built definitions (shipped and custom) | `KeyboardRegistry` cache | `KeyboardRegistry.load(id:)`, synchronous |
| Custom layouts, as authored | `CustomLayoutRegistry` (files in the app group, `CustomLayoutStore`) | `KeyboardRegistry`, only to build a definition |
| Custom layouts, host app view | `CustomLayoutLibrary` (`@MainActor @Observable`) | n/a (settings screens) |
| Compiled resolution tables | `KeyboardRegistry`'s second `LockedCache`, keyed by `compiledSignature(languageId:numpadType:)` | `KeyboardViewModel.compiledDefinition`, a value read directly |
| Solved grid layouts | `GridLayoutSolver` cache | `GridLayoutSolver.solve`, synchronous |
| Per-finger state (phase, sample ring, slide state, trail token, long-press timer) | pooled `PointerTrack`s inside `TouchEngine` | the engine itself; never leaves it |
| Held-back commits | `TouchEngine`'s `CommitQueue` (press order, bounded by `maxPointers`) | flushed synchronously by the event that unblocks them, or by the hold timer |
| Health log | file in the app group, owned by `KeyboardHealthLog` | not at all (write-only from the keyboard) |
| Long-press deadlines, rollover-hold flush | `TouchEngine`'s one `TimerHandle` on the keyboard's `TimerSource` (earliest deadline; lazily re-armed) | n/a |
| Trail fade, settings debounce | one `TimerHandle` each on the same `TimerSource` | n/a |

## Settings: snapshot, then signal

`UserDefaults` is read when settings *change*, not when keys are pressed.

1. The view model builds the snapshots (`GestureTuning.load(from:)`,
   `TypingBehavior.load(from:)`) at init and in `reloadSettings()`. A reload that
   changes nothing leaves the snapshot untouched (equality-guarded), so views
   holding it are not invalidated.
2. `reloadSettings()` runs when a **signal** arrives:
   - in-process `UserDefaults.didChangeNotification` (immediate);
   - the host app's Darwin notification `de.akator.wurstfinger.settingsChanged`
     (debounced 50 ms with task cancellation, so a slider drag reloads once);
   - `viewWillAppear` / host-foreground return (backstop).
3. The host app posts the Darwin notification from `SettingsChangeBroadcaster`,
   which watches the shared defaults store. The keyboard extension never posts it
   (it writes the store too, and must not echo).

### Adding a new setting safely

1. Add a case to `SettingsKey` (the rawValue is the persisted key; never rename
   one that has shipped).
2. Decide who reads it:
   - **The touch/keystroke path** (classification, the pipeline, anything that
     runs between a touch and `insertText`): add a field to `GestureTuning` or
     `TypingBehavior` and read the key in its `load(from:)`. Consume the field
     from the snapshot. *Do not* call `defaults.bool(forKey:)` on the path.
   - **A view that renders it**: read it in `DataDrivenKeyboardRootView` via
     `@AppStorage(..., store: SharedDefaults.store)` and pass it down in
     `KeyRenderSettings`, or give it an observed property on a settings class.
   - **Only the host app**: `@AppStorage` in the settings view; nothing else.
3. Write it from the host app with `@AppStorage(..., store: SharedDefaults.store)`.
   `SettingsChangeBroadcaster` posts the Darwin signal for you; the keyboard picks
   the change up live.
4. In tests, a store write is invisible to a view model until `reloadSettings()`
   runs, exactly as in production. `set(...)` then `vm.reloadSettings()`.

## Background work: rules

- **No `nonisolated(unsafe)`** except on an immutable `static let` of a
  non-`Sendable` type, with a comment. (There are none in `Sources/` today.)
- **No `DispatchQueue.main.sync`, semaphores, or `Thread.sleep`.** The one
  deliberately blocking call is `KeyboardHealthLog.recordAndFlush`, used only on
  the suspension path, where an async hop that "will run soon" may never run.
- **Timers come from the `TimerSource`.** Nothing on the input path spawns
  its own sleeping `Task`: the long press, the rollover flush, the trail fade
  and the settings debounce ask the keyboard's `TimerSource`
  (`KeyboardViewModel.timers`) for a one-shot `TimerHandle`. In production
  that is `SystemTimerSource` — a main-actor `Task` sleeping with
  `Task.sleepWithoutLeeway`, cancelled through the handle and re-checked on
  the actor after the sleep, exactly what the per-site tasks did. In tests it
  is `ManualTimerSource`, advanced by hand: a timing test asserts *when*
  something fires without waiting for it, so a busy machine cannot fail it
  (`TouchEngineTimingTests`, `ExternalSettingsObservationTests`). The engine
  arms **one** timer for the earliest of its deadlines and re-arms when it
  fires; a deadline that goes away is left to that lazy wake-up, so typing
  with long-press digits on costs about one timer task per long-press
  duration rather than one per keystroke.
- **Timers never decide order.** Two main-actor timers (the rollover-hold
  flush and a long press) may wake in either order on a busy main thread, so
  the engine does not rely on the flush running first: a long press that
  fires flushes the commit queue itself and then checks whether an earlier
  finger still holds its place, deferring to that finger's deadline if so.
  Press order is a property of the queue, not of timer scheduling. The
  randomized `TouchEngineFuzzTests` drive timers at arbitrary moments to keep
  it that way.
- **Cancellable observation tied to ownership.** Hold long-lived tasks in a
  `TaskHandle` (cancels on deinit) and notification observers in an
  `ObserverToken` (removes on deinit). A non-isolated `deinit` cannot touch
  main-actor state, so owners have no `deinit` at all.
- **`@preconcurrency import`** only for Apple frameworks that need it, with a
  comment. None needed today.
- **Tests**: a suite that touches a main-actor type is `@MainActor`. A test must
  never weaken an assertion to fit the model; if a behaviour changed, say why in
  the test.

## Unsafe constructs, and why each is sound

`@unchecked Sendable`

- `ObserverToken`: wraps an `NSObjectProtocol` observer that is an immutable
  `let` used only to call `NotificationCenter.removeObserver`, which is
  documented thread-safe.
- `DefaultsHandle`: puts a `UserDefaults` in a `static let`. `UserDefaults` is
  documented thread-safe; the SDK this package builds against does not mark it
  `Sendable`. The box hands out the same instance through an immutable `let`.

`MainActor.assumeIsolated` (each used where the platform already guarantees the
main thread, to avoid an async hop that would change timing)

- `KeyboardViewModel.init`: the `UserDefaults.didChangeNotification` observer is
  registered with `queue: .main`.
- `KeyboardViewController.observeHostLifecycle` (iOS only): the extension-host
  observers are registered with `queue: .main`; the shedding must run in the same
  turn the notification arrives, before the process can be frozen.
- `ChangeCounter` (tests): Observation's `onChange` fires synchronously on the
  mutating thread, which in those tests is main.

`Actor.assumeIsolated`

- `LogDrainer.write` (`KeyboardHealthLog.swift`): the drain loop runs on the same
  serial queue as every `KeyboardHealthLog`, so asserting that actor's isolation
  is true by construction and checked by the runtime.
