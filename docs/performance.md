# Performance: Swift 5 baseline vs. the Swift 6 concurrency architecture

Numbers for the input path before and after the Swift 6 port
([concurrency.md](concurrency.md) explains the architecture). All of them come
from `Sources/WurstfingerBench`, the same program run against both builds.

## How to reproduce

The code under measurement is module-internal, so the bench imports it with
`@testable` and needs testability enabled in the release build:

```sh
swift run -c release -Xswiftc -enable-testing WurstfingerBench
# one section only:
swift run -c release -Xswiftc -enable-testing WurstfingerBench --timers
# KeyView body-evaluation counts need the DEBUG-only counter, so a debug build:
swift run -Xswiftc -enable-testing WurstfingerBench --bodies
```

It prints p50 / p99 / max in **nanoseconds per operation** over a deterministic
corpus (SplitMix64 seed, ~10k synthetic gestures: taps, 8-way flicks, return
swipes and circles, with jitter). `swift run` rebuilds the Kit in release mode,
which takes several minutes the first time.

## Method and caveats (read before trusting a digit)

- **Baseline** is the Swift 5 build at the commit before the port (same bench,
  same machine). **After** is the Swift 6 build in this branch.
- Each configuration was run **three times, alternating** (baseline, after,
  baseline, ...), and the table shows the **median of the three** for each
  statistic. The machine was shared with other builds the whole time (load
  average 30-70 on 11 cores), so absolute figures drift by tens of percent between
  runs and `max` is dominated by scheduler spikes. Treat ratios that held in
  every run (dispatch, snapshot classification, timers, body counts) as real and
  differences under ~30% (render, definition builds, the legacy classification
  row) as noise.
- Release build, `-enable-testing`. Testability keeps internal symbols exported,
  so absolute numbers sit slightly above a shipping build's.

## Results

p50 / p99 / max, nanoseconds. "-" means the row did not exist or is the same
code on both sides.

| # | What | Before (Swift 5) p50 / p99 / max | After (Swift 6) p50 / p99 / max |
| --- | --- | --- | --- |
| 1 | `classify(positions:aspectRatio:)`, production entry, **including its settings reads** | 4,083 / 36,000 / 736,083 | 1,958 / 23,709 / 845,250 (production path is now the snapshot, row 2b) |
| 1' | the same legacy entry point, still reading `UserDefaults` (kept for tests/tools) | (row 1) | 5,375 / 42,958 / 1,413,792 |
| 2 | `classify(config:thresholds:)`, explicit snapshot, no defaults reads | 1,833 / 16,500 / 421,625 | 2,875 / 23,333 / 488,875 (same code; run-to-run noise) |
| 2b | `classify(positions:aspectRatio:tuning:)` with a `GestureTuning` snapshot | - | 1,958 / 23,709 / 845,250 |
| 3a | keystroke dispatch: `handleGesture` tap -> pipeline -> mock target | 6,209 / 95,041 / 5,345,041 | 1,917 / 8,333 / 21,939,292 |
| 3b | compose sequence (tap `a` + swipe `^`) -> target | 12,875 / 112,959 / 4,245,375 | 4,125 / 22,625 / 14,921,916 |
| 4a | cold `KeyboardDefinition` build, one language (130 builds, 26 languages x 5) | 101,583 / 1,172,208 / 6,717,166 | 112,333 / 291,000 / 5,066,375 (unchanged) |
| 4b | cold build, all 26 languages, total | 10.1 ms | 8.6 ms (unchanged; cold builds are single-shot) |
| 4c | globe-key language switch, cache **cold** (no prewarm) | - | 680,916 / 1,991,250 |
| 4d | globe-key language switch, after the **prewarm** | - | 348,584 / 791,667 |
| 5 | `DataDrivenKeyboardRootView` `ImageRenderer` render (59 fresh renders) | 40,082,917 / 161,743,917 | 41,844,542 / 150,384,750 (unchanged: dominated by SwiftUI) |
| 6a | timer fire lateness, `DispatchWorkItem` + `main.asyncAfter` (the old long-press timer) | 719,417 / 3,794,125 / 4,640,041 | 1,010,333 / 3,933,291 / 4,138,667 |
| 6b | timer fire lateness, `@MainActor Task` + `Task.sleep` (default leeway) | 1,436,250 / 4,382,000 / 4,786,375 | 1,151,333 / 4,767,458 / 4,860,166 |
| 6c | timer fire lateness, `Task.sleep(until:tolerance: .zero)` (**chosen**) | 122,375 / 1,601,958 / 1,960,542 | 182,125 / 1,602,666 / 1,766,833 |

