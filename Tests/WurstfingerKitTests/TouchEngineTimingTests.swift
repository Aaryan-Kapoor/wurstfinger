//
//  TouchEngineTimingTests.swift
//  WurstfingerKitTests
//
//  Every deadline of the input path — the long press, the rollover hold, the
//  trail's fade — driven by a hand-turned clock, so the suite can prove *when*
//  something fires without ever waiting for it (and without a busy machine
//  being able to fail the test).
//

import CoreGraphics
import Foundation
import Testing
@testable import WurstfingerKit

/// A 2×1 grid of flick keys over a 200×60 surface on a manual clock.
@MainActor
private final class TimedHarness {
    enum Event: Equatable {
        case gesture(String, GestureType)
        case longPress(String)
        case longPressPhase(String, LongPressFeelPhase)
    }

    let timers = ManualTimerSource()
    let engine: TouchEngine
    private(set) var events: [Event] = []
    var longPressHandled = true
    /// Keys whose long press finds nothing to type: the finger stays undecided.
    var unboundLongPress: Set<String> = []

    init(longPressDuration: TimeInterval = KeyboardConstants.LongPress.duration) {
        engine = TouchEngine(trail: GestureTrailRecorder(defaults: InMemoryUserDefaults()), timers: timers)
        var tuning = GestureTuning.default
        tuning.longPressDuration = longPressDuration
        engine.configure(
            geometry: GridGeometry(
                cells: [
                    SolvedCell(keyId: "a", row: 0, column: 0, rowSpan: 1, columnSpan: 1),
                    SolvedCell(keyId: "b", row: 0, column: 1, rowSpan: 1, columnSpan: 1),
                ],
                columns: 2, rowHeight: 60, horizontalSpacing: 0, verticalSpacing: 0, cellAspectRatio: 100.0 / 60
            ),
            keys: ["a": Self.key("a"), "b": Self.key("b")],
            tuning: tuning,
            isLongPressEnabled: true,
            actions: TouchEngineActions(
                gesture: { [unowned self] key, classification in events.append(.gesture(key.id, classification.gesture)) },
                longPress: { [unowned self] key in
                    events.append(.longPress(key.id))
                    return longPressHandled && !unboundLongPress.contains(key.id)
                },
                longPressPhase: { [unowned self] key, phase in events.append(.longPressPhase(key.id, phase)) }
            )
        )
        engine.updateSize(CGSize(width: 200, height: 60))
    }

    private static func key(_ id: String) -> KeyDefinition {
        let binding = KeyBinding(label: id, action: .commitText(id), category: nil, returnAction: nil, accessibilityLabel: nil)
        return KeyDefinition(
            id: id, bindings: [.tap: binding, .longPress: binding],
            swipeMode: .eightWay, slideType: .none, style: .primary, tapCycleActions: nil
        )
    }

    func center(of id: String) -> CGPoint {
        let frame = engine.hitMap.key(withId: id)!.frame
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Touch-down at the clock's current time.
    func press(_ id: String, pointer: PointerID) {
        engine.began(pointer, at: center(of: id), time: timers.now)
    }

    func lift(_ id: String, pointer: PointerID) {
        engine.ended(pointer, at: center(of: id), time: timers.now)
    }

    var commits: [Event] {
        events.filter { if case .longPressPhase = $0 { false } else { true } }
    }
}

@MainActor
struct TouchEngineTimingTests {
    @Test func aLongPressFiresExactlyAtItsDeadline() {
        let harness = TimedHarness()
        harness.press("a", pointer: 1)
        harness.timers.advance(to: KeyboardConstants.LongPress.duration - 0.001)
        #expect(harness.commits.isEmpty)
        harness.timers.advance(to: KeyboardConstants.LongPress.duration)
        #expect(harness.commits == [.longPress("a")])
        #expect(harness.events.contains(.longPressPhase("a", .fired)))
        // The release of a consumed finger types nothing.
        harness.lift("a", pointer: 1)
        #expect(harness.commits == [.longPress("a")])
    }

