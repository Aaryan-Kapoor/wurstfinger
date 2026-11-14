//
//  TouchEngineFuzzTests.swift
//  WurstfingerKitTests
//
//  Randomized multi-finger interleavings against the input engine, checked
//  against the invariants the engine promises rather than against expected
//  output: no crash, at most one commit per finger, press order unless the
//  bounded hold expired, pressed keys == fingers down, bounded pools, nothing
//  left pending once every finger has lifted.
//

import CoreGraphics
import Foundation
import os
import Testing
@testable import WurstfingerKit

/// Deterministic generator (SplitMix64), so a failing seed reproduces.
private struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    mutating func chance(_ probability: Double) -> Bool { unit() < probability }
    mutating func range(_ lower: Double, _ upper: Double) -> Double { lower + (upper - lower) * unit() }
}

/// The engine under a random stream of touches, with a model of what the
/// engine should believe alongside it.
@MainActor
private final class FuzzHarness {
    /// The engine's clock: the synthetic event time of the event in flight.
    /// A lock rather than a main-actor property so the engine's nonisolated
    /// `now` closure can read it.
    let clock = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)
    let engine: TouchEngine
    var rng: SplitMix64

    /// Whether long presses are enabled on this engine, and whether the next
    /// fired one is reported handled.
    let longPressEnabled: Bool
    var longPressHandled = true

    static let letters = ["a", "b", "c", "d", "e", "f", "g", "h", "i"]
    static let allKeyIds = letters + ["space"]
    /// The reduced layout `configure` switches to: it drops `c` and `g`, so
    /// fingers on those keys are abandoned.
    static let reducedKeyIds = ["a", "b", "d", "e", "f", "h", "i", "space"]
    private(set) var isReduced = false

    // MARK: Model

    struct Finger {
        let pointer: PointerID
        let keyId: String
        /// Position in press order, over all accepted touches.
        let order: Int
        let pressTime: TimeInterval
        var isSliding = false
        var longPressed = false
    }

    /// Fingers the engine accepted and that have not lifted or been cancelled.
    private(set) var down: [PointerID: Finger] = [:]
    /// Every accepted finger by press order, lifted ones included, so a commit
    /// that arrives after its finger lifted still finds it.
    private var fingers: [Int: Finger] = [:]
    private var pressCount = 0

    struct Commit {
        let order: Int
        let pressTime: TimeInterval
        let dispatchTime: TimeInterval
        let holdExempt: Bool
    }

    private(set) var commits: [Commit] = []
    private(set) var commitsPerOrder: [Int: Int] = [:]
    private(set) var acceptedTouches = 0

    /// Whether every commit can be attributed to one finger (one finger per
    /// key at a time). With fingers sharing a key the stamp on the key is the
    /// latest finger's, so attribution is off and only state is checked.
    let attributesCommits: Bool

    init(seed: UInt64, longPress: Bool, attributesCommits: Bool = true) {
        rng = SplitMix64(state: seed)
        longPressEnabled = longPress
        self.attributesCommits = attributesCommits
        let clock = self.clock
        engine = TouchEngine(
            trail: GestureTrailRecorder(defaults: InMemoryUserDefaults()),
            now: { clock.withLock { $0 } }
        )
        configure(reduced: false)
        engine.updateSize(CGSize(width: 300, height: 240))
    }

    // MARK: Layout

    /// The engine hands the key it was configured with back in every callback,
    /// so stamping each key with the press order of the finger on it (in the
    /// otherwise unused `tapCycleActions`) attributes a commit to its finger
    /// exactly, even when it arrives after the finger lifted and another one
    /// has landed on the same key.
    private var markers: [String: Int] = [:]

    private static func stamp(_ order: Int?) -> [KeyAction]? {
        order.map { [.commitText(String($0))] }
    }

    private static func order(of key: KeyDefinition) -> Int? {
        if case let .commitText(text)? = key.tapCycleActions?.first { return Int(text) }
        return nil
    }

    private static func letterKey(_ id: String, marker: Int?) -> KeyDefinition {
        func binding(_ text: String) -> KeyBinding {
            KeyBinding(label: text, action: .commitText(text), category: nil, returnAction: nil, accessibilityLabel: nil)
        }
        return KeyDefinition(
            id: id,
            bindings: [
                .tap: binding(id), .swipeRight: binding(id + "→"), .swipeUp: binding(id + "↑"),
                .swipeLeft: binding(id + "←"), .swipeDown: binding(id + "↓"), .longPress: binding("1"),
            ],
            swipeMode: .eightWay, slideType: .none, style: .primary, tapCycleActions: stamp(marker)
        )
    }

    func configure(reduced: Bool) {
        isReduced = reduced
        let ids = reduced ? Self.reducedKeyIds : Self.allKeyIds
        var cells: [SolvedCell] = []
        var keys: [String: KeyDefinition] = [:]
        for (index, id) in Self.letters.enumerated() where ids.contains(id) {
            cells.append(SolvedCell(keyId: id, row: index / 3, column: index % 3, rowSpan: 1, columnSpan: 1))
            keys[id] = Self.letterKey(id, marker: markers[id])
        }
        cells.append(SolvedCell(keyId: "space", row: 3, column: 0, rowSpan: 1, columnSpan: 3))
        keys["space"] = KeyDefinition(
            id: "space",
            bindings: [.tap: KeyBinding(label: " ", action: .space, category: nil, returnAction: nil, accessibilityLabel: nil)],
            swipeMode: .twoWayHorizontal, slideType: .moveCursor, style: .spacebar, tapCycleActions: Self.stamp(markers["space"])
        )
        engine.configure(
            geometry: GridGeometry(
                cells: cells, columns: 3, rowHeight: 54,
                horizontalSpacing: 6, verticalSpacing: 8, cellAspectRatio: 96.0 / 54.0
            ),
            keys: keys,
            tuning: .default,
            isLongPressEnabled: longPressEnabled,
            actions: TouchEngineActions(
                touchDown: { _ in },
                gesture: { [unowned self] key, _ in recordCommit(on: key) },
                slide: { [unowned self] key, phase in
                    switch phase {
                    case .tap, .swipeUp: recordCommit(on: key)
                    case .began: markSliding(key)
                    case .changed, .ended, .cancelled: break
                    }
                },
                longPress: { [unowned self] key in
                    if longPressHandled {
                        markLongPressed(key)
                        recordCommit(on: key)
                    }
                    return longPressHandled
                },
                previewLabel: { key, classification in key.bindings[classification.gesture]?.label }
            )
        )
        // The engine abandons fingers whose key disappeared; the model follows.
        if reduced {
            for (pointer, finger) in down where !ids.contains(finger.keyId) {
                down[pointer] = nil
            }
        }
    }

    private var keyIds: [String] { isReduced ? Self.reducedKeyIds : Self.allKeyIds }

    private func center(of id: String) -> CGPoint {
        let frame = engine.hitMap.key(withId: id)!.frame
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    // MARK: Model updates from the engine's callbacks

    private func recordCommit(on key: KeyDefinition) {
        guard let order = Self.order(of: key), let finger = fingers[order] else {
            if attributesCommits { Issue.record("Commit on \(key.id) with no finger attributed to it") }
            return
        }
        let now = clock.withLock { $0 }
        commits.append(Commit(
            order: finger.order, pressTime: finger.pressTime, dispatchTime: now,
            holdExempt: finger.isSliding || finger.longPressed
        ))
        commitsPerOrder[finger.order, default: 0] += 1
    }

    private func markSliding(_ key: KeyDefinition) {
        guard let order = Self.order(of: key) else { return }
        fingers[order]?.isSliding = true
        if let pointer = fingers[order]?.pointer { down[pointer]?.isSliding = true }
    }

    private func markLongPressed(_ key: KeyDefinition) {
        guard let order = Self.order(of: key) else { return }
        fingers[order]?.longPressed = true
        if let pointer = fingers[order]?.pointer { down[pointer]?.longPressed = true }
    }

    // MARK: Random events

    var time: TimeInterval = 0

    private func advance() {
        time += rng.range(0.001, 0.04)
        let now = time
        clock.withLock { $0 = now }
    }

    /// One random event. Touch-downs target a free key, so every commit can be
    /// attributed to one finger; a separate run relaxes this (see
    /// `step(allowSharedKeys:)`).
    func step(allowSharedKeys: Bool) {
        advance()
        let roll = rng.unit()
        let pointers = Array(down.keys).sorted()
        switch roll {
        case ..<0.30:
            began(allowSharedKeys: allowSharedKeys)
        case ..<0.65 where !pointers.isEmpty:
            moved(pointers[rng.below(pointers.count)])
        case ..<0.86 where !pointers.isEmpty:
            ended(pointers[rng.below(pointers.count)])
        case ..<0.91 where !pointers.isEmpty:
            cancelled(pointers[rng.below(pointers.count)])
        case ..<0.94:
            configure(reduced: !isReduced)
        case ..<0.96 where longPressEnabled && !pointers.isEmpty:
            longPressHandled = rng.chance(0.7)
            engine.fireLongPressTimer(for: pointers[rng.below(pointers.count)])
        case ..<0.98:
            engine.flushPendingCommits(at: time)
        case ..<0.985:
            cancelAll()
        default:
            began(allowSharedKeys: allowSharedKeys)
        }
    }

    private func began(allowSharedKeys: Bool) {
        // Mostly fresh pointers; sometimes a pointer id the engine already
        // tracks, which it must treat as a stale touch.
        let pointer: PointerID = rng.chance(0.05) && !down.isEmpty
            ? Array(down.keys)[rng.below(down.count)]
            : Int(rng.next() % 1_000_000) + 1
        let occupied = Set(down.values.map(\.keyId))
        let free = allowSharedKeys ? keyIds : keyIds.filter { !occupied.contains($0) }
        let location: CGPoint
        let keyId: String?
        if free.isEmpty || rng.chance(0.05) {
            // Off-grid points clamp to an edge key; (-1000, -1000) lands on
            // the top-left key, so keep the model's key in sync via the map.
            location = CGPoint(x: rng.range(-50, 350), y: rng.range(-50, 290))
            keyId = engine.hitMap.key(at: location)?.id
            if let keyId, !allowSharedKeys, occupied.contains(keyId) { return }
        } else {
            let id = free[rng.below(free.count)]
            let c = center(of: id)
            location = CGPoint(x: c.x + rng.range(-20, 20), y: c.y + rng.range(-15, 15))
            keyId = id
        }
        guard let keyId else { return }
        // Stamp the key with this touch's order before the engine reads it.
        let order = pressCount + 1
        markers[keyId] = order
        configure(reduced: isReduced)
        let before = engine.activePointerCount
        let hadStale = down[pointer] != nil
        engine.began(pointer, at: location, time: time)
        if hadStale { down[pointer] = nil }
        let accepted = engine.activePointerCount == before + 1 || (hadStale && engine.activePointerCount == before)
        guard accepted else { return }
        acceptedTouches += 1
        pressCount = order
        let finger = Finger(pointer: pointer, keyId: keyId, order: order, pressTime: time)
        down[pointer] = finger
        fingers[order] = finger
    }

    private func moved(_ pointer: PointerID) {
        guard let finger = down[pointer] else { return }
        let origin = center(of: finger.keyId)
        var samples: [TouchSample] = []
        let count = 1 + rng.below(4)
        let dx = rng.range(-120, 120), dy = rng.range(-120, 120)
        for index in 1 ... count {
            let fraction = CGFloat(index) / CGFloat(count)
            samples.append(TouchSample(
                location: CGPoint(x: origin.x + dx * fraction, y: origin.y + dy * fraction),
                time: time
            ))
        }
        engine.moved(pointer, samples: samples, predicted: rng.chance(0.3) ? [samples.last!.location] : [])
    }

    private func ended(_ pointer: PointerID) {
        guard let finger = down[pointer] else { return }
        let origin = center(of: finger.keyId)
        let location = CGPoint(x: origin.x + rng.range(-100, 100), y: origin.y + rng.range(-100, 100))
        down[pointer] = nil
        engine.ended(pointer, at: location, time: time)
    }

    /// `cancelAll` flushes every held-back commit regardless of the hold, so
    /// the commits it dispatches are recorded at an infinite time: they are
    /// exempt from the press-order check by the engine's own rule.
    func cancelAll() {
        clock.withLock { $0 = .infinity }
        engine.cancelAll()
        down.removeAll()
        let now = time
        clock.withLock { $0 = now }
    }

    private func cancelled(_ pointer: PointerID) {
        down[pointer] = nil
        engine.cancelled(pointer)
    }

    // MARK: Invariants

    func checkInvariants(seed: UInt64, step: Int) {
        let context = "seed \(seed), step \(step)"
        #expect(engine.activePointerCount == down.count, "fingers down: \(context)")
        #expect(engine.activePointerCount <= TouchEngine.maxPointers, "\(context)")
        #expect(engine.pooledTrackCount <= TouchEngine.maxPointers, "\(context)")
        #expect(engine.pendingCommitCount <= TouchEngine.maxPointers, "\(context)")
        let expectedPressed = Set(down.values.map(\.keyId))
        #expect(engine.press.pressedKeyIds == expectedPressed, "pressed keys: \(context)")
        if down.isEmpty {
            #expect(engine.pendingCommitCount == 0, "pending after all lifted: \(context)")
            #expect(engine.press.guide == nil, "guide after all lifted: \(context)")
        }
        if let guide = engine.press.guide {
            #expect(expectedPressed.contains(guide.keyId), "guide on an unpressed key: \(context)")
        }
    }

    func checkFinalInvariants(seed: UInt64) {
        for (order, count) in commitsPerOrder {
            #expect(count <= 1, "finger \(order) committed \(count) times (seed \(seed))")
        }
        #expect(commits.count <= acceptedTouches, "seed \(seed)")
        // Press order, unless the earlier finger had given up its place: its
        // hold expired, it was sliding, or it had already typed a long press.
        for (later, commit) in commits.enumerated() {
            for earlier in commits[..<later] where earlier.order > commit.order {
                // `earlier` was dispatched before `commit` although pressed
                // after it: `commit`'s finger must have been exempt by then.
                let elapsed = earlier.dispatchTime - commit.pressTime
                #expect(
                    elapsed >= TouchEngine.rolloverHold - 1e-9 || commit.holdExempt,
                    "finger \(earlier.order) typed before finger \(commit.order) after only \(elapsed)s (seed \(seed))"
                )
            }
        }
    }
}

