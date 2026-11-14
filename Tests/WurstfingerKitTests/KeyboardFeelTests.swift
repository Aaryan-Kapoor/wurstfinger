//
//  KeyboardFeelTests.swift
//  WurstfingerKitTests
//
//  The feel layer's decisions: which cue a target change earns, how often
//  detents and slide ticks may fire, the long-press swell and ring, the
//  board's bookkeeping, and — through the real engine and view model — that
//  the moments are reported where and when they happen.
//

import CoreGraphics
import Foundation
import Testing
@testable import WurstfingerKit
@testable import WurstfingerScenarioKit

/// A clock the tests advance by hand.
@MainActor
private final class TestClock {
    var now: TimeInterval = 100
}

@MainActor
private func makeFeel() -> (KeyboardFeel, RecordingHapticRenderer, TestClock) {
    let settings = HapticSettings(defaults: InMemoryUserDefaults(), shouldPersist: false)
    settings.dragIntensity = HapticIntensityLevel.light.storedIntensity
    let renderer = RecordingHapticRenderer()
    let player = HapticFeedbackPlayer(settings: settings, detailed: renderer, pulses: RecordingPulseRenderer())
    player.prepareIfNeeded()
    let clock = TestClock()
    return (KeyboardFeel(haptics: player, now: { clock.now }), renderer, clock)
}

private func candidate(_ gesture: GestureType?, isReturn: Bool = false, isLongSwipe: Bool = false) -> GestureCandidate {
    GestureCandidate(gesture: gesture, isReturn: isReturn, isLongSwipe: isLongSwipe)
}

// MARK: - Target changes

@MainActor
struct FeelCandidateTests {
    @Test func aNewDirectionIsADetent() {
        #expect(KeyboardFeel.cue(from: .tap, to: candidate(.swipeUp)) == .directionDetent)
        #expect(KeyboardFeel.cue(from: candidate(.swipeUp), to: candidate(.swipeUpRight)) == .directionDetent)
    }

    @Test func comingBackToTheCentreIsASofterDetent() {
        #expect(KeyboardFeel.cue(from: candidate(.swipeLeft), to: .tap) == .centerDetent)
        #expect(KeyboardFeel.cue(from: .tap, to: .tap) == nil)
    }

    @Test func turningBackIsTheReturnDetent() {
        #expect(KeyboardFeel.cue(from: candidate(.swipeUp), to: candidate(.swipeUp, isReturn: true)) == .returnDetent)
        // Going out again is just a direction.
        #expect(KeyboardFeel.cue(from: candidate(.swipeUp, isReturn: true), to: candidate(.swipeUp)) == .directionDetent)
    }

    @Test func closingTheLoopBeatsADetent() {
        #expect(KeyboardFeel.cue(from: candidate(.swipeRight), to: candidate(.circularClockwise)) == .circleClosed)
        #expect(KeyboardFeel.cue(from: candidate(.circularClockwise), to: candidate(.circularCounterclockwise)) == .directionDetent)
    }

    @Test func theLongSwipeThresholdBeatsEverything() {
        #expect(KeyboardFeel.cue(from: candidate(.swipeRight), to: candidate(.swipeRight, isLongSwipe: true)) == .longSwipeArmed)
        #expect(KeyboardFeel.cue(from: candidate(.swipeRight, isLongSwipe: true), to: candidate(.swipeUpRight)) == .longSwipeDisarmed)
    }

    @Test func detentsAreSpacedSoABorderDoesNotRattle() {
        let (feel, renderer, clock) = makeFeel()
        feel.candidateChanged(from: .tap, to: candidate(.swipeUp))
        clock.now += 0.01
        feel.candidateChanged(from: candidate(.swipeUp), to: candidate(.swipeUpRight))
        clock.now += 0.01
        feel.candidateChanged(from: candidate(.swipeUpRight), to: candidate(.swipeUp))
        #expect(renderer.playedCues == [.directionDetent])
        clock.now += KeyboardFeel.detentSpacing
        feel.candidateChanged(from: candidate(.swipeUp), to: candidate(.swipeUpRight))
        #expect(renderer.playedCues == [.directionDetent, .directionDetent])
    }

