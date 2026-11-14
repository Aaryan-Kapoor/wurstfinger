//
//  GestureBehaviourTests.swift
//  WurstfingerTests
//
//  What a hold and a circle do (issue #308 and the circle behaviours): the
//  settings and their one-time migration, how the compiled tables carry the
//  alternatives, and the typed result end to end through the touch engine —
//  including what the guide card previews and what the feel layer pops, which
//  must say what the release will type.
//

import Foundation
import Testing
@testable import WurstfingerKit
@testable import WurstfingerScenarioKit

// MARK: - Helpers

/// A view model on an in-memory store holding `settings`, wired to a mock
/// target, with `languageId` loaded.
@MainActor
private func makeBehaviourViewModel(
    languageId: String = "en_US",
    settings: [SettingsKey: Any] = [:]
) -> (KeyboardViewModel, MockTextTarget) {
    let defaults = InMemoryUserDefaults()
    for (key, value) in settings { defaults.set(value, forKey: key.rawValue) }
    let vm = KeyboardViewModel(userDefaults: defaults, shouldPersistSettings: false)
    let target = MockTextTarget()
    vm.bindTextInputTarget(target)
    vm.loadDefinition(for: languageId)
    return (vm, target)
}

@MainActor
private func typed(_ target: MockTextTarget) -> [String] {
    target.events.compactMap {
        if case let .insertText(text) = $0 { text } else { nil }
    }
}

// MARK: - Long-press behaviour: setting and migration

struct LongPressMigrationTests {
    /// The strings below are spelled out on purpose: they are what is on
    /// disk, and a renamed case must not move them.
    private let legacyKey = "longPressNumbersEnabled"
    private let pickerKey = "longPressBehaviour"

    /// The keyboard migrates on its own at load, so a user who updates and
    /// types before opening the app keeps the setting written, not inferred.
    @MainActor @Test func theKeyboardMigratesWhenItLoads() {
        let store = InMemoryUserDefaults()
        store.set(true, forKey: legacyKey)
        _ = KeyboardViewModel(userDefaults: store, shouldPersistSettings: true)
        #expect(store.string(forKey: pickerKey) == "digits")
    }

    /// Previews and screenshots never write to the store.
    @MainActor @Test func aNonPersistingViewModelLeavesTheStoreAlone() {
        let store = InMemoryUserDefaults()
        store.set(true, forKey: legacyKey)
        let viewModel = KeyboardViewModel(userDefaults: store, shouldPersistSettings: false)
        #expect(store.object(forKey: pickerKey) == nil)
        #expect(viewModel.typingBehavior.longPress == .digits, "the legacy value still applies")
    }

    @Test func anOldTrueBecomesDigits() {
        let store = InMemoryUserDefaults()
        store.set(true, forKey: legacyKey)
        LongPressType.migrateLegacyIfNeeded(in: store)
        #expect(store.string(forKey: pickerKey) == "digits")
        #expect(LongPressType.load(from: store) == .digits)
    }

    @Test func anOldFalseBecomesOff() {
        let store = InMemoryUserDefaults()
        store.set(false, forKey: legacyKey)
        LongPressType.migrateLegacyIfNeeded(in: store)
        #expect(store.string(forKey: pickerKey) == "off")
        #expect(LongPressType.load(from: store) == .off)
    }

    @Test func aStoreThatNeverHeldTheSwitchIsLeftAlone() {
        let store = InMemoryUserDefaults()
        LongPressType.migrateLegacyIfNeeded(in: store)
        #expect(store.object(forKey: pickerKey) == nil)
        #expect(LongPressType.load(from: store) == .off)
    }

    @Test func theMigrationRunsOnce() {
        // The user moves on to Capitals; the old switch is still `true` in the
        // store (kept for downgrade). Neither another migration nor a load may
        // bring Digits back.
        let store = InMemoryUserDefaults()
        store.set(true, forKey: legacyKey)
        LongPressType.migrateLegacyIfNeeded(in: store)
        store.set("capitals", forKey: pickerKey)

        LongPressType.migrateLegacyIfNeeded(in: store)
        #expect(store.string(forKey: pickerKey) == "capitals")
        #expect(LongPressType.load(from: store) == .capitals)
    }

