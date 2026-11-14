# Rework review: the input path and the keyboard's rendering

A structural review of everything between a finger and `insertText`, and of
the SwiftUI graph that draws the keys, written before any code was changed.
Findings are ranked by user impact: things that can type the wrong thing or
wedge first, then latency, then memory, then where the type system could be
doing more. Each finding names the file and line as of the review commit
(`4a98cef`) and the scenario in which it bites. The second half of the file
("What was done") records what the rework changed and what it left alone.

Baseline numbers (release bench, this machine, `swift run -c release
WurstfingerBench`, before any change): speculative/final classification of one
gesture ~1.9 us p50; a tap keystroke through the pipeline ~1.0 us p50; a warm
language switch ~280 us; an `ImageRenderer` render of the whole keyboard ~37 ms.
1472 tests pass. Allocation counts had no bench row yet; they were the first
thing the rework added, and the "before" column of `docs/performance.md`
records them.

## 1. Correctness and reliability

### R1. A heap closure is allocated per drag sample (and per release) — `TouchEngine.swift:204`, `:258`

`moved` calls `track.record(translation) { [actions] key, phase in actions.slide(key, phase) }`
for every coalesced sample. The parameter type is
`((KeyDefinition, SlidePhase) -> Void)?`; an optional closure is implicitly
*escaping*, so the closure's context — a copy of `TouchEngineActions`, five
closure references — is heap-allocated and retained/released on every sample,
flick keys included (where it is never called). At 120–240 Hz this is one
malloc + five retains + five releases per sample on the engine path, which
is exactly the path the engine's own doc comment says "allocates nothing".
Not a correctness bug, but the first reason the "zero allocations per drag
sample" target was not met.

### R2. The speculative classifier allocates ~10 arrays per `moved` — `TouchEngine.swift:297–301`, `KeyGestureRecognizer.swift:51`, `GesturePreprocessor.swift:239–574`, `GestureFeatureCalculations.swift:130,186`

`speculate` runs the full classification on every `moved` event:
`track.flick.path` (ring buffer `elements` → `compactMap` → array, then
`anchoringOrigin` prepends the origin → another array), `filterJitter`,
`filterOutliers`, `normalizeAspectRatio` (`map`), `smoothSavitzkyGolay` (plus
`savitzkyGolayCoefficients` rebuilt with `.map` on every call),
`circularity` (`radii` array), `turnConsistency` (deduplicated `pts` array).
Measured: 10 heap allocations per drag event. The ring buffer itself stores
`[CGPoint?]` — 24 bytes per slot instead of 16 and a branch per read.

### R3. A long press that fired still holds later keystrokes back — `TouchEngine.swift:335–347`, `LongPressScheduler.swift:567–570`

`longPressFired` calls `flushPending(at: now())` with the comment "a consumed
finger no longer holds back later keystrokes", but `consumedTouch` is set by
`LongPressScheduler.runFire` only *after* the fire closure returns. At the
moment of the flush `holdsBack` still sees `!consumedTouch == true`. The
flush therefore releases nothing. It is masked today because
`longPressDuration` (0.7 s) is longer than `rolloverHold` (0.25 s), so the
time guard has already expired; the moment either constant moves, or a
tuning exposes the long-press duration, the queue wedges until the hold
expires. The state ("this finger has typed") lives in the wrong object and is
written after the code that needs it.

### R4. A fired long press bypasses the press-order queue — `TouchEngine.swift:339`

`actions.longPress(track.key)` dispatches straight into the view model while
`enqueue`/`flushPending` is what every other commit goes through. Ordering is
only preserved because of the same constant relationship as R3
(`longPressDuration > rolloverHold`): an earlier finger's hold has always
expired by the time a long press fires. Nothing checks that invariant.

### R5. A key held by two fingers keeps a stale emphasized hint — `TouchEngine.swift:417–423`, `KeyPressState.swift:72–82`

`KeyPressCell.candidate` is per *key*, not per finger. Two fingers on the same
key: finger A flicks right (cell.candidate = `.swipeRight`), finger B rests.
A releases; `release(track)` keeps the cell pressed (B is still on it) and
never clears the candidate, so the key keeps A's emphasized hint until B's
own speculation overwrites it or B lifts. Cosmetic, but visible.

### R6. `configure` updates a track's key but not its kind — `TouchEngine.swift:145–151`

A mode switch mid-gesture (one thumb taps shift while the other is
mid-flick) hands the live track the new mode's `KeyDefinition` for the same
slot id — correct, and what makes the rolled-over letter come out shifted —
but `track.kind` (flick vs slide) and the slide configuration were fixed at
touch-down. A slot that is a flick key in one mode and a slide key in another
would keep classifying with the old kind. No shipped layout does this; the
invariant is unstated.