/// Sized to stay around a second of main-actor time: every case runs
/// synchronously on the main actor, and a long run starves the suites that
/// await main-actor tasks with a deadline (the settings-signal debounce
/// tests). The three ordering holes this suite found were all found within
/// the first dozen seeds; raise the counts locally when changing the engine.
@MainActor
struct TouchEngineFuzzTests {
    private func run(seed: UInt64, steps: Int, longPress: Bool, allowSharedKeys: Bool) {
        let harness = FuzzHarness(seed: seed, longPress: longPress, attributesCommits: !allowSharedKeys)
        for step in 0 ..< steps {
            harness.step(allowSharedKeys: allowSharedKeys)
            harness.checkInvariants(seed: seed, step: step)
        }
        harness.cancelAll()
        harness.checkInvariants(seed: seed, step: steps)
        if !allowSharedKeys {
            harness.checkFinalInvariants(seed: seed)
        }
    }

    @Test(arguments: 0 ..< 30)
    func randomInterleavingsKeepTheInvariants(seed: Int) {
        run(seed: UInt64(seed) &* 0x9E37_79B9 &+ 1, steps: 200, longPress: false, allowSharedKeys: false)
    }

    @Test(arguments: 0 ..< 25)
    func randomInterleavingsWithLongPressKeepTheInvariants(seed: Int) {
        run(seed: UInt64(seed) &* 0x51_7C_C1_B7 &+ 3, steps: 200, longPress: true, allowSharedKeys: false)
    }

    /// Several fingers on one key at once: commits can no longer be attributed
    /// to a finger, so only the state invariants are checked.
    @Test(arguments: 0 ..< 15)
    func fingersSharingKeysKeepTheStateInvariants(seed: Int) {
        run(seed: UInt64(seed) &* 0x2545_F491 &+ 7, steps: 200, longPress: true, allowSharedKeys: true)
    }
}