    @Test func thresholdsAreNeverSwallowedBySpacing() {
        let (feel, renderer, _) = makeFeel()
        feel.candidateChanged(from: .tap, to: candidate(.swipeRight))
        feel.candidateChanged(from: candidate(.swipeRight), to: candidate(.swipeRight, isLongSwipe: true))
        #expect(renderer.playedCues == [.directionDetent, .longSwipeArmed])
    }

    @Test func aReleaseClicksAndPops() {
        let (feel, renderer, _) = makeFeel()
        let pop = FeelBoard.Pop(text: "p", keyFrame: CGRect(x: 0, y: 0, width: 50, height: 50), gesture: .swipeUp)
        feel.released(.swipe, pop: pop)
        #expect(renderer.playedCues.isEmpty, "nothing goes out before the keystroke is handed on")
        #expect(feel.board.pops.isEmpty)
        feel.flushRelease()
        feel.released(.tap, pop: nil)
        feel.flushRelease()
        feel.released(.longSwipe, clicks: false, pop: nil)
        feel.flushRelease()
        feel.flushRelease()
        #expect(renderer.playedCues == [.commit(.swipe), .commit(.tap)])
        #expect(feel.board.pops.map(\.text) == ["p"])
    }
}

// MARK: - Long press

@MainActor
struct FeelLongPressTests {
    private let frame = CGRect(x: 10, y: 10, width: 60, height: 50)

    @Test func armingSchedulesTheSwellToEndAtTheFireAndShowsTheRing() throws {
        let (feel, renderer, _) = makeFeel()
        feel.longPressArmed(keyId: "e", keyFrame: frame, delay: 0.7)
        let played = try #require(renderer.played.last)
        #expect(played.cue == .longPressRamp)
        #expect(abs(played.delay - (0.7 - LongPressFeel.rampDuration)) < 0.0001)
        #expect(feel.board.ring?.keyId == "e")
        #expect(feel.board.ring?.duration == 0.7)
    }

    @Test func cancellingStopsTheSwellAndHidesTheRing() {
        let (feel, renderer, _) = makeFeel()
        feel.longPressArmed(keyId: "e", keyFrame: frame, delay: 0.7)
        feel.longPressCancelled(keyId: "e")
        #expect(renderer.stopped == [.longPressRamp])
        #expect(feel.board.ring == nil)
    }

    @Test func anotherKeysCancelLeavesTheRingAlone() {
        let (feel, renderer, _) = makeFeel()
        feel.longPressArmed(keyId: "e", keyFrame: frame, delay: 0.7)
        feel.longPressCancelled(keyId: "a")
        #expect(renderer.stopped.isEmpty)
        #expect(feel.board.ring?.keyId == "e")
    }

    @Test func firingResolvesTheSwellWithAClickAndAPop() {
        let (feel, renderer, _) = makeFeel()
        feel.longPressArmed(keyId: "e", keyFrame: frame, delay: 0.7)
        feel.longPressFired(keyId: "e", pop: FeelBoard.Pop(text: "5", keyFrame: frame, gesture: .tap))
        #expect(renderer.stopped == [.longPressRamp])
        #expect(renderer.playedCues.last == .commit(.longPress))
        #expect(feel.board.ring?.hasFired == true)
        #expect(feel.board.pops.map(\.text) == ["5"])
    }

    @Test func aSecondFingersArmReplacesTheFirst() {
        let (feel, renderer, _) = makeFeel()
        feel.longPressArmed(keyId: "e", keyFrame: frame, delay: 0.7)
        feel.longPressArmed(keyId: "a", keyFrame: frame, delay: 0.7)
        #expect(renderer.stopped == [.longPressRamp])
        #expect(feel.board.ring?.keyId == "a")
    }
}

// MARK: - Slides

@MainActor
struct FeelSlideTests {
    private let frame = CGRect(x: 0, y: 180, width: 200, height: 50)

    @Test func everyStepMovesTheRatchetAndTicks() {
        let (feel, renderer, clock) = makeFeel()
        feel.slideBegan(.moveCursor, keyId: "space", keyFrame: frame)
        for _ in 0 ..< 3 {
            clock.now += 0.2
            feel.slideStep(.moveCursor, direction: 1)
        }
        #expect(feel.board.ratchet?.steps == 3)
        #expect(feel.board.ratchet?.lastDirection == 1)
        #expect(renderer.playedCues == Array(repeating: .cursorTick(.deliberate), count: 3))
        feel.slideEnded()
        #expect(feel.board.ratchet == nil)
    }

