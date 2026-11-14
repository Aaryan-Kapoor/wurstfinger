//
//  KeyboardScenarioTests.swift
//  WurstfingerTests
//
//  End-to-end typing: a synthetic finger moves over a real keyboard, its touch
//  path goes through gesture recognition, resolution and the action pipeline,
//  and the assertions read the text that comes out. Nothing here hands the
//  pipeline a pre-classified gesture.
//

import CoreGraphics
import Foundation
import Testing
@testable import WurstfingerKit
@testable import WurstfingerScenarioKit

// MARK: - Typing sentences

@Suite(.serialized)
@MainActor
struct ScenarioTypingTests {
    @Test func helloWorldWithAutoCapitalization() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: true)
        // The empty document opens on shifted letters, as the controller does.
        #expect(scenario.mode == ModeNames.shifted)

        let missing = scenario.type("Hello, World!")
        #expect(missing.isEmpty, "no gesture produces \(missing)")
        #expect(scenario.text == "Hello, World!")
        #expect(scenario.cursor == 13)
    }

    @Test func autoCapitalizationShiftsTheFirstLetterOnly() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: true)
        // "h" is the centre-row, left key (centre tap "h" in the English layout).
        scenario.tap(GridSlot.midLeft)
        scenario.tap(GridSlot.topLeft)
        #expect(scenario.text == "Ha")
        #expect(scenario.mode == ModeNames.main)
    }

    @Test func withoutAutoCapitalizationTheFirstLetterIsLowercase() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        #expect(scenario.mode == ModeNames.main)
        scenario.type("hello")
        #expect(scenario.text == "hello")
    }

    @Test func sentenceEndCapitalizesTheNextWord() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: true)
        scenario.type("Hi. ")
        #expect(scenario.mode == ModeNames.shifted)
        scenario.type("Ok")
        #expect(scenario.text == "Hi. Ok")
    }

    @Test func germanSentenceWithUmlautsTypesThroughSwipes() {
        let scenario = KeyboardScenario(language: "de_DE", autoCapitalize: true)
        let missing = scenario.type("Schöne Grüße")
        #expect(missing.isEmpty, "no gesture produces \(missing)")
        #expect(scenario.text == "Schöne Grüße")
    }

    @Test func russianTypesCyrillic() {
        let scenario = KeyboardScenario(language: "ru_RU", autoCapitalize: false)
        let missing = scenario.type("привет")
        #expect(missing.isEmpty, "no gesture produces \(missing)")
        #expect(scenario.text == "привет")
    }
}

// MARK: - Single gestures

@Suite(.serialized)
@MainActor
struct ScenarioGestureTests {
    @Test func tapTypesTheCentreCharacter() {
        let scenario = KeyboardScenario(language: "de_DE", autoCapitalize: false)
        let outcome = scenario.tap(GridSlot.topLeft)
        #expect(outcome.gesture == .tap)
        #expect(scenario.text == "a")
    }

    /// The scenario the UI test `testSwipeDownProducesDifferentCharacterThanTap`
    /// runs on a simulator: swiping up on German top-left is unbound, swiping
    /// down types "ä".
    @Test func swipeDownOnGermanTopLeftTypesAUmlaut() {
        let scenario = KeyboardScenario(language: "de_DE", autoCapitalize: false)
        scenario.tap(GridSlot.topLeft)
        let tapped = scenario.text
        scenario.clear()

        let outcome = scenario.swipe(GridSlot.topLeft, .swipeDown)
        #expect(outcome.gesture == .swipeDown)
        #expect(scenario.text == "ä")
        #expect(scenario.text != tapped)
    }

    @Test func swipeUpOnGermanTopLeftIsUnbound() {
        let scenario = KeyboardScenario(language: "de_DE", autoCapitalize: false)
        let outcome = scenario.swipe(GridSlot.topLeft, .swipeUp)
        #expect(outcome.gesture == .swipeUp)
        #expect(!outcome.dispatched)
        #expect(scenario.text.isEmpty)
    }