    @Test func theLegacyValueStaysForDowngradeSafety() {
        let store = InMemoryUserDefaults()
        store.set(true, forKey: legacyKey)
        LongPressType.migrateLegacyIfNeeded(in: store)
        #expect(store.object(forKey: legacyKey) as? Bool == true)
    }

    @Test func aLoadBeforeTheMigrationReadsTheLegacySwitch() {
        // A store the migration has not reached (a read-only context): the
        // behaviour is already the one the old switch encoded.
        let store = InMemoryUserDefaults()
        store.set(true, forKey: legacyKey)
        #expect(LongPressType.load(from: store) == .digits)
        #expect(store.object(forKey: pickerKey) == nil, "loading never writes")
    }

    @Test func anUnknownStoredValueFallsBackToTheLegacySwitchThenOff() {
        let store = InMemoryUserDefaults()
        store.set("sideways", forKey: pickerKey)
        #expect(LongPressType.load(from: store) == .off)
        store.set(true, forKey: legacyKey)
        #expect(LongPressType.load(from: store) == .digits)
    }

    @Test func offIsTheDefaultAndTheOnlyDisabledChoice() {
        #expect(LongPressType.default == .off)
        #expect(LongPressType.allCases.filter { !$0.isEnabled } == [.off])
    }

    @Test func theViewModelMigratesNothingButReadsTheSwitch() {
        // `KeyboardViewModel` snapshots the choice from the store at init.
        let store = InMemoryUserDefaults()
        store.set(true, forKey: legacyKey)
        let typing = TypingBehavior.load(from: store)
        #expect(typing.longPress == .digits)
    }
}

// MARK: - Circle behaviours: setting

struct CircleBehaviourSettingTests {
    @Test func bothDirectionsDefaultToUppercase() {
        let typing = TypingBehavior.load(from: InMemoryUserDefaults())
        #expect(typing.clockwiseCircle == .uppercase)
        #expect(typing.counterclockwiseCircle == .uppercase)
    }

    @Test func storedChoicesApplyWhileExpertModeIsOn() {
        let store = InMemoryUserDefaults()
        store.set(true, forKey: SettingsKey.expertModeEnabled.rawValue)
        store.set("uppercase", forKey: "clockwiseCircleBehaviour")
        store.set("digit", forKey: "counterclockwiseCircleBehaviour")
        let typing = TypingBehavior.load(from: store)
        #expect(typing.clockwiseCircle == .uppercase)
        #expect(typing.counterclockwiseCircle == .digit)

        store.set("uppercaseWord", forKey: "clockwiseCircleBehaviour")
        #expect(TypingBehavior.load(from: store).clockwiseCircle == .uppercaseWord)
    }

    @Test func theChoicesAreKeptButIgnoredWhileExpertModeIsOff() {
        let store = InMemoryUserDefaults()
        store.set("digit", forKey: "clockwiseCircleBehaviour")
        #expect(TypingBehavior.load(from: store).clockwiseCircle == .uppercase)
        #expect(store.string(forKey: "clockwiseCircleBehaviour") == "digit")

        store.set(true, forKey: SettingsKey.expertModeEnabled.rawValue)
        #expect(TypingBehavior.load(from: store).clockwiseCircle == .digit)
    }

    @Test func anUnknownValueFallsBackToUppercase() {
        let store = InMemoryUserDefaults()
        store.set(true, forKey: SettingsKey.expertModeEnabled.rawValue)
        store.set("confetti", forKey: "clockwiseCircleBehaviour")
        #expect(TypingBehavior.load(from: store).clockwiseCircle == .uppercase)
    }
}

// MARK: - Compiled tables

@MainActor
struct BehaviourTableTests {
    @Test func everyLetterSlotOfEnglishHasACapitalAndADigit() throws {
        let definition = try #require(KeyboardRegistry.load(id: "en_US"))
        let compiled = CompiledDefinition(definition)
        let main = try #require(compiled.mode(ModeNames.main))
        for slot in GridSlot.allSlots.flatMap(\.self) {
            let index = try #require(main.slot(for: slot))
            #expect(main.longPressBinding(slot: index, type: .capitals) != nil, "\(slot)")
            #expect(main.longPressBinding(slot: index, type: .digits) != nil, "\(slot)")
            #expect(main.circular(slot: index, clockwise: true, type: .digit) != main.circular(slot: index, clockwise: true, type: .uppercase), "\(slot)")
        }
    }