    @Test func movingBeforeTheDeadlineDisarmsTheLongPress() {
        let harness = TimedHarness()
        let start = harness.center(of: "a")
        harness.press("a", pointer: 1)
        harness.timers.advance(by: 0.3)
        harness.engine.moved(1, samples: [TouchSample(location: CGPoint(x: start.x + 40, y: start.y), time: 0.3)])
        #expect(harness.events.contains(.longPressPhase("a", .cancelled)))
        harness.timers.advance(by: 2)
        #expect(harness.commits.isEmpty)
    }

    @Test func liftingBeforeTheDeadlineLeavesNoTimerBehindToFire() {
        let harness = TimedHarness()
        harness.press("a", pointer: 1)
        harness.timers.advance(by: 0.1)
        harness.lift("a", pointer: 1)
        #expect(harness.commits == [.gesture("a", .tap)])
        // The lazily kept timer wakes, finds nothing due, and goes quiet.
        harness.timers.advance(by: 2)
        #expect(harness.commits == [.gesture("a", .tap)])
        #expect(harness.timers.pendingCount == 0)
        #expect(harness.engine.armedTimerDeadline == nil)
    }

    @Test func aHeldBackKeystrokeGoesOutWhenTheHoldExpiresOnItsOwn() {
        let harness = TimedHarness()
        harness.press("a", pointer: 1)
        harness.timers.advance(by: 0.02)
        harness.press("b", pointer: 2)
        harness.timers.advance(by: 0.03)
        harness.lift("b", pointer: 2)
        #expect(harness.commits.isEmpty, "b waits for the earlier, undecided a")
        #expect(harness.engine.armedTimerDeadline == TouchEngine.rolloverHold)
        harness.timers.advance(to: TouchEngine.rolloverHold - 0.001)
        #expect(harness.commits.isEmpty)
        harness.timers.advance(to: TouchEngine.rolloverHold)
        #expect(harness.commits == [.gesture("b", .tap)])
        #expect(harness.engine.pendingCommitCount == 0)
    }

    /// At 0.1 s, `(0.1 + 0.25) - 0.1` rounds to 0.2499…: a hold measured by
    /// subtraction would still stand at the deadline it was armed for, and the
    /// timer would re-arm for that same instant forever. The hold ends at its
    /// deadline, exactly.
    @Test func aHoldEndsAtItsDeadlineWhateverThePressTimeRoundsTo() {
        let harness = TimedHarness()
        harness.timers.advance(to: 0.1)
        harness.press("a", pointer: 1)
        harness.timers.advance(to: 0.2)
        harness.press("b", pointer: 2)
        harness.timers.advance(to: 0.3)
        harness.lift("b", pointer: 2)
        #expect(harness.commits.isEmpty)
        harness.timers.advance(to: 0.1 + TouchEngine.rolloverHold)
        #expect(harness.commits == [.gesture("b", .tap)])
        #expect(harness.engine.armedTimerDeadline != 0.1 + TouchEngine.rolloverHold)
    }

    @Test func aLongPressDueInsideAnEarlierFingersHoldWaitsForTheHold() {
        // A long press shorter than the hold, so the deferral is reachable;
        // a's own hold finds nothing to type, so a stays undecided and keeps
        // its place in the press order for the whole hold.
        let harness = TimedHarness(longPressDuration: 0.1)
        harness.unboundLongPress = ["a"]
        harness.press("a", pointer: 1)
        harness.timers.advance(by: 0.05)
        harness.press("b", pointer: 2)
        harness.timers.advance(to: 0.2)
        #expect(harness.commits == [.longPress("a")], "b's hold (due at 0.15) waits behind the undecided a")
        harness.timers.advance(to: TouchEngine.rolloverHold)
        #expect(harness.commits == [.longPress("a"), .longPress("b")])
    }

    /// The counterpart: a finger whose long press went out is decided, so it
    /// holds nothing back and a later finger's hold fires on time.
    @Test func aLongPressedFingerHoldsNothingBack() {
        let harness = TimedHarness(longPressDuration: 0.1)
        harness.press("a", pointer: 1)
        harness.timers.advance(by: 0.05)
        harness.press("b", pointer: 2)
        // b's own deadline (0.05 + 0.1), not a's hold (0.25).
        harness.timers.advance(to: 0.16)
        #expect(harness.commits == [.longPress("a"), .longPress("b")])
    }