    @Test func fasterSlidesTickLighter() {
        let (feel, renderer, clock) = makeFeel()
        feel.slideBegan(.moveCursor, keyId: "space", keyFrame: frame)
        feel.slideStep(.moveCursor, direction: -1)
        clock.now += 0.07
        feel.slideStep(.moveCursor, direction: -1)
        clock.now += 0.03
        feel.slideStep(.moveCursor, direction: -1)
        clock.now += 0.015
        feel.slideStep(.moveCursor, direction: -1)
        #expect(renderer.playedCues == [
            .cursorTick(.deliberate), .cursorTick(.steady), .cursorTick(.brisk), .cursorTick(.rapid),
        ])
        #expect(feel.board.ratchet?.steps == -4)
    }

    @Test func stepsInOneBurstShareATick() {
        let (feel, renderer, clock) = makeFeel()
        feel.slideBegan(.delete, keyId: "delete", keyFrame: frame)
        feel.slideStep(.delete, direction: -1)
        feel.slideStep(.delete, direction: -1)
        feel.slideStep(.delete, direction: -1)
        #expect(renderer.playedCues == [.deleteTick])
        #expect(feel.board.ratchet?.steps == -3, "the ratchet still counts every step")
        clock.now += KeyboardFeel.slideTickSpacing
        feel.slideStep(.delete, direction: -1)
        #expect(renderer.playedCues == [.deleteTick, .deleteTick])
    }
}

// MARK: - Board

@MainActor
struct FeelBoardTests {
    private let frame = CGRect(x: 0, y: 0, width: 50, height: 50)

    @Test func popsAreBoundedAndRemovable() {
        let board = FeelBoard(now: { 0 })
        for index in 0 ..< 6 {
            board.add(FeelBoard.Pop(text: "\(index)", keyFrame: frame, gesture: .swipeUp))
        }
        #expect(board.pops.map(\.text) == ["2", "3", "4", "5"])
        #expect(Set(board.pops.map(\.id)).count == 4)
        board.removePop(id: board.pops[0].id)
        #expect(board.pops.map(\.text) == ["3", "4", "5"])
    }

    @Test func popsNobodyDrewAreDroppedOnTheNextCommit() {
        var now: TimeInterval = 0
        let board = FeelBoard(now: { now })
        board.add(FeelBoard.Pop(text: "a", keyFrame: frame, gesture: .swipeUp))
        now += FeelBoard.popLifetime + 0.1
        board.add(FeelBoard.Pop(text: "b", keyFrame: frame, gesture: .swipeUp))
        #expect(board.pops.map(\.text) == ["b"])
    }

    @Test func theRingFollowsItsKeyOnly() {
        let board = FeelBoard()
        board.showRing(keyId: "e", keyFrame: frame, duration: 0.7)
        board.hideRing(keyId: "a")
        #expect(board.ring != nil)
        board.fireRing(keyId: "e")
        #expect(board.ring?.hasFired == true)
        let id = board.ring!.id
        board.clearRing(id: id + 1)
        #expect(board.ring != nil)
        board.clearRing(id: id)
        #expect(board.ring == nil)
    }
}

// MARK: - Engine hooks

/// A 3×3 grid of flick keys plus a space bar, recording the feel hooks.
@MainActor
private final class FeelHookHarness {
    enum Event: Equatable {
        case candidate(String, from: GestureCandidate, to: GestureCandidate)
        case released(String, GestureType, isReturn: Bool)
        case releaseHandled
        case longPress(String, LongPressFeelPhase)
        case gesture(String, GestureType)
    }

    let engine = TouchEngine(trail: GestureTrailRecorder(defaults: InMemoryUserDefaults()), now: { 0 })
    private(set) var events: [Event] = []
    var longPressHandled = true