    @Test func theCapitalIsTheShiftedModesOwnTapBinding() throws {
        // Not an uppercasing done by the resolver: the layout's shifted mode
        // is the authority, so its locale rules and overrides are what a hold
        // types.
        for id in ["en_US", "de_DE", "fr_FR", "pl_PL", "ru_RU", "el_GR", "uk_UA", "vi_VN"] {
            let definition = try #require(KeyboardRegistry.load(id: id), "\(id)")
            let compiled = CompiledDefinition(definition)
            let main = try #require(compiled.mode(ModeNames.main))
            let shifted = try #require(definition.mode(ModeNames.shifted))
            for slot in GridSlot.allSlots.flatMap(\.self) {
                let index = try #require(main.slot(for: slot))
                let held = main.longPressBinding(slot: index, type: .capitals)
                #expect(held == shifted.key(for: slot)?.bindings[.tap], "\(id) \(slot)")
            }
        }
    }

    @Test func localeSpecificCasingComesFromTheShiftedMode() throws {
        // Turkish dotted i → İ and German ß → ẞ: a layout whose locale says so
        // gets the capital its shifted mode defines.
        for (letter, locale, capital) in [("i", "tr_TR", "İ"), ("ß", "de_DE", "ẞ")] {
            let key = KeyDefinition.letter("k", tap: letter)
            let main = KeyboardMode(name: ModeNames.main, keys: ["k": key], arrangements: [:], autoTransitions: [:])
            let shifted = main.generateShifted(locale: Locale(identifier: locale))
            let compiled = CompiledMode(
                mode: main, fallbackMode: nil, shiftedMode: shifted, locale: Locale(identifier: locale)
            )
            let slot = try #require(compiled.slot(for: "k"))
            #expect(compiled.longPressBinding(slot: slot, type: .capitals)?.action == .commitText(capital), "\(letter)")
        }
    }

    @Test func noCapitalWhereTheTapIsAlreadyOneOrIsNotALetter() throws {
        let definition = try #require(KeyboardRegistry.load(id: "en_US"))
        let compiled = CompiledDefinition(definition)
        // Shifted and caps lock: the tap is the capital, so a hold has nothing to add.
        for name in [ModeNames.shifted, ModeNames.capsLock] {
            let mode = try #require(compiled.mode(name))
            for slot in GridSlot.allSlots.flatMap(\.self) {
                let index = try #require(mode.slot(for: slot))
                #expect(mode.longPressBinding(slot: index, type: .capitals) == nil, "\(name) \(slot)")
            }
        }
        // Digits in the numeric mode and the utility keys are not letters.
        let numeric = try #require(compiled.mode(ModeNames.numeric))
        for slot in GridSlot.allSlots.flatMap(\.self) {
            let index = try #require(numeric.slot(for: slot))
            #expect(numeric.longPressBinding(slot: index, type: .capitals) == nil, "numeric \(slot)")
        }
        let main = try #require(compiled.mode(ModeNames.main))
        for slot in [UtilitySlot.return, UtilitySlot.delete, UtilitySlot.globe, UtilitySlot.symbols] {
            let index = try #require(main.slot(for: slot))
            #expect(main.longPressBinding(slot: index, type: .capitals) == nil, "\(slot)")
        }
    }

    @Test func theSpaceBarsZeroBelongsToDigitsOnly() throws {
        let definition = try #require(KeyboardRegistry.load(id: "en_US"))
        let main = try #require(CompiledDefinition(definition).mode(ModeNames.main))
        let space = try #require(main.slot(for: UtilitySlot.space))
        #expect(main.longPressBinding(slot: space, type: .digits)?.action == .commitText("0"))
        #expect(main.longPressBinding(slot: space, type: .capitals) == nil)
    }