    @Test func oneTimerServesEveryFinger() {
        let harness = TimedHarness()
        harness.press("a", pointer: 1)
        harness.timers.advance(by: 0.1)
        harness.press("b", pointer: 2)
        #expect(harness.timers.pendingCount == 1, "two armed long presses, one timer")
        #expect(harness.engine.armedTimerDeadline == KeyboardConstants.LongPress.duration)
        harness.timers.advance(to: KeyboardConstants.LongPress.duration)
        #expect(harness.commits == [.longPress("a")])
        #expect(harness.timers.pendingCount == 1, "re-armed for b")
        harness.timers.advance(to: KeyboardConstants.LongPress.duration + 0.1)
        #expect(harness.commits == [.longPress("a"), .longPress("b")])
    }

    @Test func cancelAllDropsTheTimer() {
        let harness = TimedHarness()
        harness.press("a", pointer: 1)
        harness.engine.cancelAll()
        #expect(harness.timers.pendingCount == 0)
        harness.timers.advance(by: 2)
        #expect(harness.commits.isEmpty)
    }

    @Test func theTrailFadesOutOnTheClock() {
        let timers = ManualTimerSource()
        let defaults = InMemoryUserDefaults()
        defaults.set(true, forKey: SettingsKey.gestureTrailEnabled.rawValue)
        let recorder = GestureTrailRecorder(defaults: defaults, now: { 0 }, timers: timers)
        let token = GestureTrailToken()
        recorder.begin(at: .zero, from: token)
        recorder.finish(from: token)
        #expect(recorder.isVisible)
        timers.advance(by: KeyboardConstants.GestureTrail.fadeOutDuration - 0.001)
        #expect(recorder.isVisible)
        timers.advance(by: 0.001)
        #expect(!recorder.isVisible)
        #expect(recorder.trail.isEmpty)
    }

    @Test func aNewTouchCancelsThePendingFade() {
        let timers = ManualTimerSource()
        let defaults = InMemoryUserDefaults()
        defaults.set(true, forKey: SettingsKey.gestureTrailEnabled.rawValue)
        let recorder = GestureTrailRecorder(defaults: defaults, now: { 0 }, timers: timers)
        let first = GestureTrailToken(), second = GestureTrailToken()
        recorder.begin(at: .zero, from: first)
        recorder.finish(from: first)
        timers.advance(by: 0.1)
        recorder.begin(at: CGPoint(x: 10, y: 10), from: second)
        timers.advance(by: 1)
        #expect(recorder.isVisible, "the second touch owns the trail; the first fade must not clear it")
        #expect(timers.pendingCount == 0)
    }
}

@MainActor
struct ManualTimerSourceTests {
    @Test func firesInDeadlineOrderWithTheClockAtEachDeadline() {
        let timers = ManualTimerSource()
        var fired: [(String, TimeInterval)] = []
        _ = timers.schedule(after: 2) { fired.append(("late", timers.now)) }
        _ = timers.schedule(after: 1) { fired.append(("early", timers.now)) }
        timers.advance(by: 5)
        #expect(fired.map(\.0) == ["early", "late"])
        #expect(fired.map(\.1) == [1, 2])
        #expect(timers.now == 5)
    }

    @Test func aCancelledTimerNeverFiresAndATimerArmedWhileFiringIsHonoured() {
        let timers = ManualTimerSource()
        var fired: [String] = []
        let handle = timers.schedule(after: 1) { fired.append("cancelled") }
        _ = timers.schedule(after: 1) {
            fired.append("first")
            _ = timers.schedule(after: 0.5) { fired.append("nested") }
        }
        handle.cancel()
        #expect(!handle.isActive)
        timers.advance(by: 1.2)
        #expect(fired == ["first"])
        timers.advance(by: 0.3)
        #expect(fired == ["first", "nested"])
        #expect(timers.pendingCount == 0)
    }
}