    init(longPress: Bool = false) {
        var cells: [SolvedCell] = []
        var keys: [String: KeyDefinition] = [:]
        for (index, id) in ["a", "b", "c", "d", "e", "f", "g", "h", "i"].enumerated() {
            cells.append(SolvedCell(keyId: id, row: index / 3, column: index % 3, rowSpan: 1, columnSpan: 1))
            keys[id] = KeyDefinition(
                id: id,
                bindings: [.tap: KeyBinding(label: id, action: .commitText(id), category: nil, returnAction: nil, accessibilityLabel: nil)],
                swipeMode: .eightWay, slideType: .none, style: .primary, tapCycleActions: nil
            )
        }
        cells.append(SolvedCell(keyId: "space", row: 3, column: 0, rowSpan: 1, columnSpan: 3))
        keys["space"] = KeyDefinition(
            id: "space",
            bindings: [.tap: KeyBinding(label: " ", action: .space, category: nil, returnAction: nil, accessibilityLabel: nil)],
            swipeMode: .twoWayHorizontal, slideType: .moveCursor, style: .spacebar, tapCycleActions: nil
        )
        engine.configure(
            geometry: GridGeometry(
                cells: cells, columns: 3, rowHeight: 54, horizontalSpacing: 6, verticalSpacing: 8,
                cellAspectRatio: 96.0 / 54.0
            ),
            keys: keys,
            tuning: .default,
            isLongPressEnabled: longPress,
            actions: TouchEngineActions(
                gesture: { [unowned self] key, classification in events.append(.gesture(key.id, classification.gesture)) },
                longPress: { [unowned self] _ in longPressHandled },
                candidateChanged: { [unowned self] key, old, new in events.append(.candidate(key.id, from: old, to: new)) },
                released: { [unowned self] key, classification in
                    events.append(.released(key.id, classification.gesture, isReturn: classification.isReturn))
                },
                releaseHandled: { [unowned self] in events.append(.releaseHandled) },
                longPressPhase: { [unowned self] key, phase in events.append(.longPress(key.id, phase)) }
            )
        )
        engine.updateSize(CGSize(width: 300, height: 240))
    }

    func frame(of id: String) -> CGRect { engine.hitMap.key(withId: id)!.frame }
    func center(of id: String) -> CGPoint { CGPoint(x: frame(of: id).midX, y: frame(of: id).midY) }

    func drag(_ pointer: PointerID, from start: CGPoint, by delta: CGVector, steps: Int = 8) {
        for step in 1 ... steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            engine.moved(pointer, samples: [TouchSample(
                location: CGPoint(x: start.x + delta.dx * fraction, y: start.y + delta.dy * fraction),
                time: Double(step) / 120
            )])
        }
    }
}

@MainActor
struct TouchEngineFeelHookTests {
    @Test func aFlickReportsEachTargetChangeOnce() {
        let harness = FeelHookHarness()
        let start = harness.center(of: "e")
        harness.engine.began(1, at: start, time: 0)
        harness.drag(1, from: start, by: CGVector(dx: 60, dy: 0))
        // Keep going the same way: no further change, no further report.
        harness.drag(1, from: CGPoint(x: start.x + 60, y: start.y), by: CGVector(dx: 10, dy: 0))
        let changes = harness.events.filter { if case .candidate = $0 { true } else { false } }
        #expect(changes == [.candidate("e", from: .tap, to: GestureCandidate(gesture: .swipeRight))])
    }

    @Test func theReleaseIsReportedAtTheLiftEvenWhenTheKeystrokeWaits() {
        let harness = FeelHookHarness()
        harness.engine.began(1, at: harness.center(of: "a"), time: 0)
        harness.engine.began(2, at: harness.center(of: "b"), time: 0.05)
        harness.engine.ended(2, at: harness.center(of: "b"), time: 0.09)
        // b's keystroke waits for a, but its release was felt already.
        #expect(harness.events.suffix(2) == [.released("b", .tap, isReturn: false), .releaseHandled])
        #expect(!harness.events.contains(.gesture("b", .tap)))
    }