    @Test func aCaselessScriptHasNoCapitals() throws {
        for id in ["ar", "he_IL", "th_TH", "ja_JP", "hi_IN"] {
            let definition = try #require(KeyboardRegistry.load(id: id), "\(id)")
            let main = try #require(CompiledDefinition(definition).mode(ModeNames.main))
            for slot in GridSlot.allSlots.flatMap(\.self) {
                let index = try #require(main.slot(for: slot))
                #expect(main.longPressBinding(slot: index, type: .capitals) == nil, "\(id) \(slot)")
            }
        }
    }

    @Test func aLayoutsOwnNonDigitHoldSurvivesCapitalsButADigitOneDoesNot() throws {
        func compile(_ binding: KeyBinding) throws -> (CompiledMode, Int) {
            var key = KeyDefinition.letter("k", tap: "a")
            key.bindings[.longPress] = binding
            let main = KeyboardMode(name: ModeNames.main, keys: ["k": key], arrangements: [:], autoTransitions: [:])
            let shifted = main.generateShifted(locale: Locale(identifier: "en_US"))
            let compiled = CompiledMode(mode: main, fallbackMode: nil, shiftedMode: shifted, locale: Locale(identifier: "en_US"))
            return (compiled, try #require(compiled.slot(for: "k")))
        }
        let symbol = KeyBinding(label: "@", action: .commitText("@"), category: nil, returnAction: nil, accessibilityLabel: nil)
        let (symbolMode, symbolSlot) = try compile(symbol)
        #expect(symbolMode.longPressBinding(slot: symbolSlot, type: .capitals)?.action == .commitText("@"))

        let digit = KeyBinding(label: "0", action: .commitText("0"), category: .digit, returnAction: nil, accessibilityLabel: nil)
        let (digitMode, digitSlot) = try compile(digit)
        #expect(digitMode.longPressBinding(slot: digitSlot, type: .capitals)?.action == .commitText("A"))
        #expect(digitMode.longPressBinding(slot: digitSlot, type: .digits)?.action == .commitText("0"))
    }

    @Test func offResolvesLikeDigitsBecauseOnlyTheTimerIsGated() throws {
        let definition = try #require(KeyboardRegistry.load(id: "en_US"))
        let main = try #require(CompiledDefinition(definition).mode(ModeNames.main))
        for index in main.keys.indices {
            #expect(main.longPressBinding(slot: index, type: .off) == main.longPressBinding(slot: index, type: .digits))
        }
    }

    @Test func circlesOnlyReconfigureTheLetterFallback() throws {
        // Everything a circle does *except* typing the key's capital is the
        // key's own declaration and ignores the setting: the clipboard key's
        // cut-all, the numeric mode's superscripts.
        for id in ["en_US", "de_DE", "ar", "ja_JP", "ko_KR"] {
            let definition = try #require(KeyboardRegistry.load(id: id), "\(id)")
            for (name, mode) in CompiledDefinition(definition).modes {
                for index in mode.keys.indices {
                    for clockwise in [true, false] {
                        let base = mode.circular(slot: index, clockwise: clockwise)
                        for type in CircleType.allCases {
                            let chosen = mode.circular(slot: index, clockwise: clockwise, type: type)
                            if case .commitUppercase = base { continue }
                            #expect(chosen == base, "\(id) \(name) \(mode.keys[index].id) \(type)")
                        }
                        #expect(mode.circular(slot: index, clockwise: clockwise, type: .uppercase) == base)
                    }
                }
            }
        }
    }

    @Test func theDigitCircleIsTheGhostDigitAndWordCaseNeedsNoBinding() throws {
        let definition = try #require(KeyboardRegistry.load(id: "en_US"))
        let main = try #require(CompiledDefinition(definition).mode(ModeNames.main))
        let topLeft = try #require(main.slot(for: GridSlot.topLeft))
        guard case let .binding(index) = main.circular(slot: topLeft, clockwise: true, type: .digit) else {
            Issue.record("a digit circle is a binding")
            return
        }
        #expect(main.binding(at: index).action == .commitText("1"))
        #expect(main.circular(slot: topLeft, clockwise: false, type: .uppercaseWord) == .capitalizeWord)
    }

    @Test func theTablesDoNotDependOnTheSettings() throws {
        // The compiled signature names the language and numpad style only: if a
        // setting could change the tables, a stale cache would type the old
        // behaviour. Changing the settings and reloading must change what is
        // typed (the snapshot) without touching the tables.
        let (vm, _) = makeBehaviourViewModel()
        let before = vm.compiledDefinition?.mode(ModeNames.main)?.table

        vm.sharedDefaults.set("capitals", forKey: SettingsKey.longPressBehaviour.rawValue)
        vm.sharedDefaults.set(true, forKey: SettingsKey.expertModeEnabled.rawValue)
        vm.sharedDefaults.set("digit", forKey: SettingsKey.clockwiseCircleBehaviour.rawValue)
        vm.reloadSettings()

        #expect(vm.typingBehavior.longPress == .capitals)
        #expect(vm.typingBehavior.clockwiseCircle == .digit)
        #expect(vm.compiledDefinition?.mode(ModeNames.main)?.table == before)
    }
}

// MARK: - The view model

@MainActor
@Suite(.serialized)
struct CapitalsLongPressViewModelTests {
    @Test func holdingALetterTypesItsCapital() {
        let (vm, target) = makeBehaviourViewModel(settings: [.longPressBehaviour: "capitals"])
        #expect(vm.handleGesture(.longPress, keyId: GridSlot.topLeft, isReturn: false))
        #expect(typed(target) == ["A"])
        #expect(vm.activeModeName == ModeNames.main)
    }

