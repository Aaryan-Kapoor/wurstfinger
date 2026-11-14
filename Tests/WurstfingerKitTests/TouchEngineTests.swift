//
//  TouchEngineTests.swift
//  WurstfingerKitTests
//
//  The input engine against a synthetic grid: hit testing, per-finger tracks,
//  speculative guidance, press-ordered commits, cancellation, long press and
//  track pooling. (End-to-end typing through the engine is covered by the
//  scenario tests.)
//

import CoreGraphics
import Foundation
import Testing
@testable import WurstfingerKit

/// A 3×3 grid of letter keys `a`…`i` over a 300×240 surface, plus a space bar
/// spanning the bottom row: cells are 96 wide with 6 pt gaps, rows 54 high
/// with 8 pt gaps.
@MainActor
private final class EngineHarness {
    enum Event: Equatable {
        case touchDown(String)
        case gesture(String, GestureType, isReturn: Bool)
        case slide(String, SlidePhase)
        case longPress(String)
    }

    let engine: TouchEngine
    private(set) var events: [Event] = []
    var longPressHandled = true

    static let letters = ["a", "b", "c", "d", "e", "f", "g", "h", "i"]

    init(longPress: Bool = false) {
        engine = TouchEngine(trail: GestureTrailRecorder(defaults: InMemoryUserDefaults()), now: { 0 })
        var cells: [SolvedCell] = []
        var keys: [String: KeyDefinition] = [:]
        for (index, id) in Self.letters.enumerated() {
            cells.append(SolvedCell(keyId: id, row: index / 3, column: index % 3, rowSpan: 1, columnSpan: 1))
            keys[id] = Self.letterKey(id)
        }
        cells.append(SolvedCell(keyId: "space", row: 3, column: 0, rowSpan: 1, columnSpan: 3))
        keys["space"] = KeyDefinition(
            id: "space",
            bindings: [.tap: KeyBinding(label: " ", action: .space, category: nil, returnAction: nil, accessibilityLabel: nil)],
            swipeMode: .twoWayHorizontal, slideType: .moveCursor, style: .spacebar, tapCycleActions: nil
        )
        engine.configure(
            geometry: GridGeometry(
                cells: cells, columns: 3, rowHeight: 54,
                horizontalSpacing: 6, verticalSpacing: 8, cellAspectRatio: 96.0 / 54.0
            ),
            keys: keys,
            tuning: .default,
            isLongPressEnabled: longPress,
            actions: TouchEngineActions(
                touchDown: { [unowned self] key in events.append(.touchDown(key.id)) },
                gesture: { [unowned self] key, classification in
                    events.append(.gesture(key.id, classification.gesture, isReturn: classification.isReturn))
                },
                slide: { [unowned self] key, phase in events.append(.slide(key.id, phase)) },
                longPress: { [unowned self] key in
                    events.append(.longPress(key.id))
                    return longPressHandled
                },
                previewLabel: { key, classification in key.bindings[classification.gesture]?.label }
            )
        )
        engine.updateSize(CGSize(width: 300, height: 240))
    }

    static func letterKey(_ id: String) -> KeyDefinition {
        func binding(_ text: String) -> KeyBinding {
            KeyBinding(label: text, action: .commitText(text), category: nil, returnAction: nil, accessibilityLabel: nil)
        }
        return KeyDefinition(
            id: id,
            bindings: [.tap: binding(id), .swipeRight: binding(id + "→"), .swipeUp: binding(id + "↑")],
            swipeMode: .eightWay, slideType: .none, style: .primary, tapCycleActions: nil
        )
    }

    func center(of id: String) -> CGPoint {
        let frame = engine.hitMap.key(withId: id)!.frame
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Moves `pointer` from `start` by `delta` in `steps` samples.
    func drag(_ pointer: PointerID, from start: CGPoint, by delta: CGVector, steps: Int = 8, time: TimeInterval) {
        for step in 1 ... steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: start.x + delta.dx * fraction, y: start.y + delta.dy * fraction)
            engine.moved(pointer, samples: [TouchSample(location: point, time: time + Double(step) / 120)])
        }
    }

    func tap(_ id: String, pointer: PointerID = 1, at time: TimeInterval) {
        engine.began(pointer, at: center(of: id), time: time)
        engine.ended(pointer, at: center(of: id), time: time + 0.05)
    }

    var dispatched: [Event] {
        events.filter { if case .touchDown = $0 { false } else { true } }
    }
}

// MARK: - Hit map

@MainActor
struct KeyHitMapTests {
    @Test func everyPointOfTheGridBelongsToAKey() {
        let map = EngineHarness().engine.hitMap
        for x in stride(from: 0.0, through: 300, by: 3) {
            for y in stride(from: 0.0, through: 240, by: 3) {
                #expect(map.key(at: CGPoint(x: x, y: y)) != nil, "(\(x), \(y)) hit nothing")
            }
        }
    }

