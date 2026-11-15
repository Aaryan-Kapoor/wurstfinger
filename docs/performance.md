# Performance: Swift 5 baseline vs. the Swift 6 concurrency architecture

Numbers for the input path before and after the Swift 6 port
([concurrency.md](concurrency.md) explains the architecture). All of them come
from `Sources/WurstfingerBench`, the same program run against both builds.

## How to reproduce

The code under measurement is module-internal, so the bench imports it with
`@testable`; `Package.swift` compiles the kit with testing enabled on macOS
(`testableOnMac`), release builds included:

```sh
swift run -c release WurstfingerBench
# one section only:
swift run -c release WurstfingerBench --timers
# KeyView body-evaluation counts need the DEBUG-only counter, so a debug build:
swift run WurstfingerBench --bodies
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

---

# Rework: zero-allocation input path, compiled resolution, cheaper keys

The second measured pass (`docs/rework-review.md` lists the findings it
addressed). All rows come from the same bench binary: the new sections 8–10
were copied into an export of the pre-rework commit (`4a98cef`) and run
there for the **before** column, then run on this tree for **after**, back to
back on the same machine, nothing else in flight. Release builds,
`-enable-testing`. Timings are p50 unless noted; allocation counts are exact
(a `malloc_logger` hook in the `WurstfingerBenchAllocCounter` C target counts
every allocation the process makes between two points on the main actor).

```sh
swift run -c release WurstfingerBench --alloc    # section 8
swift run -c release WurstfingerBench --memory   # section 9
swift run -c release WurstfingerBench --switch   # section 10 (debug build adds body counts)
```

## Allocations and latency per operation (section 8)

| Operation | Before: allocs / bytes | After: allocs / bytes | Before p50 | After p50 |
| --- | --- | --- | --- | --- |
| 8a tap keystroke: engine → view model → pipeline → target | 14 / 375 B | **9 / 87 B** | – | – |
| 8b flick keystroke: down, 8 one-sample moves, up | 198 / 18,095 B | **9 / 87 B** | – | – |
| 8c one drag move, 1 sample (engine + view model) | 23.2 / 2,923 B | **0 / 0** | 5,291 ns | **625 ns** |
| 8c one drag move, 4 coalesced samples | 23.4 / 4,702 B | **0 / 0** | 6,500 ns | **833 ns** |
| 8d one drag move, 1 sample, engine only (no-op actions) | 23.2 / 2,923 B | **0 / 0** | 4,708 ns | **542 ns** |
| 8d one drag move, 4 samples, engine only | 23.4 / 4,702 B | **0 / 0** | 5,875 ns | **875 ns** |
| 8e `classify(positions:…tuning:)` (array entry, tests/tools) | 20.5 / 3,502 B | **1 / 803 B** | 1,958 ns | **667 ns** |
| 8f `previewLabel` (live guide, per candidate change) | 0 | 0 | – | – |
| 8g `handleGesture(.tap)` → pipeline → target | 3 / 29 B | 3 / 29 B | 1,042 ns | **916 ns** |
| 8g-i `ActionPipeline.process` alone | – | **0** | – | – |
| 8g-ii `OSSignposter` begin/end interval pair alone | – | 3 / 29 B | – | – |
| 8h tap keystroke with long-press digits on (one timer task per touch-down) | 23 / 1,927 B | **18 / 1,639 B** | – | – |
| 3b compose sequence (tap + swipe) → target | – | – | 2,458 ns | **2,167 ns** |
| 4d globe-key language switch, warm cache | – | – | 280 µs | **158 µs** |
| 4c globe-key language switch, cold cache | – | – | 450 µs | 953 µs (now also compiles the tables; the prewarm exists so this branch is not taken in practice) |

What the rows say:

- **A drag sample allocates nothing and costs an eighth of what it did.**
  The engine classifies the whole path on every move event; that
  classification went from ~20 arrays (ring-buffer read, origin anchoring,
  three filter stages, smoothing kernel rebuilt per call, two feature
  helpers) plus a closure context per sample to zero, working in a
  `ClassificationScratch` arena the engine owns. 625 ns per move at 240 Hz
  is 0.015 % of the main thread.
- **The remaining 9 allocations per keystroke** are: 3 from the
  `OSSignposter` interval state (built even with nobody recording;
  `isEnabled` is true regardless, a guard was measured useless), the rest
  from the touch-down/release bookkeeping the views observe
  (`KeyPressRegistry` mutations through Observation, the guide value, the
  trail's fade task). The pipeline itself allocates nothing (8g-i).
- **Resolution is a table.** `previewLabel` and dispatch no longer walk the
  resolver chain; the warm language switch halved because the tables come
  from the same cache the prewarm fills.
- The `handleGesture` row is dominated by the middlewares' string work on
  the document context, not by dispatch; the existential middleware array
  was measured (8g-i) and left.

## Memory (section 9)

| What | Before | After |
| --- | --- | --- |
| heap per language definition (mean over 26) | 47.4 KB | 47.3 KB (unchanged: the definition model was not touched) |
| all 26 definitions resident | 1.20 MB | 1.20 MB |
| `KeyboardRegistry.prewarm(all 26)` heap delta | 1.19 MB | 3.2 MB — the prewarm now also compiles every language's tables (~77 KB per language: the deduplicated binding pool dominates, the `Int32` tables are ~1.3 KB per mode). In the keyboard only the *enabled* languages are prewarmed (one to three), and the pre-suspension shedding evicts the tables with the definitions, so the suspended footprint is unchanged. |
| `GridLayoutSolver` memo, 8 distinct arrangements | 8 KB | 8 KB |
| one keyboard view graph, marginal heap / `phys_footprint` (off-screen `NSHostingView`, 390 pt, de_DE) | 3.1 MB / 5.5 MB | 3.1 MB / 5.6 MB (noise: ±0.2 MB run to run) |
| first graph incl. SwiftUI warm-up, heap / footprint | 7.0 / 13.5 MB | 6.8 / 14.4 MB |
| a mode switch kept alive, heap delta | +23 KB … −300 KB | −70 KB … −300 KB (noise; a switch frees as much as it adds) |
| `TouchEngine` with 10 warmed tracks | 39.4 KB | 35.1 KB (non-optional ring, scratch arena of 5.8 KB included) |

`MemoryLayout` sizes: `KeyDefinition` 41 B, `KeyBinding` 80 B,
`KeyboardMode` 40 B, `GestureTuning` 160 B, `TouchSample` 24 B.

Decisions this supports:

- **Grids are rebuilt on a mode switch, not kept alive.** A switch costs
  ~55–65 µs in `handleGesture` and ~115–160 µs with a layout and display
  pass (section 10, both trees within noise of each other), and its memory
  delta is noise. A second resident grid would cost on the order of the
  marginal graph above, 3 MB heap / 5 MB footprint, against a 48–66 MB
  jetsam limit. Slot ids are the view identities, so the rebuild is a diff:
  12 of ~14 key bodies run on a letters → numeric switch (13 before; the
  `Equatable` key skips the ones whose inputs did not change), 11 on the way
  back (12 before).
- **The hosting graph is the footprint.** Definitions, tables and the
  engine together are under 2 MB with every language loaded; one view graph
  is 3 MB of heap and 5–6 MB of footprint, and the SwiftUI warm-up another
  ~7 MB that never comes back. The pre-suspension teardown of the hosting
  controller remains the right lever; nothing in the data model is worth a
  byte-level optimisation beside it.

## Mode switch (section 10)

| | Before p50 | After p50 |
| --- | --- | --- |
| main → numeric, `handleGesture` only | 67 µs | 54–66 µs |
| main → numeric, + layout + display pass | 155 µs | 141–162 µs |
| numeric → main, `handleGesture` only | 72 µs | 50–65 µs |
| numeric → main, + layout + display pass | 156 µs | 115–162 µs |
| `KeyView.body` evaluations per switch (debug) | 13 / 12 | 12 / 11 |

The "until settled" rows are bounded below by the 20 ms settle loop and are
not reported. The work a key body does shrank (nine `Font` boxes → none,
no `AnyShapeStyle`, constant fills), but a mode switch genuinely changes
almost every key, so the switch itself stays where it was, within noise.

## Rendering (row 5, `--render`)

`DataDrivenKeyboardRootView` through `ImageRenderer`, 59 fresh renders,
alternating the two binaries five times on the same machine (p50, ms):
before 28.5 / 21.5 / 16.6 / 14.2 / 14.8, after 25.5 / 37.7 / 15.7 / 15.3 /
14.5. The spread is the machine (load average 50–120 while measuring), not
the trees: the pairs converge as the load drops. No measurable change, as
expected — a fresh render pays SwiftUI's graph construction, which the key
changes do not touch; what they reduce is the per-body work and the number
of bodies on an update (section 10).

## Caveats

- Same machine, back to back, but still a shared desktop: treat ratios that
  hold in every row (allocations, the drag sample, classification) as real
  and differences under ~20 % (dispatch, switch timings, memory noise) as
  noise.
- The long-press row (8h) counts the timer task's creation; its cancelled
  body runs after the row ends and is not counted.
- Allocation counts are process-wide; the rows run on the main actor with
  every prewarm drained first, so they are the operation's own.

## Second pass (after the feel, layout and modifier merges)

Release build, `WurstfingerBench --alloc` and `--memory`, same machine; findings
S1–S11 in `docs/rework-review.md`.

| Operation | After the feel merge | Second pass |
| --- | --- | --- |
| tap keystroke, engine → pipeline → target (8a) | 9 allocs | **0** |
| flick keystroke, down + 8 moves + up (8b) | 13 allocs | **0** |
| tap with long press enabled (8h) | 18 allocs (a timer task per touch-down) | **0** (one engine timer, re-armed lazily) |
| drag move, 1 sample, engine + view model (8c) | 0 allocs | 0 allocs, p50 0.63 µs, p99 2.0 µs |
| `os_signpost` begin/end pair (8g-ii) | 3 allocs (`OSSignposter`) | **0** |
| live preview lookup (8f) | 0 allocs | 0 allocs |
| trail frame, 40 samples (8i) | ~15 allocs (eight arrays plus the `Path`) | 7 allocs, all the `Path`'s CoreGraphics storage |
| one keyboard view graph, marginal heap (9e) | 3.83 MB (hints as view stacks) | **2.31 MB** (hints as one `Canvas` per key) |
| `ImageRenderer` render of the keyboard, warm p50 (row 5) | 38.6 ms | 22.3 ms |
| `TouchEngine`, 10 warmed tracks, heap (9d) | 35.1 KB | 64.2 KB (the trail's scratch buffers now live with the engine instead of being rebuilt each frame) |

The test suite went from ~30 s to ~11 s once every timing test ran on the
manual clock instead of sleeping.

## Third pass (completions, derived feel, emoji, optimized layouts, forgiving gestures)

Release build, `WurstfingerBench --alloc` and `--memory`, same machine.

| Operation | Before this round | Third pass |
| --- | --- | --- |
| tap / flick / long-press keystroke (8a, 8b, 8h) | 0 allocs | 0 allocs |
| tap, flick, long-press tap with the completion row on (8j, 8k, 8j′) | – | 0 allocs (a coalesced poke of one long-lived waker) |
| tap with the row on and a run-loop turn between keystrokes (8m) | – | 1 alloc, 40 B (resuming the waker's reader) |
| the deferred lookup itself (8l) | – | 9 allocs, 376 B, after the keystroke |
| tap / flick with key sounds on, a voice and stroke derived (8n, 8o, 8p) | – | 0 allocs |
| emoji keystroke, recents reordered (8q, 8q-i) | – | 0 allocs |
| classify (8e), trail frame (8i) | 1 alloc / 7 allocs | unchanged |
| one keyboard view graph, marginal heap (9c) | 2.31 MB | **1.68 MB**; 6.52 MB under VoiceOver or Switch Control |
| heap per language definition, mean (9a) | 47.4 KB | 90.3 KB (the two emoji pages in every layout) |

The view graph had grown to 6.52 MB with the per-key VoiceOver actions of #231:
SwiftUI builds a view for every custom action of every key, about 4.9 MB for
the whole keyboard, whether or not anything reads them. They are now attached
only while VoiceOver or Switch Control runs (`KeyAccessibilityActions`), and
row 9c prices them separately ("per graph with VoiceOver's key actions").