    @Test func everyLetterSlotTypesItsOwnCapital() throws {
        for slot in GridSlot.allSlots.flatMap(\.self) {
            let (vm, target) = makeBehaviourViewModel(settings: [.longPressBehaviour: "capitals"])
            let tap = try #require(vm.activeModeFromDefinition?.key(for: slot)?.bindings[.tap])
            guard case let .commitText(letter) = tap.action else {
                Issue.record("\(slot) has no letter")
                continue
            }
            vm.handleGesture(.longPress, keyId: slot, isReturn: false)
            #expect(typed(target) == [letter.uppercased()], "\(slot)")
        }
    }

    @Test func germanEszettHoldsToTheLayoutsCapital() throws {
        // The key carrying ß in de_DE is a swipe, not a tap; the tap keys are
        // letters. What matters is that the capital is whatever the shifted
        // mode types, for every slot.
        let (vm, target) = makeBehaviourViewModel(languageId: "de_DE", settings: [.longPressBehaviour: "capitals"])
        let shifted = try #require(vm.currentDefinition?.mode(ModeNames.shifted))
        for slot in GridSlot.allSlots.flatMap(\.self) {
            target.events.removeAll()
            vm.handleGesture(.longPress, keyId: slot, isReturn: false)
            guard case let .commitText(capital)? = shifted.key(for: slot)?.bindings[.tap]?.action else { continue }
            #expect(typed(target) == [capital], "\(slot)")
        }
    }

    @Test func aHoldOnNonLettersIsUnhandledSoTheTapSurvives() {
        let (vm, target) = makeBehaviourViewModel(settings: [.longPressBehaviour: "capitals"])
        for key in [UtilitySlot.return, UtilitySlot.delete, UtilitySlot.globe, UtilitySlot.symbols, UtilitySlot.space] {
            #expect(!vm.handleGesture(.longPress, keyId: key, isReturn: false), "\(key)")
        }
        #expect(target.events.isEmpty)
    }

    @Test func aHoldInTheNumericModeTypesNothingUnderCapitals() {
        let (vm, target) = makeBehaviourViewModel(settings: [.longPressBehaviour: "capitals"])
        vm.handleGesture(.tap, keyId: UtilitySlot.symbols, isReturn: false)
        #expect(vm.activeModeName == ModeNames.numeric)
        #expect(!vm.handleGesture(.longPress, keyId: GridSlot.topLeft, isReturn: false))
        #expect(target.events.isEmpty)
    }