    @Test func pointsInAGapBelongToTheNearerKey() {
        let map = EngineHarness().engine.hitMap
        // Columns are 96 wide with a 6 pt gap: a's visible edge is x = 96, b's
        // starts at 102, and the boundary between their touch frames is 99.
        #expect(map.key(at: CGPoint(x: 98.9, y: 20))?.id == "a")
        #expect(map.key(at: CGPoint(x: 99.1, y: 20))?.id == "b")
        // Rows are 54 high with an 8 pt gap: the boundary is 58.
        #expect(map.key(at: CGPoint(x: 20, y: 57.9))?.id == "a")
        #expect(map.key(at: CGPoint(x: 20, y: 58.1))?.id == "d")
    }

    @Test func agreesWithTheLayoutFrames() {
        let map = EngineHarness().engine.hitMap
        for key in map.keys {
            let center = CGPoint(x: key.frame.midX, y: key.frame.midY)
            #expect(map.key(at: center)?.id == key.id)
        }
    }

    @Test func outsidePointsClampToTheEdgeKeys() {
        let map = EngineHarness().engine.hitMap
        #expect(map.key(at: CGPoint(x: -40, y: -40))?.id == "a")
        #expect(map.key(at: CGPoint(x: 400, y: 10))?.id == "c")
        #expect(map.key(at: CGPoint(x: 150, y: 500))?.id == "space")
    }

    @Test func spansCoverEveryCellTheyOccupy() {
        let map = EngineHarness().engine.hitMap
        for x in [10.0, 150, 290] {
            #expect(map.key(at: CGPoint(x: x, y: 220))?.id == "space")
        }
        let space = map.key(withId: "space")!
        #expect(abs(space.aspectRatio - 3 * 96.0 / 54.0) < 0.001)
    }

    @Test func anEmptyGridHitsNothing() {
        #expect(KeyHitMap.empty.key(at: .zero) == nil)
    }
}

// MARK: - Single finger

@MainActor
struct TouchEngineSingleFingerTests {
    @Test func aTapPressesTheKeyAndTypesOnRelease() {
        let harness = EngineHarness()
        let engine = harness.engine
        engine.began(1, at: harness.center(of: "e"), time: 0)
        #expect(engine.press.cell(for: "e").isPressed)
        #expect(harness.events == [.touchDown("e")])

        engine.ended(1, at: harness.center(of: "e"), time: 0.06)
        #expect(!engine.press.cell(for: "e").isPressed)
        #expect(harness.dispatched == [.gesture("e", .tap, isReturn: false)])
        #expect(engine.activePointerCount == 0)
    }

    @Test func aFlickBelongsToTheKeyItStartedOnEvenWhenItEndsOnANeighbour() {
        let harness = EngineHarness()
        let start = harness.center(of: "e")
        harness.engine.began(1, at: start, time: 0)
        harness.drag(1, from: start, by: CGVector(dx: 90, dy: 0), time: 0)
        harness.engine.ended(1, at: CGPoint(x: start.x + 90, y: start.y), time: 0.1)
        #expect(harness.dispatched == [.gesture("e", .swipeRight, isReturn: false)])
    }

    @Test func movingSetsTheCandidateAndTheGuideBeforeRelease() {
        let harness = EngineHarness()
        let engine = harness.engine
        let start = harness.center(of: "e")
        engine.began(1, at: start, time: 0)
        #expect(engine.press.guide?.keyId == "e")
        #expect(engine.press.guide?.candidate == nil)

        harness.drag(1, from: start, by: CGVector(dx: 60, dy: 0), time: 0)
        #expect(engine.press.cell(for: "e").candidate == .swipeRight)
        #expect(engine.press.guide?.candidate == .swipeRight)
        #expect(engine.press.guide?.label == "e→")
        #expect(harness.dispatched.isEmpty, "Speculation must not type anything")

        engine.ended(1, at: CGPoint(x: start.x + 60, y: start.y), time: 0.1)
        #expect(engine.press.guide == nil)
        #expect(engine.press.cell(for: "e").candidate == nil)
    }

    @Test func outAndBackIsPreviewedAsAReturnSwipe() {
        let harness = EngineHarness()
        let engine = harness.engine
        let start = harness.center(of: "e")
        engine.began(1, at: start, time: 0)
        harness.drag(1, from: start, by: CGVector(dx: 0, dy: -60), time: 0)
        #expect(engine.press.cell(for: "e").candidate == .swipeUp)
        #expect(engine.press.guide?.isReturn == false)
        harness.drag(1, from: CGPoint(x: start.x, y: start.y - 60), by: CGVector(dx: 0, dy: 58), time: 0.1)
        #expect(engine.press.guide?.candidate == .swipeUp)
        #expect(engine.press.guide?.isReturn == true)
        engine.ended(1, at: CGPoint(x: start.x, y: start.y - 2), time: 0.25)
        #expect(harness.dispatched == [.gesture("e", .swipeUp, isReturn: true)])
    }