    @Test func swipeDownRightTypesV() {
        let scenario = KeyboardScenario(language: "de_DE", autoCapitalize: false)
        scenario.swipe(GridSlot.topLeft, .swipeDownRight)
        #expect(scenario.text == "v")
    }

    @Test func composeSequenceAcuteAccentOnA() {
        let scenario = KeyboardScenario(language: "de_DE", autoCapitalize: false)
        scenario.tap(GridSlot.topLeft) // "a"
        // The acute accent is a compose trigger on top-centre, up-right; it
        // combines with the "a" before the cursor.
        scenario.swipe(GridSlot.topCenter, .swipeUpRight)
        #expect(scenario.text == "á")
    }

    @Test func circleTypesTheUppercaseOfTheCentreLetter() {
        let scenario = KeyboardScenario(language: "de_DE", autoCapitalize: false)
        let outcome = scenario.circle(GridSlot.topLeft, clockwise: true)
        #expect(outcome.gesture == .circularClockwise)
        #expect(scenario.text == "A")
    }

    @Test func returnSwipeIsRecognizedAsOne() {
        let scenario = KeyboardScenario(language: "de_DE", autoCapitalize: false)
        let outcome = scenario.returnSwipe(GridSlot.center, .swipeUp)
        #expect(outcome.gesture == .swipeUp)
        #expect(outcome.isReturn)
    }

    @Test func spaceAndReturnKeys() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        scenario.tap(GridSlot.topLeft)
        scenario.tap(UtilitySlot.space)
        scenario.tap(GridSlot.topLeft)
        scenario.tap(UtilitySlot.return)
        #expect(scenario.text == "a a\n")
    }

    @Test func unknownKeyDoesNothing() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        let outcome = scenario.tap("noSuchKey")
        #expect(outcome == GestureOutcome())
        #expect(scenario.text.isEmpty)
    }
}

// MARK: - Slide keys

@Suite(.serialized)
@MainActor
struct ScenarioSlideTests {
    @Test func tapOnDeleteRemovesOneCharacter() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        scenario.type("abc")
        let outcome = scenario.tap(UtilitySlot.delete)
        #expect(outcome.slidePhases == [.tap])
        #expect(scenario.text == "ab")
    }

    @Test func slidingLeftOnDeleteRemovesSeveralCharacters() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        scenario.type("abcdefgh")
        let outcome = scenario.drag(UtilitySlot.delete, by: CGSize(width: -110, height: 0))
        #expect(outcome.slidePhases.contains(.began))
        #expect(outcome.slidePhases.last == .ended)
        // 28 pt activates, then one character per 14 pt.
        #expect(scenario.text.count <= 4)
        #expect(scenario.text.count >= 2)
        #expect("abcdefgh".hasPrefix(scenario.text))
    }

    @Test func slidingTheSpaceBarMovesTheCursor() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        scenario.type("hello")
        #expect(scenario.cursor == 5)
        scenario.drag(UtilitySlot.space, by: CGSize(width: -70, height: 0))
        #expect(scenario.cursor < 5)
        #expect(scenario.text == "hello")
        scenario.drag(UtilitySlot.space, by: CGSize(width: 200, height: 0))
        #expect(scenario.cursor == 5)
    }

    @Test func tapOnSpaceTypesASpace() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        scenario.tap(UtilitySlot.space)
        #expect(scenario.text == " ")
    }
}

// MARK: - Modes

@Suite(.serialized)
@MainActor
struct ScenarioModeTests {
    @Test func numericModeTypesDigits() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        // Whichever key carries the switch to numbers, find it from the layout.
        let definition = scenario.viewModel.currentDefinition
        let main = definition?.mode(ModeNames.main)
        let switchKey = main?.keys.values.first { key in
            key.bindings.values.contains { $0.action == .switchMode(ModeNames.numeric) }
        }
        let gesture = switchKey?.bindings.first { $0.value.action == .switchMode(ModeNames.numeric) }?.key
        #expect(switchKey != nil)
        guard let switchKey, let gesture else { return }