    @Test func aHoldInTheShiftedModeIsLeftToTheTap() {
        let (vm, target) = makeBehaviourViewModel(settings: [.longPressBehaviour: "capitals"])
        vm.handleGesture(.swipeUp, keyId: GridSlot.midRight, isReturn: false)
        #expect(vm.activeModeName == ModeNames.shifted)
        #expect(!vm.handleGesture(.longPress, keyId: GridSlot.topLeft, isReturn: false))
        #expect(target.events.isEmpty)
    }

    @Test func aCaselessLayoutHasNothingToCapitalize() {
        let (vm, target) = makeBehaviourViewModel(languageId: "ar", settings: [.longPressBehaviour: "capitals"])
        #expect(!vm.handleGesture(.longPress, keyId: GridSlot.center, isReturn: false))
        #expect(target.events.isEmpty)
    }

    @Test func digitsStillTypeTheDigitAndSpaceStillTypesZero() {
        let (vm, target) = makeBehaviourViewModel(settings: [.longPressBehaviour: "digits"])
        vm.handleGesture(.longPress, keyId: GridSlot.topLeft, isReturn: false)
        vm.handleGesture(.longPress, keyId: UtilitySlot.space, isReturn: false)
        #expect(typed(target) == ["1", "0"])
    }

    @Test func theChoiceFollowsAReloadWithoutRecompiling() {
        let (vm, target) = makeBehaviourViewModel(settings: [.longPressBehaviour: "digits"])
        vm.handleGesture(.longPress, keyId: GridSlot.topLeft, isReturn: false)
        vm.sharedDefaults.set("capitals", forKey: SettingsKey.longPressBehaviour.rawValue)
        vm.reloadSettings()
        vm.handleGesture(.longPress, keyId: GridSlot.topLeft, isReturn: false)
        #expect(typed(target) == ["1", "A"])
    }

    @Test func theGuideAndTheFeelLayerPreviewTheCapital() {
        let (vm, _) = makeBehaviourViewModel(settings: [.longPressBehaviour: "capitals"])
        #expect(vm.previewLabel(for: .longPress, keyId: GridSlot.topLeft, isReturn: false) == "A")
        #expect(vm.previewLabel(for: .longPress, keyId: UtilitySlot.return, isReturn: false) == nil)

        let (digits, _) = makeBehaviourViewModel(settings: [.longPressBehaviour: "digits"])
        #expect(digits.previewLabel(for: .longPress, keyId: GridSlot.topLeft, isReturn: false) == "1")
    }

    @Test func aHoldIsAFeltLongPressWithThePopOfTheCapital() {
        // The feel layer decides from the same resolution: a hold that would
        // type a capital commits as a long press, popping the capital.
        let (vm, _) = makeBehaviourViewModel(settings: [.longPressBehaviour: "capitals"])
        let commit = vm.commitFeel(
            for: GestureClassification(gesture: .longPress, isReturn: false), keyId: GridSlot.topLeft
        )
        #expect(commit?.commitType == .longPress)
        #expect(commit?.popText == "A")
    }
}

// MARK: - Circles in the view model

@MainActor
@Suite(.serialized)
struct CircleBehaviourViewModelTests {
    private func circle(_ vm: KeyboardViewModel, clockwise: Bool, on key: String = GridSlot.topLeft) {
        vm.handleGesture(clockwise ? .circularClockwise : .circularCounterclockwise, keyId: key, isReturn: false)
    }

    @Test func untouchedCirclesTypeTheCapital() {
        let (vm, target) = makeBehaviourViewModel()
        circle(vm, clockwise: true)
        circle(vm, clockwise: false)
        #expect(typed(target) == ["A", "A"])
    }

    @Test func eachDirectionFollowsItsOwnChoice() {
        let (vm, target) = makeBehaviourViewModel(settings: [
            .expertModeEnabled: true,
            .clockwiseCircleBehaviour: "uppercase",
            .counterclockwiseCircleBehaviour: "digit",
        ])
        circle(vm, clockwise: true)
        circle(vm, clockwise: false)
        #expect(typed(target) == ["A", "1"])
    }

    @Test func aDigitCircleTypesTheNativeDigitOfTheLayout() {
        let (vm, target) = makeBehaviourViewModel(languageId: "ar", settings: [
            .expertModeEnabled: true, .clockwiseCircleBehaviour: "digit",
        ])
        circle(vm, clockwise: true)
        #expect(typed(target) == ["١"])
    }

