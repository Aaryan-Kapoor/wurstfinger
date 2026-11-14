//
//  Allocations.swift
//  WurstfingerBench
//
//  Section 8: how many heap allocations (and requested bytes) each step of the
//  input path makes. Time says how long a keystroke takes; allocations say how
//  much garbage-collection-free pressure it puts on the allocator, which is
//  what shows up as jitter on a phone under memory load. The engine's design
//  goal is that a touch allocates no bookkeeping of its own (pooled tracks,
//  reused buffers), so these rows are where a regression of that shows first.
//
//  Everything runs on the main actor with no prewarm or timer in flight: the
//  counter is process-wide (see `AllocationMeter`).
//

#if os(macOS)
import CoreGraphics
import Foundation
@testable import WurstfingerKit

/// A view model wired like the keyboard's: a fresh preferences suite, a mock
/// text target, the German definition, and the touch engine configured for the
/// 390 pt portrait grid.
@MainActor
struct BenchRig {
    let viewModel: KeyboardViewModel
    let target: BenchTextTarget

    var engine: TouchEngine { viewModel.touchEngine }

    init(isLongPressEnabled: Bool = false, language: String = "de_DE") {
        let suite = "de.akator.wurstfinger.bench.rig"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        viewModel = KeyboardViewModel(userDefaults: defaults, shouldPersistSettings: false)
        target = BenchTextTarget()
        viewModel.bindTextInputTarget(target)
        viewModel.loadDefinition(for: language)
        viewModel.configureTouchEngine(containerWidth: 390, isLongPressEnabled: isLongPressEnabled)
    }

    /// The touch frame of a key in the engine's current grid.
    func frame(of keyId: String) -> CGRect {
        engine.hitMap.key(withId: keyId)!.frame
    }
}

/// The finger ids and clock the drivers below use. Touch times only matter for
/// the rollover hold, so a steady 8 ms tick (one 120 Hz frame) is enough.
private let finger: PointerID = 1

/// A tap: down and up on the same spot, as `TouchSurfaceView` delivers it.
@MainActor
private func tap(_ engine: TouchEngine, at point: CGPoint, clock: inout TimeInterval) {
    engine.began(finger, at: point, time: clock)
    clock += 0.05
    engine.ended(finger, at: point, time: clock)
    clock += 0.05
}

/// A flick across `frame`: eight single-sample move events, then the release.
/// `samples` is reused so the event array is not charged to the engine.
@MainActor
private func flick(
    _ engine: TouchEngine, across frame: CGRect, samples: inout [TouchSample], clock: inout TimeInterval
) {
    let start = CGPoint(x: frame.midX, y: frame.midY)
    engine.began(finger, at: start, time: clock)
    let stride = frame.width * 0.7 / 8
    for step in 1 ... 8 {
        clock += 0.008
        samples[0] = TouchSample(location: CGPoint(x: start.x + stride * CGFloat(step), y: start.y), time: clock)
        engine.moved(finger, samples: samples, predicted: [])
    }
    clock += 0.008
    engine.ended(finger, at: CGPoint(x: start.x + stride * 8, y: start.y), time: clock)
    clock += 0.05
}

/// Per-move cost of one drag sample on `engine`: time (ns) and allocations.
///
/// A drag is `movesPerRound` move events, each carrying `samplesPerMove`
/// coalesced samples spanning the same distance (so 1 and 4 samples describe
/// the same finger motion, sampled finer). Rounds are separate touches: the
/// engine classifies the whole path so far on every move, so one endless drag
/// would measure a path length no thumb produces. Landing and lifting are
/// outside the measured region; the sample array is reused so the array
/// itself is not charged.
@MainActor
private func driveDrag(
    _ engine: TouchEngine, frame: CGRect, samplesPerMove: Int, rounds: Int, movesPerRound: Int = 40
) -> (stats: [UInt64], allocations: Double, bytes: Double) {
    let start = CGPoint(x: frame.midX, y: frame.midY)
    let step = 0.8 / CGFloat(samplesPerMove)
    var samples = [TouchSample](repeating: TouchSample(location: start, time: 0), count: samplesPerMove)
    var timings = [UInt64]()
    timings.reserveCapacity(rounds * movesPerRound)
    var meter = AllocationMeter()
    var clock: TimeInterval = 1

    func round(measured: Bool) {
        engine.began(finger, at: start, time: clock)
        var travelled: CGFloat = 0
        for _ in 0 ..< movesPerRound {
            for index in 0 ..< samplesPerMove {
                travelled += step
                clock += 0.008 / Double(samplesPerMove)
                samples[index] = TouchSample(location: CGPoint(x: start.x + travelled, y: start.y), time: clock)
            }
            if measured {
                meter.start()
                let begin = nanos()
                engine.moved(finger, samples: samples, predicted: [])
                timings.append(nanos() &- begin)
                meter.stop()
            } else {
                engine.moved(finger, samples: samples, predicted: [])
            }
        }
        engine.ended(finger, at: CGPoint(x: start.x + travelled, y: start.y), time: clock)
        clock += 0.05
    }

    for _ in 0 ..< 5 { round(measured: false) }
    for _ in 0 ..< rounds { round(measured: true) }
    let count = Double(Swift.max(timings.count, 1))
    return (timings, Double(meter.allocations) / count, Double(meter.bytes) / count)
}

