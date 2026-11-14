//
//  TerminalModeRobustnessTests.swift
//  WurstfingerKitTests
//
//  The one-shot Ctrl and Alt modes at their edges: what a gesture the main mode
//  never bound does there (the numeric mode's ghost keys must not answer), how
//  the mode is left, and what the feel layer makes of an inert key.
//

import Foundation
import Testing
@testable import WurstfingerKit
@testable import WurstfingerScenarioKit

@MainActor
struct TerminalModeGhostTests {
    /// Every (key, gesture) of the generated modes resolves to one of the
    /// mode's own bindings or to nothing; never to the numeric mode's.
    @Test(arguments: ["en_US", "en_US_thumbkey", "en_US_optimized", "de_DE"])
    func theNumericModeNeverAnswersForAModifierMode(languageId: String) throws {
        let definition = try #require(KeyboardRegistry.load(id: languageId))
        let compiled = CompiledDefinition(definition)
        for name in [ModeNames.control, ModeNames.alt] {
            let mode = try #require(definition.mode(name))
            let table = try #require(compiled.mode(name))
            for keyId in mode.keys.keys.sorted() {
                let slot = try #require(table.slot(for: keyId))
                let own = Array(try #require(mode.keys[keyId]).bindings.values)
                // A return swipe answers with its binding's `returnAction`
                // (`ReturnSwipeResolver`), so those count as the key's own too.
                let ownReturns = own.compactMap { binding in
                    binding.returnAction.map {
                        KeyBinding(
                            label: binding.label, action: $0, category: binding.category,
                            returnAction: nil, accessibilityLabel: binding.accessibilityLabel
                        )
                    }
                }
                for gesture in GestureType.allCases where !gesture.isCircular {
                    for isReturn in [false, true] {
                        guard let binding = table.binding(slot: slot, gesture: gesture, isReturn: isReturn) else { continue }
                        #expect(
                            own.contains(binding) || (isReturn && ownReturns.contains(binding)),
                            "\(languageId)/\(name)/\(keyId) \(gesture) return=\(isReturn) -> \(binding.action) came from outside the mode"
                        )
                    }
                }
            }
        }
    }

    @Test func aHoldOnAKeyTypesWhatItsTapTypesAndLeavesTheMode() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        scenario.swipe(UtilitySlot.symbols, .swipeUpLeft)
        #expect(scenario.mode == ModeNames.control)
        scenario.longPress(GridSlot.topLeft)
        // a is Ctrl-A, never the 1 the numeric mode holds under it.
        #expect(scenario.text == "\u{01}")
        #expect(scenario.mode == ModeNames.main, "a hold consumes the one-shot like a tap")
    }

    @Test func aHoldUnderAltPrefixesEscape() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        scenario.swipe(UtilitySlot.symbols, .swipeLeft)
        #expect(scenario.mode == ModeNames.alt)
        scenario.longPress(GridSlot.center)
        #expect(scenario.text == "\u{1B}" + "o")
    }

    @Test func theLessThanAndGreaterThanOfTheTopCornersStayOutOfTheModes() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        scenario.swipe(UtilitySlot.symbols, .swipeUpLeft)
        scenario.swipe(GridSlot.topLeft, .swipeLeft)
        #expect(scenario.text.isEmpty, "the ghost ≤ is not typed raw under Ctrl")
        #expect(scenario.mode == ModeNames.control, "an inert swipe leaves the modifier armed")
        scenario.swipe(GridSlot.topRight, .swipeRight)
        #expect(scenario.text.isEmpty)
    }
}

@MainActor
struct TerminalModeLifecycleTests {
    private func armed(_ symbolsGesture: GestureType = .swipeUpLeft) -> KeyboardScenario {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        scenario.swipe(UtilitySlot.symbols, symbolsGesture)
        return scenario
    }

    @Test func theAppearanceResetLeavesTheMode() {
        let scenario = armed()
        #expect(scenario.mode == ModeNames.control)
        scenario.viewModel.resetToDefaultMode()
        #expect(scenario.mode == ModeNames.main)
    }