        if gesture == .tap { scenario.tap(switchKey.id) } else { scenario.swipe(switchKey.id, gesture) }
        #expect(scenario.mode == ModeNames.numeric)

        // The numpad reads like a phone: 1 2 3 / 4 5 6 / 7 8 9, with 0 below.
        scenario.tap(GridSlot.topLeft)
        scenario.tap(GridSlot.center)
        scenario.tap(GridSlot.bottomRight)
        #expect(scenario.text == "159")
        #expect(scenario.mode == ModeNames.numeric)
    }

    @Test func typingDigitsRoutesThroughNumericAndBack() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        let missing = scenario.type("a1b2")
        #expect(missing.isEmpty, "no gesture produces \(missing)")
        #expect(scenario.text == "a1b2")
        #expect(scenario.mode == ModeNames.main)
    }

    @Test func longPressTypesTheDigitWhenEnabled() {
        let scenario = KeyboardScenario(
            language: "en_US", autoCapitalize: false,
            settings: [.isLongPressDigitEnabled: true]
        )
        let outcome = scenario.longPress(GridSlot.topLeft)
        #expect(outcome.firedLongPress)
        #expect(scenario.text == "1")
        #expect(scenario.mode == ModeNames.main)
    }

    @Test func longPressIsATapWhenDisabled() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        let outcome = scenario.longPress(GridSlot.topLeft)
        #expect(!outcome.firedLongPress)
        #expect(outcome.gesture == .tap)
        #expect(scenario.text == "a")
    }

    @Test func settingsStayInTheScenario() {
        let before = SharedDefaults.store.object(forKey: SettingsKey.autoCapitalizeEnabled.rawValue)
        _ = KeyboardScenario(language: "en_US", autoCapitalize: true)
        #expect(SharedDefaults.store.object(forKey: SettingsKey.autoCapitalizeEnabled.rawValue) as? Bool == before as? Bool)
    }
}

// MARK: - Recognition of synthesized paths

/// The synthesized paths have to be good enough to be recognized as what they
/// are across key shapes; otherwise the end-to-end tests above would be testing
/// the synthesizer instead of the keyboard.
@Suite(.serialized)
@MainActor
struct TouchPathRecognitionTests {
    private static let swipes: [GestureType] = GestureType.allCases.filter(\.isSwipe)

    @Test(arguments: [1.0, 1.2, 1.4, 1.62])
    func everySwipeIsRecognizedAtEveryAspectRatio(aspect: Double) {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        scenario.viewModel.keyAspectRatio = aspect
        for gesture in Self.swipes {
            let outcome = scenario.swipe(GridSlot.center, gesture)
            #expect(outcome.gesture == gesture, "aspect \(aspect): sent \(gesture), recognized \(String(describing: outcome.gesture))")
            #expect(!outcome.isReturn)
        }
    }

    @Test(arguments: [1.0, 1.4])
    func circlesAreRecognizedInBothDirections(aspect: Double) {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        scenario.viewModel.keyAspectRatio = aspect
        #expect(scenario.circle(GridSlot.center, clockwise: true).gesture == .circularClockwise)
        #expect(scenario.circle(GridSlot.center, clockwise: false).gesture == .circularCounterclockwise)
    }