    @Test func aDigitCircleFollowsTheClassicNumpad() {
        let defaults = InMemoryUserDefaults()
        defaults.set(NumpadType.classic.rawValue, forKey: SettingsKey.numpadStyle.rawValue)
        defaults.set(true, forKey: SettingsKey.expertModeEnabled.rawValue)
        defaults.set("digit", forKey: SettingsKey.clockwiseCircleBehaviour.rawValue)
        let vm = KeyboardViewModel(userDefaults: defaults, shouldPersistSettings: false)
        let target = MockTextTarget()
        vm.bindTextInputTarget(target)
        vm.loadDefinition(for: "en_US")
        circle(vm, clockwise: true)
        #expect(typed(target) == ["7"])
    }

    @Test func anUppercaseWordCircleCapitalizesTheWordBeforeTheCursor() {
        let (vm, target) = makeBehaviourViewModel(settings: [
            .expertModeEnabled: true, .counterclockwiseCircleBehaviour: "uppercaseWord",
        ])
        target.documentContextBeforeInput = "say hello"
        circle(vm, clockwise: false)
        // The word is retyped in capitals; the circle types no letter of its own.
        #expect(target.events.filter { $0 == .deleteBackward }.count == 5)
        #expect(typed(target) == ["HELLO"])
    }

    @Test func aDigitCircleInShiftedModeStillTypesTheDigit() {
        let (vm, target) = makeBehaviourViewModel(settings: [
            .expertModeEnabled: true, .clockwiseCircleBehaviour: "digit",
        ])
        vm.handleGesture(.swipeUp, keyId: GridSlot.midRight, isReturn: false)
        #expect(vm.activeModeName == ModeNames.shifted)
        circle(vm, clockwise: true)
        #expect(typed(target).last == "1")
    }

    @Test func aKeyWithItsOwnCircleKeepsItWhateverIsChosen() throws {
        // The clipboard key's circle is cut-all; it does not become a digit.
        let (vm, _) = makeBehaviourViewModel(settings: [
            .expertModeEnabled: true,
            .clockwiseCircleBehaviour: "digit", .counterclockwiseCircleBehaviour: "uppercaseWord",
        ])
        let main = try #require(vm.compiledDefinition?.mode(ModeNames.main))
        let symbols = try #require(main.slot(for: UtilitySlot.symbols))
        #expect(vm.resolvedCircle(in: main, slot: symbols, gesture: .circularClockwise)
            == main.circular(slot: symbols, clockwise: true))
        #expect(vm.resolvedCircle(in: main, slot: symbols, gesture: .circularCounterclockwise)
            == main.circular(slot: symbols, clockwise: false))
    }

    @Test func offExpertModeIgnoresTheStoredChoices() {
        let (vm, target) = makeBehaviourViewModel(settings: [.clockwiseCircleBehaviour: "digit"])
        circle(vm, clockwise: true)
        #expect(typed(target) == ["A"])
    }

    @Test func theGuidePreviewsWhatTheCircleWillType() {
        let (vm, _) = makeBehaviourViewModel(settings: [
            .expertModeEnabled: true,
            .clockwiseCircleBehaviour: "digit", .counterclockwiseCircleBehaviour: "uppercaseWord",
        ])
        #expect(vm.previewLabel(for: .circularClockwise, keyId: GridSlot.topLeft, isReturn: false) == "1")
        #expect(vm.previewLabel(for: .circularCounterclockwise, keyId: GridSlot.topLeft, isReturn: false) == "Aa")

        let (stock, _) = makeBehaviourViewModel()
        #expect(stock.previewLabel(for: .circularClockwise, keyId: GridSlot.topLeft, isReturn: false) == "A")
    }

    @Test func theFeelLayerAgreesWithThePreview() {
        let (vm, _) = makeBehaviourViewModel(settings: [
            .expertModeEnabled: true, .clockwiseCircleBehaviour: "digit",
        ])
        let commit = vm.commitFeel(
            for: GestureClassification(gesture: .circularClockwise, isReturn: false), keyId: GridSlot.topLeft
        )
        #expect(commit?.commitType == .circle)
        #expect(commit?.popText == "1")
    }
}