    @Test func slideKeysReportPhasesAndTypeOnTap() {
        let harness = EngineHarness()
        let engine = harness.engine
        let start = harness.center(of: "space")
        engine.began(1, at: start, time: 0)
        #expect(engine.press.guide == nil, "Slide keys show no flick guide")
        harness.drag(1, from: start, by: CGVector(dx: 80, dy: 0), time: 0)
        engine.ended(1, at: CGPoint(x: start.x + 80, y: start.y), time: 0.2)

        let phases = harness.dispatched.compactMap { event -> SlidePhase? in
            if case let .slide(_, phase) = event { phase } else { nil }
        }
        #expect(phases.first == .began)
        #expect(phases.last == .ended)

        harness.tap("space", pointer: 2, at: 1)
        #expect(harness.dispatched.last == .slide("space", .tap))
    }

    @Test func aCancelledSlideReportsCancelledAndTypesNothing() {
        let harness = EngineHarness()
        let start = harness.center(of: "space")
        harness.engine.began(1, at: start, time: 0)
        harness.drag(1, from: start, by: CGVector(dx: 80, dy: 0), time: 0)
        harness.engine.cancelled(1)
        #expect(harness.dispatched.last == .slide("space", .cancelled))
        #expect(!harness.engine.press.cell(for: "space").isPressed)
    }

    @Test func aCancelledFlickTypesNothing() {
        let harness = EngineHarness()
        harness.engine.began(1, at: harness.center(of: "a"), time: 0)
        harness.engine.cancelled(1)
        harness.engine.ended(1, at: harness.center(of: "a"), time: 0.1)
        #expect(harness.dispatched.isEmpty)
        #expect(harness.engine.press.guide == nil)
    }

    @Test func aKeyRemovedByALayoutChangeAbandonsItsFinger() {
        let harness = EngineHarness()
        let engine = harness.engine
        engine.began(1, at: harness.center(of: "a"), time: 0)
        // The next mode has no key "a".
        engine.configure(
            geometry: GridGeometry(
                cells: [SolvedCell(keyId: "b", row: 0, column: 0, rowSpan: 1, columnSpan: 1)],
                columns: 1, rowHeight: 54, horizontalSpacing: 6, verticalSpacing: 8, cellAspectRatio: 1
            ),
            keys: ["b": EngineHarness.letterKey("b")],
            tuning: .default,
            isLongPressEnabled: false,
            actions: TouchEngineActions()
        )
        #expect(engine.activePointerCount == 0)
        #expect(!engine.press.cell(for: "a").isPressed)
    }

    @Test func touchesOutsideAnyKeyAreIgnored() {
        let engine = TouchEngine(now: { 0 })
        engine.began(1, at: .zero, time: 0)
        #expect(engine.activePointerCount == 0)
    }
}

// MARK: - Several fingers