    @Test func returnSwipesAreRecognizedInEveryDirection() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        for gesture in Self.swipes {
            let outcome = scenario.returnSwipe(GridSlot.center, gesture)
            #expect(outcome.gesture == gesture, "sent \(gesture), recognized \(String(describing: outcome.gesture))")
            #expect(outcome.isReturn, "\(gesture) did not read as a return swipe")
        }
    }

    @Test func tapsStayTaps() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        for _ in 0 ..< 20 {
            #expect(scenario.tap(GridSlot.center).gesture == .tap)
        }
    }

    @Test func keySizeFollowsTheLayout() {
        let scenario = KeyboardScenario(language: "en_US", containerWidth: 393)
        let size = scenario.keySize(GridSlot.center)
        #expect(abs(size.width - scenario.metrics.cellWidth) < 0.001)
        #expect(abs(size.height - scenario.metrics.cellHeight) < 0.001)
        // The space bar spans more than one column.
        #expect(scenario.keySize(UtilitySlot.space).width > size.width)
    }
}

// MARK: - The harness itself

@Suite
struct TouchPathTests {
    @Test func pathsStartAtTheOriginAndRunAt120Hz() {
        var synth = TouchSynthesizer(keySize: CGSize(width: 60, height: 60))
        let path = synth.swipe(.swipeRight, duration: 0.15)
        #expect(path.samples.first == .zero)
        #expect(path.samples.count == 19) // 18 intervals + the origin
        #expect(abs(path.duration - 0.15) < 1e-9)
    }

    @Test func pathsAreDeterministicPerSeed() {
        var a = TouchSynthesizer(keySize: CGSize(width: 60, height: 60), seed: 5)
        var b = TouchSynthesizer(keySize: CGSize(width: 60, height: 60), seed: 5)
        var c = TouchSynthesizer(keySize: CGSize(width: 60, height: 60), seed: 6)
        #expect(a.swipe(.swipeUp) == b.swipe(.swipeUp))
        #expect(a.swipe(.swipeUp) != c.swipe(.swipeUp))
    }

    @Test func tremorStaysSmall() {
        var synth = TouchSynthesizer(keySize: CGSize(width: 60, height: 60), jitter: 0.5)
        let path = synth.tap()
        #expect(path.maxDisplacement < 1)
    }

    @Test func swipeEndsWhereItWasAimed() {
        var synth = TouchSynthesizer(keySize: CGSize(width: 60, height: 50))
        let path = synth.swipe(.swipeDown, fraction: 1)
        #expect(path.end == CGPoint(x: 0, y: 50))
    }

    @MainActor @Test func textTargetMovesTheCursorInUTF16Units() {
        let target = ScenarioTextTarget()
        target.insertText("ab😀")
        #expect(target.cursor == 3)
        target.adjustTextPosition(byCharacterOffset: -2) // the emoji is two UTF-16 units
        #expect(target.before == "ab")
        #expect(target.after == "😀")
        target.deleteBackward()
        #expect(target.text == "a😀")
    }

    @Test func scenarioDefaultsNeverReachTheStandardDomain() {
        let defaults = ScenarioDefaults()
        let key = "scenario.test.\(UUID().uuidString)"
        defaults.set(true, forKey: key)
        defaults.set(["a", "b"], forKey: key + ".list")
        #expect(defaults.bool(forKey: key))
        #expect(defaults.stringArray(forKey: key + ".list") == ["a", "b"])
        #expect(UserDefaults.standard.object(forKey: key) == nil)
        defaults.removeObject(forKey: key)
        #expect(!defaults.bool(forKey: key))
    }

    @MainActor
    @Test func keyboardGeometryTilesTheGrid() {
        let scenario = KeyboardScenario(language: "en_US", containerWidth: 393)
        let layout = KeyboardGeometry.layout(of: scenario.viewModel, containerWidth: 393)
        #expect(layout != nil)
        guard let layout else { return }
        // Every key lies inside the grid.
        let grid = CGRect(origin: .zero, size: layout.gridSize)
        for (id, frame) in layout.keyFrames {
            #expect(grid.insetBy(dx: -0.001, dy: -0.001).contains(frame), "\(id) lies outside the grid")
        }
        // The keyboard's rows plus its chrome make up its height.
        #expect(abs(layout.keyboardHeight - scenario.metrics.totalHeight) < 0.001)
    }
}
