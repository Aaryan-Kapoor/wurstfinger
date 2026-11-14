//
//  NumpadColumnScenarioTests.swift
//  WurstfingerTests
//
//  End to end: a synthetic finger types digits on the numpad column — leading
//  and trailing, phone and calculator style, in a layout with native numerals —
//  and types with the keys at the tightest and the widest spacing, and on the
//  split layout. Every touch goes through the view model's real input engine,
//  hit map included, so the touch frames and the drawn layout cannot disagree
//  without a digit coming out wrong.
//

import CoreGraphics
import Foundation
import Testing
@testable import WurstfingerKit
@testable import WurstfingerScenarioKit

@Suite(.serialized)
@MainActor
struct NumpadColumnScenarioTests {
    private let keyIds = NumpadColumn.keyIds

    private func scenario(
        language: String = "en_US",
        placement: NumpadColumnPlacement = .trailing,
        style: NumpadType = .phone,
        spacing: Double? = nil,
        utilityLeading: Bool = false,
        autoCapitalize: Bool = false,
        containerWidth: CGFloat = 393
    ) -> KeyboardScenario {
        var settings: [SettingsKey: Any] = [
            .numpadColumn: placement.rawValue,
            .numpadStyle: style.rawValue,
            .utilityColumnLeading: utilityLeading,
        ]
        if let spacing { settings[.keySpacing] = spacing }
        return KeyboardScenario(
            language: language, containerWidth: containerWidth, autoCapitalize: autoCapitalize, settings: settings
        )
    }

    /// Types the digit at (`row`, `side`) of the column by its gesture:
    /// left swipe, tap or right swipe.
    private func type(_ side: Int, onRow row: Int, in scenario: KeyboardScenario) {
        switch side {
        case 0: scenario.swipe(keyIds[row], .swipeLeft)
        case 1: scenario.tap(keyIds[row])
        default: scenario.swipe(keyIds[row], .swipeRight)
        }
    }

    // MARK: Digits

    @Test(arguments: [NumpadColumnPlacement.leading, .trailing], [NumpadType.phone, .classic])
    func everyDigitIsOneGestureAway(placement: NumpadColumnPlacement, style: NumpadType) {
        for utilityLeading in [false, true] {
            checkEveryDigit(placement: placement, style: style, utilityLeading: utilityLeading)
        }
    }