    /// Resolved before the keystroke goes out, issued after it: the click
    /// and the pop never precede the text.
    @Test func theReleaseBracketsTheKeystroke() {
        let harness = FeelHookHarness()
        harness.engine.began(1, at: harness.center(of: "e"), time: 0)
        harness.engine.ended(1, at: harness.center(of: "e"), time: 0.05)
        #expect(harness.events == [
            .released("e", .tap, isReturn: false),
            .gesture("e", .tap),
            .releaseHandled,
        ])
    }

    @Test func aSpaceTapReportsAPlainTapRelease() {
        let harness = FeelHookHarness()
        harness.engine.began(1, at: harness.center(of: "space"), time: 0)
        harness.engine.ended(1, at: harness.center(of: "space"), time: 0.05)
        #expect(harness.events.contains(.released("space", .tap, isReturn: false)))
    }

    @Test func aSpaceSlideReportsNoRelease() {
        let harness = FeelHookHarness()
        let start = harness.center(of: "space")
        harness.engine.began(1, at: start, time: 0)
        harness.drag(1, from: start, by: CGVector(dx: 80, dy: 0))
        harness.engine.ended(1, at: CGPoint(x: start.x + 80, y: start.y), time: 0.3)
        #expect(!harness.events.contains { if case .released = $0 { true } else { false } })
    }

    @Test func theTouchPointIsRecordedInKeyUnits() {
        let harness = FeelHookHarness()
        let frame = harness.frame(of: "e")
        harness.engine.began(1, at: CGPoint(x: frame.minX + frame.width * 0.25, y: frame.minY + frame.height * 0.75), time: 0)
        let point = harness.engine.press.cell(for: "e").touchPoint
        #expect(abs(point.x - 0.25) < 0.001)
        #expect(abs(point.y - 0.75) < 0.001)
    }

    @Test func aLongPressIsArmedAtTouchDownWithItsKeyAndDelay() {
        let harness = FeelHookHarness(longPress: true)
        harness.engine.began(1, at: harness.center(of: "e"), time: 0)
        #expect(harness.events == [.longPress("e", .armed(
            keyFrame: harness.frame(of: "e"), delay: GestureTuning.default.longPressDuration
        ))])
    }

    @Test func movingAwayCancelsTheLongPress() {
        let harness = FeelHookHarness(longPress: true)
        let start = harness.center(of: "e")
        harness.engine.began(1, at: start, time: 0)
        harness.drag(1, from: start, by: CGVector(dx: 50, dy: 0))
        #expect(harness.events.contains(.longPress("e", .cancelled)))
    }

    @Test func liftingFirstCancelsTheLongPress() {
        let harness = FeelHookHarness(longPress: true)
        harness.engine.began(1, at: harness.center(of: "e"), time: 0)
        harness.engine.ended(1, at: harness.center(of: "e"), time: 0.1)
        #expect(harness.events.contains(.longPress("e", .cancelled)))
    }

    @Test func aFiredLongPressReportsFiredAndNoCancel() {
        let harness = FeelHookHarness(longPress: true)
        harness.engine.began(1, at: harness.center(of: "e"), time: 0)
        harness.engine.fireLongPressTimer(for: 1)
        harness.engine.ended(1, at: harness.center(of: "e"), time: 0.8)
        let phases = harness.events.compactMap { event -> LongPressFeelPhase? in
            if case let .longPress(_, phase) = event { phase } else { nil }
        }
        #expect(phases.count == 2)
        #expect(phases.last == .fired)
    }

    @Test func anUnhandledLongPressReportsCancelled() {
        let harness = FeelHookHarness(longPress: true)
        harness.longPressHandled = false
        harness.engine.began(1, at: harness.center(of: "e"), time: 0)
        harness.engine.fireLongPressTimer(for: 1)
        #expect(harness.events.last == .longPress("e", .cancelled))
    }

    @Test func nothingIsArmedWhileLongPressesAreOff() {
        let harness = FeelHookHarness(longPress: false)
        harness.engine.began(1, at: harness.center(of: "e"), time: 0)
        #expect(harness.events.isEmpty)
    }
}

// MARK: - Through the view model