// MARK: - End to end through the touch engine

@MainActor
@Suite(.serialized)
struct BehaviourScenarioTests {
    @Test func aHeldLetterTypesItsCapitalAndTheReleaseTypesNothingMore() {
        let scenario = KeyboardScenario(
            language: "en_US", autoCapitalize: false,
            settings: [.longPressBehaviour: LongPressType.capitals.rawValue]
        )
        let outcome = scenario.longPress(GridSlot.topLeft)
        #expect(outcome.firedLongPress)
        #expect(scenario.text == "A")
        #expect(scenario.mode == ModeNames.main)
    }

    @Test func aHoldOnAKeyWithNoCapitalIsATap() {
        let scenario = KeyboardScenario(
            language: "en_US", autoCapitalize: false,
            settings: [.longPressBehaviour: LongPressType.capitals.rawValue]
        )
        let outcome = scenario.longPress(UtilitySlot.space)
        #expect(!outcome.firedLongPress)
        #expect(scenario.text == " ")
    }

    @Test func offStillMakesAHoldATap() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        let outcome = scenario.longPress(GridSlot.topLeft)
        #expect(!outcome.firedLongPress)
        #expect(scenario.text == "a")
    }

    @Test func theOldSwitchStillArmsDigitsOnAnUnmigratedStore() {
        let scenario = KeyboardScenario(
            language: "en_US", autoCapitalize: false, settings: [.isLongPressDigitEnabled: true]
        )
        #expect(scenario.longPress(GridSlot.topLeft).firedLongPress)
        #expect(scenario.text == "1")
    }

    @Test func circlesOnTheEngineFollowTheirDirectionsChoice() {
        let scenario = KeyboardScenario(
            language: "en_US", autoCapitalize: false,
            settings: [
                .expertModeEnabled: true,
                .clockwiseCircleBehaviour: CircleType.uppercase.rawValue,
                .counterclockwiseCircleBehaviour: CircleType.digit.rawValue,
            ]
        )
        #expect(scenario.circle(GridSlot.topLeft, clockwise: true).gesture == .circularClockwise)
        #expect(scenario.text == "A")
        #expect(scenario.circle(GridSlot.topLeft, clockwise: false).gesture == .circularCounterclockwise)
        #expect(scenario.text == "A1")
    }

    @Test func capitalsHoldsAreFeltAsLongPresses() throws {
        // The haptic phases fire for Capitals as for Digits: the key arms a
        // ring, the fire pops the capital.
        let scenario = KeyboardScenario(
            autoCapitalize: false, settings: [.longPressBehaviour: LongPressType.capitals.rawValue]
        )
        let viewModel = scenario.viewModel
        viewModel.configureTouchEngine(containerWidth: scenario.containerWidth, isLongPressEnabled: true)
        let engine = viewModel.touchEngine
        let frame = try #require(engine.hitMap.key(withId: GridSlot.center)?.frame)
        engine.began(1, at: CGPoint(x: frame.midX, y: frame.midY), time: 0)
        #expect(viewModel.feel.board.ring?.keyId == GridSlot.center)
        engine.fireLongPressTimer(for: 1)
        #expect(viewModel.feel.board.ring?.hasFired == true)
        #expect(viewModel.feel.board.pops.last?.text.first?.isUppercase == true)
        engine.ended(1, at: CGPoint(x: frame.midX, y: frame.midY), time: 0.8)
    }

    @Test func keysWithoutACapitalGetNoRing() throws {
        let scenario = KeyboardScenario(
            autoCapitalize: false, settings: [.longPressBehaviour: LongPressType.capitals.rawValue]
        )
        let viewModel = scenario.viewModel
        viewModel.configureTouchEngine(containerWidth: scenario.containerWidth, isLongPressEnabled: true)
        let engine = viewModel.touchEngine
        let frame = try #require(engine.hitMap.key(withId: UtilitySlot.space)?.frame)
        engine.began(1, at: CGPoint(x: frame.midX, y: frame.midY), time: 0)
        #expect(viewModel.feel.board.ring == nil)
        engine.cancelAll()
    }
}