@MainActor
struct TouchEngineRolloverTests {
    @Test func overlappingKeystrokesTypeInPressOrder() {
        let harness = EngineHarness()
        let engine = harness.engine
        engine.began(1, at: harness.center(of: "a"), time: 0)
        engine.began(2, at: harness.center(of: "b"), time: 0.05)
        // The later finger lifts first...
        engine.ended(2, at: harness.center(of: "b"), time: 0.09)
        #expect(harness.dispatched.isEmpty, "b must wait for the earlier a")
        #expect(engine.pendingCommitCount == 1)
        // ...and is typed right after the earlier one.
        engine.ended(1, at: harness.center(of: "a"), time: 0.12)
        #expect(harness.dispatched == [
            .gesture("a", .tap, isReturn: false),
            .gesture("b", .tap, isReturn: false),
        ])
        #expect(engine.pendingCommitCount == 0)
    }

    @Test func aRestingThumbDoesNotHoldTheOtherThumbBack() {
        let harness = EngineHarness()
        let engine = harness.engine
        engine.began(1, at: harness.center(of: "a"), time: 0)
        // Well past the rollover hold, the other thumb types freely.
        harness.tap("b", pointer: 2, at: TouchEngine.rolloverHold + 0.2)
        #expect(harness.dispatched == [.gesture("b", .tap, isReturn: false)])
    }

    @Test func aHeldBackKeystrokeIsReleasedWhenTheHoldExpires() {
        let harness = EngineHarness()
        let engine = harness.engine
        engine.began(1, at: harness.center(of: "a"), time: 0)
        harness.tap("b", pointer: 2, at: 0.02)
        #expect(harness.dispatched.isEmpty)
        engine.flushPendingCommits(at: TouchEngine.rolloverHold + 0.01)
        #expect(harness.dispatched == [.gesture("b", .tap, isReturn: false)])
    }

    @Test func aSlidingSpaceBarDoesNotHoldBackLetters() {
        let harness = EngineHarness()
        let engine = harness.engine
        let start = harness.center(of: "space")
        engine.began(1, at: start, time: 0)
        harness.drag(1, from: start, by: CGVector(dx: 60, dy: 0), time: 0)
        harness.tap("a", pointer: 2, at: 0.1)
        #expect(harness.dispatched.contains(.gesture("a", .tap, isReturn: false)))
    }

    @Test func aSpaceTapKeepsItsPlaceInThePressOrder() {
        let harness = EngineHarness()
        let engine = harness.engine
        engine.began(1, at: harness.center(of: "space"), time: 0)
        harness.tap("a", pointer: 2, at: 0.03)
        engine.ended(1, at: harness.center(of: "space"), time: 0.1)
        #expect(harness.dispatched == [
            .slide("space", .tap),
            .gesture("a", .tap, isReturn: false),
        ])
    }

    @Test func aKeyHeldByTwoFingersStaysPressedUntilBothLift() {
        let harness = EngineHarness()
        let engine = harness.engine
        engine.began(1, at: harness.center(of: "e"), time: 0)
        engine.began(2, at: harness.center(of: "e"), time: 0.01)
        engine.ended(1, at: harness.center(of: "e"), time: 0.05)
        #expect(engine.press.cell(for: "e").isPressed)
        engine.ended(2, at: harness.center(of: "e"), time: 0.06)
        #expect(!engine.press.cell(for: "e").isPressed)
    }

    @Test func cancellingAllTypesWhatAlreadyCompleted() {
        let harness = EngineHarness()
        let engine = harness.engine
        engine.began(1, at: harness.center(of: "a"), time: 0)
        harness.tap("b", pointer: 2, at: 0.01)
        engine.cancelAll()
        #expect(harness.dispatched == [.gesture("b", .tap, isReturn: false)])
        #expect(engine.activePointerCount == 0)
        #expect(engine.press.pressedKeyIds.isEmpty)
    }

    @Test func fingersBeyondTheLimitAreIgnored() {
        let harness = EngineHarness()
        let engine = harness.engine
        for pointer in 0 ..< TouchEngine.maxPointers + 3 {
            engine.began(pointer, at: harness.center(of: "e"), time: 0)
        }
        #expect(engine.activePointerCount == TouchEngine.maxPointers)
    }
}

// MARK: - Long press

@MainActor
struct TouchEngineLongPressTests {
    @Test func aHandledLongPressConsumesTheRelease() {
        let harness = EngineHarness(longPress: true)
        let engine = harness.engine
        engine.began(1, at: harness.center(of: "e"), time: 0)
        engine.fireLongPressTimer(for: 1)
        engine.ended(1, at: harness.center(of: "e"), time: 0.8)
        #expect(harness.dispatched == [.longPress("e")])
    }

    @Test func anUnhandledLongPressLeavesTheTapToTheRelease() {
        let harness = EngineHarness(longPress: true)
        harness.longPressHandled = false
        let engine = harness.engine
        engine.began(1, at: harness.center(of: "e"), time: 0)
        engine.fireLongPressTimer(for: 1)
        engine.ended(1, at: harness.center(of: "e"), time: 0.8)
        #expect(harness.dispatched == [.longPress("e"), .gesture("e", .tap, isReturn: false)])
    }

    @Test func movingAwayDisarmsTheLongPress() {
        let harness = EngineHarness(longPress: true)
        let engine = harness.engine
        let start = harness.center(of: "e")
        engine.began(1, at: start, time: 0)
        harness.drag(1, from: start, by: CGVector(dx: 50, dy: 0), time: 0)
        engine.fireLongPressTimer(for: 1)
        #expect(!harness.dispatched.contains(.longPress("e")))
    }

    @Test func disabledLongPressNeverFires() {
        let harness = EngineHarness(longPress: false)
        harness.engine.began(1, at: harness.center(of: "e"), time: 0)
        harness.engine.fireLongPressTimer(for: 1)
        #expect(!harness.dispatched.contains(.longPress("e")))
    }
}

// MARK: - Pooling

@MainActor
struct TouchEnginePoolingTests {
    /// Tracks are recycled: a thousand keystrokes leave no more tracks behind
    /// than the most fingers ever down at once.
    @Test func tracksAreReusedAcrossTouches() {
        let harness = EngineHarness()
        for index in 0 ..< 1000 {
            let id = EngineHarness.letters[index % 9]
            harness.tap(id, pointer: index, at: Double(index))
        }
        #expect(harness.engine.pooledTrackCount == 1)
        #expect(harness.dispatched.count == 1000)
    }
}