@MainActor
struct ViewModelFeelTests {
    @Test func commitsResolveTheirKindAndGlyph() throws {
        let scenario = KeyboardScenario(autoCapitalize: false)
        let viewModel = scenario.viewModel
        let mode = try #require(viewModel.activeModeFromDefinition)
        let center = try #require(mode.key(for: GridSlot.center))
        let tapText = try #require(center.bindings[.tap]?.label)

        let tap = viewModel.commitFeel(for: GestureClassification(gesture: .tap, isReturn: false), keyId: GridSlot.center)
        #expect(tap == CommitFeel(commitType: .tap, popText: tapText))

        let swipeGesture = try #require(KeyView.hintGestureOrder.first { center.bindings[$0] != nil })
        let swipe = viewModel.commitFeel(for: GestureClassification(gesture: swipeGesture, isReturn: false), keyId: GridSlot.center)
        #expect(swipe?.commitType == .swipe)

        let circle = viewModel.commitFeel(
            for: GestureClassification(gesture: .circularClockwise, isReturn: false), keyId: GridSlot.center
        )
        #expect(circle == CommitFeel(commitType: .circle, popText: tapText.uppercased()))
    }

    @Test func spacesAndUnboundDirectionsPopNothing() throws {
        let scenario = KeyboardScenario(autoCapitalize: false)
        let viewModel = scenario.viewModel
        let space = viewModel.commitFeel(for: GestureClassification(gesture: .tap, isReturn: false), keyId: UtilitySlot.space)
        #expect(space?.commitType == .tap)
        #expect(space?.popText == nil)
        let mode = try #require(viewModel.activeModeFromDefinition)
        let center = try #require(mode.key(for: GridSlot.center))
        if let unbound = KeyView.hintGestureOrder.first(where: { center.bindings[$0] == nil }) {
            #expect(viewModel.commitFeel(for: GestureClassification(gesture: unbound, isReturn: false), keyId: GridSlot.center) == nil)
        }
    }