/// Lets cancelled long-press and trail-fade tasks run to completion so they
/// are not still queued when the next row is counted.
@MainActor
private func drainMainActor() async {
    try? await Task.sleep(for: .milliseconds(300))
}

@MainActor
func benchAllocations() async {
    print("8. Heap allocations per operation (process-wide malloc hook, main actor, nothing else in flight):")

    // Warm everything lazy (definitions, solver cache, signposter, locale
    // tables) and let the view model's own prewarm finish before counting.
    var rig = BenchRig()
    await KeyboardRegistry.prewarm(KeyboardRegistry.available.map(\.id))
    await drainMainActor()

    // The counter must see allocations at all: N arrays should count ~N.
    do {
        var keep = 0
        let calibration = countAllocations(iterations: 10_000, warmup: 100) {
            let array = [Int](repeating: keep, count: 16)
            keep &+= array.withUnsafeBufferPointer { $0.count }
        }
        let kept = keep
        sink.withLock { $0 &+= kept }
        reportAllocations("8-0. calibration: one [Int](repeating:count:) per call", calibration)
    }

    let frame = rig.frame(of: GridSlot.topLeft)
    let center = CGPoint(x: frame.midX, y: frame.midY)
    var clock: TimeInterval = 1
    var samples = [TouchSample](repeating: TouchSample(location: center, time: 0), count: 1)

    reportAllocations("8a. tap keystroke: engine -> view model -> pipeline -> target", countAllocations(iterations: 5000) {
        tap(rig.engine, at: center, clock: &clock)
    })
    reportAllocations("8b. flick keystroke: down, 8 one-sample moves, up", countAllocations(iterations: 5000) {
        flick(rig.engine, across: frame, samples: &samples, clock: &clock)
    })
    let inserted = rig.target.inserted
    sink.withLock { $0 &+= inserted }

    // 8c: the drag sample on the full path (engine + view model actions).
    for coalesced in [1, 4] {
        let drag = driveDrag(rig.engine, frame: frame, samplesPerMove: coalesced, rounds: 500)
        reportAllocations("8c. drag move, \(coalesced) sample(s)/move, engine + view model", allocations: drag.allocations, bytes: drag.bytes)
        Stats(name: "8c. drag move ns, \(coalesced) sample(s), engine+view model", samples: drag.stats).report()
    }

    // 8d: the same on an engine whose actions do nothing, to split the cost
    // of the engine itself from what the view model adds.
    do {
        let bare = TouchEngine()
        if let mode = rig.viewModel.activeModeFromDefinition,
           let (geometry, size) = rig.viewModel.gridGeometry(forContainerWidth: 390) {
            bare.configure(
                geometry: geometry, keys: mode.keys, tuning: rig.viewModel.gestureTuning,
                isLongPressEnabled: false, actions: TouchEngineActions()
            )
            bare.updateSize(size)
        }
        for coalesced in [1, 4] {
            let drag = driveDrag(bare, frame: frame, samplesPerMove: coalesced, rounds: 500)
            reportAllocations("8d. drag move, \(coalesced) sample(s)/move, engine only (no-op)", allocations: drag.allocations, bytes: drag.bytes)
            Stats(name: "8d. drag move ns, \(coalesced) sample(s), engine only", samples: drag.stats).report()
        }
    }

    // 8e: pure classification, per call, over the deterministic corpus.
    do {
        let corpus = makeCorpus(count: 2000)
        let tuning = GestureTuning.default
        var index = 0
        var accumulator = 0
        let result = countAllocations(iterations: corpus.count, warmup: 200) {
            accumulator &+= KeyGestureRecognizer.classify(
                positions: corpus[index % corpus.count].positions, aspectRatio: 1.2, tuning: tuning
            ).isReturn ? 1 : 0
            index += 1
        }
        let total = accumulator
        sink.withLock { $0 &+= total }
        reportAllocations("8e. KeyGestureRecognizer.classify(positions:..tuning:)", result)
    }

    // 8f / 8g: the two view-model calls the engine makes per gesture.
    do {
        var accumulator = 0
        let classification = GestureClassification(gesture: .swipeUp, isReturn: false)
        let preview = countAllocations(iterations: 20_000) {
            accumulator &+= rig.viewModel.previewLabel(for: classification, keyId: GridSlot.topCenter)?.utf8.count ?? 0
        }
        reportAllocations("8f. previewLabel(for: swipeUp, topCenter) [live preview]", preview)
        let dispatch = countAllocations(iterations: 20_000) {
            accumulator &+= rig.viewModel.handleGesture(.tap, keyId: GridSlot.topLeft, isReturn: false) ? 1 : 0
        }
        reportAllocations("8g. handleGesture(.tap, topLeft) -> pipeline -> target", dispatch)
        // Where a dispatch's allocations come from: the pipeline alone (no
        // resolution, no signposts), and the signpost interval pair alone.
        if let pipeline = rig.viewModel.pipeline {
            let context = ActionContext(action: .commitText("a"), binding: nil, mode: ModeNames.main)
            let pipelineOnly = countAllocations(iterations: 20_000) {
                pipeline.process(context)
            }
            reportAllocations("8g-i. ActionPipeline.process(commitText) only", pipelineOnly)
        }
        let signposts = countAllocations(iterations: 20_000) {
            InputSignposts.begin(InputSignposts.dispatch, InputSignposts.dispatchID)
            InputSignposts.end(InputSignposts.dispatch, InputSignposts.dispatchID)
        }
        reportAllocations("8g-ii. os_signpost begin/end pair (InputSignposts)", signposts)
        let total = accumulator + rig.target.inserted
        sink.withLock { $0 &+= total }
    }

    // 8j: the emoji mode's keystroke. The middleware that remembers the emoji
    // for the recent key must add nothing: an in-place move-to-front of nine
    // small strings. The second row alternates two keys so that every
    // keystroke really reorders the list.
    do {
        rig.viewModel.switchToMode(ModeNames.emoji)
        var accumulator = 0
        let steady = countAllocations(iterations: 20_000) {
            accumulator &+= rig.viewModel.handleGesture(.tap, keyId: GridSlot.topLeft, isReturn: false) ? 1 : 0
        }
        reportAllocations("8j. emoji mode: handleGesture(.tap) -> pipeline (+ recents) -> target", steady)
        var flip = false
        let rotating = countAllocations(iterations: 20_000) {
            flip.toggle()
            accumulator &+= rig.viewModel.handleGesture(
                flip ? .swipeUp : .swipeDown, keyId: GridSlot.topRight, isReturn: false
            ) ? 1 : 0
        }
        reportAllocations("8j-i. emoji mode: alternating flicks (the recents reorder every time)", rotating)
        rig.viewModel.switchToMode(ModeNames.main)
        let total = accumulator + rig.target.inserted
        sink.withLock { $0 &+= total }
    }

    // 8i: one frame of the gesture trail, as the overlay builds it (the
    // `Path` itself is CoreGraphics storage and always counts for one).
    do {
        let scratch = GestureTrailScratch()
        var trailSamples: [GestureTrailSample] = []
        for index in 0 ..< 40 {
            trailSamples.append(GestureTrailSample(
                point: CGPoint(x: 40 + CGFloat(index) * 5, y: 60 + sin(CGFloat(index) / 3) * 10),
                time: 1 + Double(index) * 0.008
            ))
        }
        let predicted = [CGPoint(x: 242, y: 61)]
        var accumulator = 0
        let frame = countAllocations(iterations: 2000) {
            let path = GestureTrailInk.shape(samples: trailSamples[...], predicted: predicted, headWidth: 12, scratch: scratch)
            accumulator &+= path.isEmpty ? 0 : 1
        }
        reportAllocations("8i. trail frame: GestureTrailInk.shape (40 samples, scratch)", frame)
        let total = accumulator
        sink.withLock { $0 &+= total }
    }

    // 8h: long presses on schedule one timer task per touch-down. The tasks
    // are cancelled on release but still sit in the executor until it runs
    // them, so they are drained between rows.
    await drainMainActor()
    rig = BenchRig(isLongPressEnabled: true)
    await KeyboardRegistry.prewarm(["de_DE"])
    await drainMainActor()
    let longPressFrame = rig.frame(of: GridSlot.topLeft)
    let longPressCenter = CGPoint(x: longPressFrame.midX, y: longPressFrame.midY)
    reportAllocations("8h. tap keystroke, long press enabled (timer per down)", countAllocations(iterations: 5000) {
        tap(rig.engine, at: longPressCenter, clock: &clock)
    })
    await drainMainActor()
}

#endif