The timer rows (6a-6c) measure the *mechanism*, not the port, so both columns
exercise the same code; the "after" column is the chosen one (6c).

### KeyView body re-evaluations per event (`--bodies`, debug build, 14 keys on screen)

| Event | Before (`ObservableObject`) | After (`@Observable`) |
| --- | --- | --- |
| a tap keystroke that does not change mode | 0 | 0 |
| `reloadSettings()` with nothing changed | 0 | 0 |
| a haptic intensity slider moves | **14** (every key) | **0** |
| a mode switch (letters -> numeric) | 15 | 15 |

A mode switch genuinely changes what every key shows, so it keeps re-evaluating
the grid. What the Observation migration removed is the *whole-keyboard*
invalidation that came from forwarding `objectWillChange` out of the haptic and
layout settings objects: a change to a setting the keys do not read now touches
no key. (A tap never invalidated keys in the old build either, which is why that
row is 0 on both sides; the per-touch `isActive` flip a real gesture causes is a
single key's own `@State` and is the same before and after.)

## What moved, and why

### The touch path no longer reads `UserDefaults` (rows 1, 3a, 3b)

Classifying a release used to rebuild the preprocessor configuration and the
classification thresholds from `UserDefaults` -- about a dozen keyed lookups on
the main thread between the finger lifting and the character appearing -- and the
pipeline did one more lookup per feature toggle (auto-capitalize, double-space
period, cut-all) on every keystroke. Those values change when the user visits
Settings, not while typing. They are now `Sendable` snapshots (`GestureTuning`,
`TypingBehavior`) held by the view model and refreshed only when a settings
signal arrives.

- Classification through the snapshot: **~4.1 us -> ~2.0 us** at the median. Row
  2 vs 1 on the baseline is the same measurement from the other side: the
  explicit-snapshot variant (~1.8 us) never paid the reads.
- A full tap keystroke through the pipeline: **~6.2 us -> ~1.9 us** (the per-keystroke feature-toggle
  reads were most of the difference). The compose sequence
  (two dispatches): **~12.9 us -> ~4.1 us**.
- Both are far below a frame (8.3 ms at 120 Hz); what the change buys is less
  main-thread work and, more importantly, no store access whose latency the
  keyboard does not control (the shared app-group store is a cross-process
  object).

### Definition prewarm (rows 4c / 4d)

A language switch used to build the target definition on the main thread on a
miss. The registry now builds every enabled language at `.utility` priority when
the view model loads (and again on each appearance, since pre-suspension shedding
evicts them). With the cache warm, a globe-key switch drops from a median of
**~0.68 ms to ~0.35 ms** and, more to the point, loses the build's tail: the
slowest definitions (Japanese katakana, ~3-5 ms cold) can no longer land on the
main thread mid-typing. The cache lock is held for the dictionary get/insert only;
a build runs under a per-key lock, so an active-language hit is never blocked by
a prewarm building another language.

### Timers (rows 6a-6c)

The long-press timer and the trail fade moved from `DispatchWorkItem` +
`asyncAfter` to main-actor `Task`s. Measured over 1,000 timers, the default
`Task.sleep` fires about as late as GCD (median ~1-2 ms), but a sleep with **zero
timer leeway** fires a median **~0.1-0.2 ms** after its deadline (about 5x less)
with a tighter p99, so that is what `Task.sleepWithoutLeeway` does. At 0.7 s the
difference is not perceptible; the point is that the closure that types a digit
is now a main-actor-isolated task the compiler checks, at no latency cost.

### Rendering and definition builds (rows 4a, 4b, 5)

Unchanged, as expected: a cold definition build is ~0.1 ms (all 26 languages in
~9 ms, the single slowest being katakana at a few ms), and an `ImageRenderer`
render is dominated by SwiftUI. The port does not touch either.

## What these numbers do not show

- **Haptic `prepare()` on touch-down** and the **`OSSignposter` intervals** have no
  bench row: generator latency exists only on a device with a Taptic Engine, and
  signposts cost nothing unless Instruments is recording. Profile them on a
  device with the `os_signpost` instrument, subsystem `de.akator.wurstfinger`,
  category `input` (`keystroke`, with `classify` and `dispatch` nested inside).
- **Live settings sync** (the host app's Darwin notification) is a behaviour
  change, not a speed change; it is covered by tests, not by the bench.