### R7. The guide card belongs to the most recent flick finger only — `TouchEngine.swift:189`, `KeyPressState.swift:98–111`

A second finger replaces the guide; when it lifts, `clearGuide(touchID:)`
hides it, and the first finger — still moving — gets no card back. By design
("the finger most recently put down"), but the first thumb loses its preview
for the rest of its gesture.

### R8. `holdsBack` compares two clocks — `TouchEngine.swift:559–566`, `:386–398`

`pressTime` is a touch timestamp; `scheduleFlush` and the fired task use the
engine's `now()`. On iOS both are system uptime, so it holds. The scenario
harness feeds synthetic times (starting at 1000) with the real uptime clock,
which happens to work because real uptime is larger. Nothing in the types says
the two must agree.

### R9. `scheduleFlush` allocates a `Task` on every blocked flush — `TouchEngine.swift:386–398`

Each `enqueue`/`abandon`/`ended` that finds a blocker cancels and re-creates
the flush task. With two thumbs overlapping that is a few task allocations per
keystroke pair. Bounded and correct; just not free.

### R10. The trail allocates a fresh array per touch-down — `GestureTrail.swift:46`

`begin` does `samples = [sample]`, dropping the buffer's capacity. One
allocation per keystroke with the trail on, plus `removeFirst(n)` shifting the
buffer on every sample once it is full.

### R11. Dispatch copies whole definition values on every keystroke — `KeyboardViewModel+Pipeline.swift:377–386`, `PrimaryResolver.swift`, `GhostKeyResolver.swift`

`performGesture` → `activeModeFromDefinition` copies a `KeyboardMode` (four
retains: name, keys, arrangements, autoTransitions), each resolver does
`mode.key(for:)` (a `String` hash plus a `KeyDefinition` copy — three
retains), then `key.bindings[gesture]`. Three resolvers → up to three `String`
hashes and ~10 retain/release pairs per keystroke, and the same again for every
candidate change in the live preview. The resolution result depends only on
(mode, key, gesture, isReturn) and the definition — a table.

### R12. The pipeline and resolver chain are existential arrays — `ActionPipeline.swift:20`, `GestureResolverChain.swift:16`

`[ActionMiddleware]` (ten witnesses per keystroke, two of them classes) and
`[GestureResolver]`. Each hop is a protocol-witness call through an existential
box. Cheap individually; measured below.

### R13. The view model's clipboard is `any Clipboard` — `KeyboardViewModel.swift:204`

Only touched by copy/cut/paste (not per keystroke). Left as is: an existential
on a path that runs once per deliberate gesture pulls no weight either way.

## 2. Latency

### L1. KeyView builds nine `Font` values per body — `KeyView.swift:280, 428, 485–500`

`Font.system(size:weight:design:)` allocates a boxed font descriptor. One for
the label and one per hint (up to eight), on every body evaluation, for ~40
keys: ~360 allocations per mode switch, all deriving from the same metrics.

### L2. `AnyShapeStyle` on the key's centre label — `KeyView.swift:403–405`

`centerStyle` boxes a `Color` in `AnyShapeStyle` per body. Both branches are
`Color`; the box is pure overhead.

### L3. `Color(.systemGray4)`/`Color(.secondarySystemBackground)` per body — `KeyView.swift:241–246`

UIColor-to-Color bridging per key per body. They are constants.

### L4. KeyView carries `tuning: GestureTuning` it never draws — `KeyView.swift:90`

Left over from the per-key gesture recognizer. It makes every key's inputs
change when an expert slider moves, so a tuning change re-evaluates all ~40
bodies for nothing. With it gone and the view `Equatable`, that cost is zero.

### L5. `TouchGuideOverlay` uses a `GeometryReader` — `TouchGuideOverlay.swift:34`

The grid's size is a pure function of the metrics and the solved cells (the
engine already computes it in `gridGeometry(forContainerWidth:)`); the reader
adds a layout pass and a container.

### L6. `KeyboardGridView.body` re-solves and re-hashes the arrangement — `KeyboardGridView.swift:65–66, 74`

`GridLayoutSolver.solve` hashes the whole `GridArrangement` (every placement's
key id) to find its memo; `cells.map { … }.max()` and
`Array(cells.enumerated())` allocate. Per body, not per keystroke.

### L7. The guide label resolves through the same chain as dispatch — `KeyboardViewModel+Input.swift:516–537`

Every candidate change (a few per flick) pays R11 again.

## 3. Memory

### M1. No measurement existed — `WurstfingerBench`

Neither the hosting graph nor a definition nor the caches had a number. The
controller's own comment says the SwiftUI graph dominates the suspended
footprint, so the rework's first memory step was a bench row for it.