    @Test func aLanguageSwitchLeavesTheMode() {
        let scenario = armed(.swipeLeft)
        #expect(scenario.mode == ModeNames.alt)
        scenario.viewModel.loadDefinition(for: "de_DE")
        #expect(scenario.mode == ModeNames.main)
    }

    @Test func autoCapitalizationNeverEntersOrLeavesTheMode() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: true)
        scenario.swipe(UtilitySlot.symbols, .swipeUpLeft)
        #expect(scenario.mode == ModeNames.control)
        scenario.viewModel.refreshAutoCapitalization()
        #expect(scenario.mode == ModeNames.control, "a text change must not pull the keyboard out of Ctrl")
        scenario.viewModel.engageAutoCapitalization()
        scenario.viewModel.releaseAutoCapitalization()
        #expect(scenario.mode == ModeNames.control)
    }

    /// A key that is not a letter does not consume the modifier: the one-shot
    /// stays armed (and visibly so, the symbols key shows ⌃) until a letter key
    /// or that key ends it.
    @Test func aKeyThatTypesNoLetterLeavesTheModifierArmed() {
        let scenario = armed()
        scenario.tap(UtilitySlot.space)
        #expect(scenario.mode == ModeNames.control)
        scenario.tap(UtilitySlot.symbols)
        #expect(scenario.mode == ModeNames.main)
    }
}

@MainActor
struct InertKeyFeelTests {
    @Test func anInertReleaseClicksForNothing() throws {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        scenario.swipe(UtilitySlot.symbols, .swipeUpLeft)
        // The acute dead key is inert under Ctrl.
        let classification = GestureClassification(gesture: .swipeUpRight, isReturn: false)
        #expect(scenario.viewModel.commitFeel(for: classification, keyId: GridSlot.topCenter) == nil)
        // A key that does type still clicks.
        let tap = GestureClassification(gesture: .tap, isReturn: false)
        #expect(scenario.viewModel.commitFeel(for: tap, keyId: GridSlot.topLeft)?.commitType == .tap)
    }

    @Test func theGlobesInertTapClicksForNothing() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        let tap = GestureClassification(gesture: .tap, isReturn: false)
        #expect(scenario.viewModel.commitFeel(for: tap, keyId: UtilitySlot.globe) == nil)
    }

    @Test func anInertHoldArmsNoRingAndPlaysNoClick() throws {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        let viewModel = scenario.viewModel
        // A key whose hold is bound, but to nothing.
        var definition = try #require(viewModel.currentDefinition)
        var main = try #require(definition.mode(ModeNames.main))
        var key = try #require(main.keys[GridSlot.topLeft])
        key.bindings[.longPress] = KeyBinding(
            label: "", action: .none, category: .utility, returnAction: nil, accessibilityLabel: nil
        )
        main = main.replacingKey(key)
        definition = definition.replacingMode(ModeNames.main, with: main)
        viewModel.currentDefinition = definition
        viewModel.rebuildResolverChain()

        let frame = CGRect(x: 0, y: 0, width: 50, height: 50)
        viewModel.feelLongPress(key, phase: .armed(keyFrame: frame, delay: 0.7))
        #expect(viewModel.feel.board.ring == nil, "nothing to confirm, nothing to count down to")
        viewModel.feelLongPress(key, phase: .fired)
        #expect(viewModel.feel.board.pops.isEmpty)

        // The same key with a real hold does arm.
        key.bindings[.longPress] = KeyBinding(
            label: "1", action: .commitText("1"), category: .digit, returnAction: nil, accessibilityLabel: nil
        )
        main = main.replacingKey(key)
        viewModel.currentDefinition = definition.replacingMode(ModeNames.main, with: main)
        viewModel.rebuildResolverChain()
        viewModel.feelLongPress(key, phase: .armed(keyFrame: frame, delay: 0.7))
        #expect(viewModel.feel.board.ring != nil)
    }
}

private extension KeyboardMode {
    /// A copy with `key` in place of the key that shares its id.
    func replacingKey(_ key: KeyDefinition) -> KeyboardMode {
        var keys = self.keys
        keys[key.id] = key
        return KeyboardMode(name: name, keys: keys, arrangements: arrangements, autoTransitions: autoTransitions)
    }
}