    /// A mode switch confirms itself with its own cue; the release must not
    /// add a second pattern.
    @Test func modeKeysLeaveTheirConfirmationToTheSwitch() throws {
        let scenario = KeyboardScenario(autoCapitalize: false)
        let viewModel = scenario.viewModel
        let mode = try #require(viewModel.activeModeFromDefinition)
        let switcher = try #require(mode.keys.values.first {
            if case .switchMode = $0.bindings[.tap]?.action { true } else { false }
        })
        #expect(viewModel.commitFeel(for: GestureClassification(gesture: .tap, isReturn: false), keyId: switcher.id) == nil)
    }

    @Test func aSwipePopsItsGlyphFromTheCardCell() throws {
        let scenario = KeyboardScenario(autoCapitalize: false)
        let mode = try #require(scenario.viewModel.activeModeFromDefinition)
        let center = try #require(mode.key(for: GridSlot.center))
        let gesture = try #require(KeyView.hintGestureOrder.first {
            if case .commitText = center.bindings[$0]?.action { true } else { false }
        })
        scenario.swipe(GridSlot.center, gesture)
        let pop = try #require(scenario.viewModel.feel.board.pops.last)
        #expect(pop.gesture == gesture)
        #expect(scenario.text.hasSuffix(pop.text))
    }

    @Test func aTapPopsNothing() {
        let scenario = KeyboardScenario(autoCapitalize: false)
        scenario.tap(GridSlot.center)
        #expect(scenario.viewModel.feel.board.pops.isEmpty)
    }

    @Test func aLongSwipePopsItsActionGlyph() throws {
        let scenario = KeyboardScenario(
            autoCapitalize: false,
            settings: [.expertModeEnabled: true, .isLongSwipeEnabled: true]
        )
        let tuning = scenario.viewModel.gestureTuning
        let classification = GestureClassification(gesture: .swipeLeft, isReturn: false, displacementInKeys: CGVector(dx: -3, dy: 0))
        let action = try #require(tuning.longSwipe.action(for: classification))
        let feel = scenario.viewModel.commitFeel(for: classification, keyId: GridSlot.center)
        #expect(feel == CommitFeel(commitType: .longSwipe, popText: action.previewGlyph, isAction: true))
    }

    /// Down-left dismisses by default: the pipeline's dismissal cue confirms
    /// it, so the release itself stays silent (but still pops its glyph).
    @Test func aSelfConfirmingLongSwipeDoesNotClickTwice() throws {
        let scenario = KeyboardScenario(
            autoCapitalize: false,
            settings: [.expertModeEnabled: true, .isLongSwipeEnabled: true]
        )
        let classification = GestureClassification(
            gesture: .swipeDownLeft, isReturn: false, displacementInKeys: CGVector(dx: -2.5, dy: 2.5)
        )
        let feel = try #require(scenario.viewModel.commitFeel(for: classification, keyId: GridSlot.center))
        #expect(!feel.clicks)
        #expect(feel.popText != nil)
    }

    @Test func aCursorSlideRunsTheRatchetAndEndsIt() throws {
        let scenario = KeyboardScenario(autoCapitalize: false)
        scenario.type("hello")
        let viewModel = scenario.viewModel
        viewModel.configureTouchEngine(containerWidth: scenario.containerWidth, isLongPressEnabled: false)
        let engine = viewModel.touchEngine
        let frame = try #require(engine.hitMap.key(withId: UtilitySlot.space)?.frame)
        let start = CGPoint(x: frame.midX, y: frame.midY)
        engine.began(1, at: start, time: 0)
        for step in 1 ... 20 {
            let point = CGPoint(x: start.x - CGFloat(step) * 3, y: start.y)
            engine.moved(1, samples: [TouchSample(location: point, time: Double(step) / 60)])
        }
        let ratchet = try #require(viewModel.feel.board.ratchet)
        #expect(ratchet.slideType == .moveCursor)
        #expect(ratchet.keyId == UtilitySlot.space)
        #expect(ratchet.steps < 0, "a slide to the left steps left")
        #expect(scenario.cursor == 5 + ratchet.steps)
        engine.ended(1, at: CGPoint(x: start.x - 60, y: start.y), time: 0.5)
        #expect(viewModel.feel.board.ratchet == nil, "the ratchet ends with the slide")
    }

    @Test func aDeleteSlideRunsARedRatchet() throws {
        let scenario = KeyboardScenario(autoCapitalize: false)
        scenario.type("hello")
        let viewModel = scenario.viewModel
        viewModel.configureTouchEngine(containerWidth: scenario.containerWidth, isLongPressEnabled: false)
        let engine = viewModel.touchEngine
        let frame = try #require(engine.hitMap.key(withId: UtilitySlot.delete)?.frame)
        let start = CGPoint(x: frame.midX, y: frame.midY)
        engine.began(1, at: start, time: 0)
        for step in 1 ... 30 {
            engine.moved(1, samples: [TouchSample(location: CGPoint(x: start.x - CGFloat(step) * 3, y: start.y), time: Double(step) / 60)])
        }
        let ratchet = try #require(viewModel.feel.board.ratchet)
        #expect(ratchet.slideType == .delete)
        #expect(scenario.text.count == 5 + ratchet.steps)
        engine.cancelled(1)
        #expect(viewModel.feel.board.ratchet == nil)
    }

    @Test func aLongPressDigitArmsTheRing() throws {
        let scenario = KeyboardScenario(autoCapitalize: false, settings: [.isLongPressDigitEnabled: true])
        let viewModel = scenario.viewModel
        viewModel.configureTouchEngine(containerWidth: scenario.containerWidth, isLongPressEnabled: true)
        let engine = viewModel.touchEngine
        let frame = try #require(engine.hitMap.key(withId: GridSlot.center)?.frame)
        engine.began(1, at: CGPoint(x: frame.midX, y: frame.midY), time: 0)
        #expect(viewModel.feel.board.ring?.keyId == GridSlot.center)
        engine.fireLongPressTimer(for: 1)
        #expect(viewModel.feel.board.ring?.hasFired == true)
        #expect(viewModel.feel.board.pops.last?.text.first?.isNumber == true)
        engine.ended(1, at: CGPoint(x: frame.midX, y: frame.midY), time: 0.8)
    }

    @Test func keysWithoutAHoldBindingGetNoRing() throws {
        let scenario = KeyboardScenario(autoCapitalize: false, settings: [.isLongPressDigitEnabled: true])
        let viewModel = scenario.viewModel
        viewModel.configureTouchEngine(containerWidth: scenario.containerWidth, isLongPressEnabled: true)
        let engine = viewModel.touchEngine
        let frame = try #require(engine.hitMap.key(withId: UtilitySlot.return)?.frame)
        engine.began(1, at: CGPoint(x: frame.midX, y: frame.midY), time: 0)
        #expect(viewModel.feel.board.ring == nil)
        engine.cancelAll()
    }
}