### M2. `KeyPressRegistry.cells` grows with every key id ever seen — `KeyPressState.swift:57`

Bounded by the union of slot ids across languages (a few dozen), never
trimmed. Fine in practice; stated here so nobody adds per-touch ids to it.

### M3. `GridLayoutSolver`'s memo pins arrangement storage — `GridLayoutSolver.swift:34`

Already evicted on shedding; noted as the one cache keyed by a value that
owns heap storage.

### M4. `RingBuffer<CGPoint?>` — `RingBuffer.swift:595`

120 × 24 bytes per track slot instead of 120 × 16, ten slots: ~10 KB of
padding, plus the optional check per read.

## 4. Type modelling

### T1. Per-finger state is five loose flags — `TouchEngine.swift:487–579`

`candidate`, `candidateIsReturn`, `candidateIsLongSwipe`,
`longPress.consumedTouch`, `flick.isTracking`, `slide.isSliding`,
`slide.dragStarted`. The representable combinations include "a slide key with
a flick candidate" and "consumed by a long press and still speculating".
R3 is a direct consequence: the "consumed" fact lives on the scheduler object
rather than on the track's state.

### T2. `KeyDefinition` is threaded where only an identity is needed — `TouchEngine.swift:471–480`, `TouchEngineActions`

Pending commits and callbacks carry whole definitions (dictionary, array,
strings) when the receiver only reads `id` and `slideType`. Each copy is three
retains. Kept for API stability with the parallel agents; the engine now
keeps its own keys array and the pending queue stores the key's index.

### T3. Resolution is re-derived per gesture — see R11

A per-mode table of (key slot × gesture × return) → binding index makes the
resolved result a value, built once off-main, with resolution an array index.

### T4. `~Copyable` per-finger state was considered and rejected

Swift 6.1's `Array` cannot hold non-copyable elements and `InlineArray` is not
available, so a pool of `~Copyable` tracks has nowhere to live without unsafe
storage. The pooled final class keeps the allocation count at zero after
warm-up; the phase enum (T1) gives the state-machine guarantees that mattered.

---

## What was done

Numbers (before/after, same bench binary against the pre-rework tree and
this one) are in `docs/performance.md`, section "Rework"; the isolation map
is in `docs/concurrency.md`. Finding numbers below refer to the first half.

### Fixed

- **R3 / R4 / long-press ordering** — `TouchEngine.swift`. Per-finger state
  is now a `PointerTrack.Phase` (`resting`, `heading(candidate)`, `sliding`,
  `longPressed`); the "consumed" fact is the track's own phase, set *before*
  the flush that reads it. A fired long press flushes the commit queue first
  and, if an earlier finger still holds its place, re-arms itself for that
  finger's deadline instead of dispatching out of order. A second fire on an
  already long-pressed finger is a no-op by construction. The randomized
  suite (`TouchEngineFuzzTests`) found two of these three before the fix:
  the double fire and the out-of-order long press — and a third, not in the
  review: a long press that fires after a blocker's hold had *expired but
  not yet been flushed* (the flush timer had not run) overtook a commit still
  in the queue.
- **R1** — the per-sample closure is gone. `SlideGestureState.Update` reports
  `began`/`deltaX` as fields (its `phases` array is now a computed view for
  tests), and the engine dispatches them itself.
- **R2 / M4** — classification is allocation-free on the engine path: a
  non-optional `RingBuffer`, a `ClassificationScratch` arena owned by the
  engine, buffer-based preprocessor steps, static Savitzky–Golay kernels,
  two-pass circularity and streaming turn consistency. The array entry
  points remain as thin wrappers; ~2,400 seeded paths pin the two paths
  equal (`ClassificationScratchTests`).
- **R5** — a lifted finger hands the key's emphasized hint to the finger
  still on it, or clears it.
- **R6** — `configure` abandons a track whose slot changed kind (flick ↔
  slide) rather than continuing with the wrong state machine.
- **R9** — the hold-flush task is reused when the deadline is unchanged.
- **R10** — the trail keeps its buffer across touches.
- **R11 / T3 / L7** — resolution is a table: `CompiledMode` /
  `CompiledDefinition` (`Runtime/Pipeline/CompiledMode.swift`), filled by
  running the existing resolvers over every (key, gesture, return) and the
  three circular branches, deduplicating bindings into a pool. Built once per
  (language, numpad style), cached in `KeyboardRegistry` beside the
  definition and compiled by the same prewarm. Dispatch and the live preview
  do one `String` hash (key id → slot) and one array index.
  `CompiledModeTests` prove equality against the chains for all 26 languages,
  every mode, key, gesture and return flag, both numpad styles.