    private func checkEveryDigit(placement: NumpadColumnPlacement, style: NumpadType, utilityLeading: Bool) {
        let scenario = scenario(placement: placement, style: style, utilityLeading: utilityLeading)
        let expectedRows = style == .phone
            ? [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], [",", "0", "."]]
            : [["7", "8", "9"], ["4", "5", "6"], ["1", "2", "3"], [",", "0", "."]]
        for row in 0 ..< 4 {
            for side in 0 ..< 3 {
                scenario.clear()
                type(side, onRow: row, in: scenario)
                #expect(
                    scenario.text == expectedRows[row][side],
                    "\(placement) \(style) utility-left=\(utilityLeading): row \(row) side \(side)"
                )
            }
        }
    }

    @Test func aWholeNumberTypesInSequence() {
        let scenario = scenario(placement: .leading)
        // 1 2 3 . 4 5 : left swipe on row 0, tap row 0, right swipe row 0 ...
        type(0, onRow: 0, in: scenario)
        type(1, onRow: 0, in: scenario)
        type(2, onRow: 0, in: scenario)
        type(2, onRow: 3, in: scenario)
        type(0, onRow: 1, in: scenario)
        type(1, onRow: 1, in: scenario)
        #expect(scenario.text == "123.45")
    }

    @Test func typeFindsTheDigitsInTheLetterModeWithoutLeavingIt() {
        let scenario = scenario()
        #expect(scenario.mode == ModeNames.main)
        let missing = scenario.type("a1b20")
        #expect(missing.isEmpty, "no gesture produces \(missing)")
        #expect(scenario.text == "a1b20")
        #expect(scenario.mode == ModeNames.main)
    }

    @Test func theSymbolGesturesTypeTheirMarks() {
        let scenario = scenario()
        let expected: [(row: Int, gesture: GestureType, text: String)] = [
            (0, .swipeUp, "+"), (0, .swipeDown, "-"), (0, .swipeUpLeft, "×"), (0, .swipeUpRight, "÷"),
            (0, .swipeDownLeft, "("), (0, .swipeDownRight, ")"),
            (1, .swipeUp, "%"), (1, .swipeDown, "="), (1, .swipeUpLeft, "$"), (1, .swipeUpRight, "€"),
            (3, .swipeUpLeft, "°"), (3, .swipeDownRight, "π"),
        ]
        for item in expected {
            scenario.clear()
            scenario.swipe(keyIds[item.row], item.gesture)
            #expect(scenario.text == item.text, "row \(item.row) \(item.gesture)")
        }
    }

    @Test func aCircleOnANumpadKeyTypesNothing() {
        let scenario = scenario()
        let outcome = scenario.circle(keyIds[1])
        #expect(outcome.gesture == .circularClockwise)
        #expect(scenario.text.isEmpty)
    }

    @Test func nativeNumeralsComeFromTheLayoutsOwnDigitSet() {
        let scenario = scenario(language: "ar")
        type(0, onRow: 0, in: scenario)
        type(1, onRow: 0, in: scenario)
        type(2, onRow: 0, in: scenario)
        #expect(scenario.text == "١٢٣")
        scenario.clear()
        type(1, onRow: 3, in: scenario)
        #expect(scenario.text == "٠")

        let devanagari = self.scenario(language: "hi_IN", style: .classic)
        type(1, onRow: 0, in: devanagari)
        #expect(devanagari.text == "८")
        let thai = self.scenario(language: "th_TH")
        type(1, onRow: 1, in: thai)
        #expect(thai.text == "๕")
        let persian = self.scenario(language: "fa_IR", placement: .leading)
        type(2, onRow: 2, in: persian)
        #expect(persian.text == "۹")
    }

    @Test func digitsWorkInEveryLetterMode() {
        for mode in [ModeNames.main, ModeNames.shifted, ModeNames.capsLock] {
            let scenario = scenario()
            scenario.viewModel.switchToMode(mode)
            scenario.tap(keyIds[0])
            #expect(scenario.text == "2", "mode \(mode)")
        }
    }

    @Test func aDigitAfterAutoCapitalizationDoesNotLoseTheText() {
        let scenario = scenario(autoCapitalize: true)
        #expect(scenario.mode == ModeNames.shifted)
        scenario.tap(keyIds[0])
        scenario.type("a")
        #expect(scenario.text.hasPrefix("2"))
        #expect(scenario.text.count == 2)
    }

    @Test func theNumericModeHasNoNumpadColumnAndItsKeysTypeNothing() {
        let scenario = scenario()
        scenario.viewModel.switchToMode(ModeNames.numeric)
        let outcome = scenario.tap(keyIds[0])
        #expect(!outcome.dispatched)
        #expect(scenario.text.isEmpty)
        // The ordinary numeric keys are still there.
        scenario.tap(GridSlot.topLeft)
        #expect(scenario.text == "1")
    }

    @Test func theGuidePreviewsTheDigitASwipeWouldType() {
        let scenario = scenario()
        #expect(scenario.viewModel.previewLabel(for: .swipeRight, keyId: keyIds[1], isReturn: false) == "6")
        #expect(scenario.viewModel.previewLabel(for: .swipeLeft, keyId: keyIds[1], isReturn: false) == "4")
        #expect(scenario.viewModel.previewLabel(for: .tap, keyId: keyIds[1], isReturn: false) == "5")
        #expect(scenario.viewModel.previewLabel(for: .swipeUpRight, keyId: keyIds[2], isReturn: false) == "^")
        let arabic = self.scenario(language: "ar")
        #expect(arabic.viewModel.previewLabel(for: .swipeRight, keyId: keyIds[0], isReturn: false) == "٣")
    }

    @Test func theLettersStillTypeWithTheColumnOn() {
        for placement in [NumpadColumnPlacement.leading, .trailing] {
            let scenario = scenario(placement: placement)
            let missing = scenario.type("hello, world")
            #expect(missing.isEmpty)
            #expect(scenario.text == "hello, world")
        }
    }

    // MARK: Spacing

    @Test(arguments: [0.0, 5.0, 12.0])
    func typingWorksAtEverySpacing(spacing: Double) {
        let scenario = scenario(spacing: spacing, containerWidth: 393)
        let missing = scenario.type("hello 42, ok")
        #expect(missing.isEmpty, "no gesture produces \(missing)")
        #expect(scenario.text == "hello 42, ok")
        #expect(scenario.metrics.keySpacing == CGFloat(spacing))
    }

    @Test(arguments: [0.0, 12.0], [NumpadColumnPlacement.off, .leading, .trailing])
    func everyKeyOfTheGridCanBeTappedAtTheExtremes(spacing: Double, placement: NumpadColumnPlacement) throws {
        let scenario = scenario(placement: placement, spacing: spacing)
        let mode = try #require(scenario.viewModel.activeModeFromDefinition)
        let slots = mode.keys.keys.filter { GridSlot.allSlots.joined().contains($0) }.sorted()
        for slot in slots {
            let outcome = scenario.tap(slot)
            #expect(outcome.gesture == .tap, "\(slot) at spacing \(spacing)")
            #expect(outcome.dispatched, "\(slot) at spacing \(spacing)")
        }
        let tapped = scenario.text
        #expect(tapped.count == 9, "all nine letters typed: '\(tapped)'")
    }

    @Test func aTouchInTheGapGoesToTheNearerKey() throws {
        let scenario = scenario(placement: .off, spacing: 12)
        let engine = scenario.engine
        _ = scenario.tap(GridSlot.center)  // configures the engine against the layout
        let map = engine.hitMap
        let left = try #require(map.key(withId: GridSlot.midLeft))
        let centre = try #require(map.key(withId: GridSlot.center))
        // The gap is 12 pt wide; a touch 1 pt past the left key's drawn edge
        // is still the left key, 1 pt before the centre key's drawn edge is the centre.
        let leftDrawnEdge = left.frame.maxX - 6
        #expect(map.key(at: CGPoint(x: leftDrawnEdge + 1, y: left.frame.midY))?.id == GridSlot.midLeft)
        #expect(map.key(at: CGPoint(x: centre.frame.minX + 1, y: left.frame.midY))?.id == GridSlot.center)
    }

    // MARK: Split

    private func splitScenario(
        placement: NumpadColumnPlacement = .trailing, utilityLeading: Bool = false, language: String = "en_US"
    ) -> KeyboardScenario {
        let scenario = KeyboardScenario(
            language: language, containerWidth: 1366, autoCapitalize: false,
            settings: [
                .numpadColumn: placement.rawValue,
                .isSplitLayoutEnabled: true,
                .utilityColumnLeading: utilityLeading,
            ]
        )
        scenario.viewModel.screenSizeOverride = CGSize(width: 1366, height: 1024)
        return scenario
    }

    @Test func theSplitTypesLettersDigitsAndSymbolsFromBothClusters() {
        let scenario = splitScenario()
        #expect(scenario.viewModel.layoutPlan(forContainerWidth: 1366)?.isSplit == true)
        let missing = scenario.type("hello 123, ok")
        #expect(missing.isEmpty, "no gesture produces \(missing)")
        #expect(scenario.text == "hello 123, ok")
    }

    @Test func theSplitNumpadStillTypesEveryDigit() {
        let scenario = splitScenario(utilityLeading: true)
        for row in 0 ..< 3 {
            for side in 0 ..< 3 {
                scenario.clear()
                type(side, onRow: row, in: scenario)
                #expect(scenario.text == String(row * 3 + side + 1), "row \(row) side \(side)")
            }
        }
    }

    @Test func theSplitKeepsTheSwipeGeometryOfTheKeys() {
        let scenario = splitScenario()
        // A swipe on a key at the edge of a cluster, toward the gap, is a swipe.
        let outcome = scenario.swipe(GridSlot.midRight, .swipeRight)
        #expect(outcome.gesture == .swipeRight)
        #expect(outcome.dispatched)
    }

    @Test func aTouchInTheEmptyMiddleTypesNothing() throws {
        let scenario = splitScenario()
        _ = scenario.tap(GridSlot.center)  // configures the engine against the layout
        scenario.clear()
        let engine = scenario.engine
        let map = engine.hitMap
        let right = try #require(map.key(withId: GridSlot.midRight))
        let numpad = try #require(map.key(withId: NumpadColumn.keyIds[1]))
        let middle = CGPoint(x: (right.frame.maxX + numpad.frame.minX) / 2, y: right.frame.midY)
        engine.began(77, at: middle, time: 5000)
        engine.ended(77, at: middle, time: 5000.05)
        #expect(scenario.text.isEmpty)
        #expect(engine.activePointerCount == 0)
    }

    @Test func theSplitIsIgnoredOnAPortraitScreen() {
        let scenario = KeyboardScenario(
            language: "en_US", containerWidth: 820, autoCapitalize: false,
            settings: [.isSplitLayoutEnabled: true]
        )
        scenario.viewModel.screenSizeOverride = CGSize(width: 820, height: 1180)
        #expect(scenario.viewModel.layoutPlan(forContainerWidth: 820)?.isSplit == false)
        scenario.type("ok")
        #expect(scenario.text == "ok")
    }
}