- **L1–L5** — `KeyView` takes a `KeyTypography` built once per grid (nine
  `Font` boxes per key per body → zero), is `Equatable` and installed with
  `.equatable()` (the `onGesture` closure is excluded from `==`, it is the
  same forwarding closure each time), drops the unused `tuning` input, uses
  constant fills and a plain `Color` for the centre style. The guide overlay
  takes the grid's computed size instead of a `GeometryReader`. The grid
  identifies keys by slot id directly (`ForEach(cells, id: \.keyId)`) and no
  longer allocates an enumerated copy per body.

### Measured and left alone (with the reason)

- **R12 (existential middlewares / resolvers).** The resolver chain is gone
  from the hot path (it is now the compiler of the tables). The middleware
  array stays: a dispatch through it costs ~1 µs and the bench's breakdown
  rows show the pipeline itself allocates nothing — the three allocations a
  dispatch makes are `OSSignposter.beginInterval`'s interval state, built
  even with no client recording (`isEnabled` reports true regardless, so a
  guard was tried and measured useless; the intervals stay because the
  Instruments workflow in `docs/performance.md` depends on them). Replacing ten `ActionMiddleware`
  witnesses with a hand-nested static chain would buy tens of nanoseconds
  per keystroke at the price of the pipeline's composability (tests build
  pipelines from arbitrary middlewares).
- **R13 (`any Clipboard`).** Copy/cut/paste only.
- **Long-press `Task` per touch-down (R9's cousin).** One task per keystroke
  while long-press digits are on; it is the timer. A single engine-level
  deadline timer would remove it; not done in this pass.
- **Keeping mode grids alive.** Measured (`--switch`, `--memory`): a mode
  switch is ~55 µs of `handleGesture` plus ~120 µs of layout and display,
  and its memory delta is noise (hundreds of KB, net negative as often as
  not). A second resident grid costs on the order of the marginal view
  graph (~2 MB heap, ~5–6 MB footprint). Under a 48–66 MB jetsam limit that
  trade is wrong; grids are rebuilt, with stable slot identities so the
  rebuild is a diff.
- **Trail overlay per-frame arrays** (`visiblePoints`, the `Path`). Only
  with the trail setting on, and a `Canvas` needs a `Path` per frame anyway.
- **`~Copyable` per-finger state (T4).** See the `PointerTrack` doc comment.

### Added

- `TouchEngineFuzzTests`: seeded random multi-finger interleavings of
  began/moved/ended/cancelled/configure/timer-fire/flush/cancelAll (140
  seeds × 300 steps, with and without long presses, with and without
  fingers sharing a key), checking after every step: fingers down ==
  pressed keys, pools and queue bounded, nothing pending or guided once all
  fingers lifted; and at the end: at most one commit per finger, and press
  order unless the earlier finger had given up its place (hold expired,
  sliding, or already long-pressed). Each touch's key is stamped with the
  finger's press order through `configure`, which the engine hands back
  verbatim, so attribution is exact even for commits that arrive after the
  finger lifted.
- Bench sections 8 (allocations per keystroke / drag sample / classify /
  resolve / dispatch, via a `malloc_logger` hook in a small C target),
  9 (heap and `phys_footprint` of definitions, caches, the hosting graph, the
  engine) and 10 (mode-switch timing and body counts).

### API changes the lead must reconcile with the `feel` worktree

- `KeyView.init` lost `tuning:` and gained `typography: KeyTypography? = nil`
  (defaults to building one from `metrics`); `KeyView` is `Equatable`.
- `TouchGuideOverlay.init` gained `gridSize: CGSize` (required).
- `SlideGestureState.Update.phases` is now computed from `began`/`deltaX`.
- `KeyStyle` is `CaseIterable`.
- `TouchEngineActions`, `KeyPressRegistry`, `KeyPressCell`, `TouchGuide`:
  unchanged. `TouchEngine`'s public surface is unchanged;
  `rolloverHold`/`maxPointers` are now `nonisolated static let`.
- `KeyboardViewModel.resolverChain` / `returnSwipeResolverChain` are gone;
  `compiledDefinition` replaces them. `rebuildResolverChain()` keeps its
  name and now fills the compiled tables.
- `KeyboardRegistry`: `compiled(for:signature:)`,
  `compiledSignature(languageId:numpadType:)`, `isCompiledCached(signature:)`;
  `LockedCache.removeAll(where:)`.
- New: `ClassificationScratch`, `KeyGestureSequence.withOriginAnchoredPath`,
  `handleEnded(…scratch:)`, `KeyGestureRecognizer.classify(path:…scratch:)`,
  buffer variants of the preprocessor steps, `RingBuffer.copyOrdered(into:)`
  and `count`.
