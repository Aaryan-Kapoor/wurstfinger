//
//  EmojiModeTests.swift
//  WurstfingerKitTests
//
//  The emoji mode: the feeling map's data, how it is entered and left, how it
//  types (tap, flick, return swipe, circle, hold), the recent key, and what it
//  offers VoiceOver. docs/emoji-mode.md is the design these pin.
//

import Foundation
import SwiftUI
import Testing
@testable import WurstfingerKit
@testable import WurstfingerScenarioKit

// MARK: - The map

struct EmojiFeelingMapTests {
    private var allEmoji: [String] {
        EmojiLayouts.families.flatMap { family in
            [family.main, family.returns, family.more].flatMap { $0.split(separator: " ").map(String.init) }
        }
    }

    @Test func nineFamiliesFillTheNineGridSlotsOnce() {
        let slots = EmojiLayouts.families.map(\.slot)
        #expect(slots == GridSlot.allSlots.flatMap(\.self), "families are listed in grid order")
        #expect(Set(EmojiLayouts.families.map(\.id)).count == 9)
    }

    /// The compass: left sour, right sweet, top loud, bottom quiet. Moving a
    /// family is a design change, so it fails here first.
    @Test func theFamiliesSitWhereTheCompassPutsThem() {
        let ids = EmojiLayouts.families.map(\.id)
        #expect(ids == [
            "anger", "surprise", "joy",
            "worry", "playful", "love",
            "sadness", "neutral", "approval",
        ])
    }

    @Test func everyFamilyHasTheCellsItsKeyNeeds() {
        for family in EmojiLayouts.families {
            #expect(family.main.split(separator: " ").count == 9, "\(family.id) first page")
            #expect(family.returns.split(separator: " ").count == 8, "\(family.id) return swipes")
            #expect(family.more.split(separator: " ").count == 9, "\(family.id) second page")
        }
    }

    @Test func everyMemberIsOneEmoji() {
        for emoji in allEmoji {
            #expect(EmojiText.isSingleEmoji(emoji), "\(emoji) is not one emoji grapheme cluster")
            #expect(emoji.unicodeScalars.first?.properties.isEmoji == true, "\(emoji)")
        }
    }

    @Test func noEmojiIsOnTheMapTwice() {
        let duplicates = Dictionary(grouping: allEmoji, by: \.self).filter { $0.value.count > 1 }.keys.sorted()
        #expect(duplicates.isEmpty, "twice on the map: \(duplicates)")
        #expect(allEmoji.count == 234)
    }

    /// iOS 17 draws Emoji 15.0 and earlier; Emoji 15.1 (iOS 17.4) and 16.0
    /// (iOS 18.4) would show as a missing glyph or as two emoji. The map was
    /// checked against emoji-test.txt of 15.0 when it was written; this keeps a
    /// later edit from slipping a newer one in. Only the newer emoji are
    /// listed, so the list can stay short.
    @Test func noMemberIsNewerThanEmoji15() {
        let newer: Set<String> = [
            // 15.1: new sequences
            "🙂‍↔️", "🙂‍↕️", "🐦‍🔥", "🍋‍🟩", "🍄‍🟫", "⛓️‍💥", "🧑‍🧑‍🧒", "🧑‍🧒", "🧑‍🧒‍🧒",
            // 16.0: new emoji
            "🫩", "🫆", "🪾", "🫜", "🪉", "🪏", "🫟", "🫈", "🫛", "🫚",
        ]
        for emoji in allEmoji {
            #expect(!newer.contains(emoji), "\(emoji) needs a newer iOS than 17")
        }
        // The Emoji 15.0 additions the map does use render on iOS 16.4 and later.
        #expect(allEmoji.contains("🫨"))
    }

    @Test func theTapIsTheCentreCell() throws {
        for family in EmojiLayouts.families {
            let cells = family.main.split(separator: " ").map(String.init)
            #expect(EmojiLayouts.gridGestures[4] == .tap)
            let main = try #require(EmojiLayouts.modes()[ModeNames.emoji])
            #expect(main.keys[family.slot]?.bindings[.tap]?.label == cells[4], "\(family.id)")
        }
    }
}

// MARK: - The mode in every layout

@MainActor
struct EmojiModeDefinitionTests {
    private func definitions() throws -> [KeyboardDefinition] {
        let all = KeyboardRegistry.available.compactMap { KeyboardRegistry.load(id: $0.id) }
        try #require(all.count == KeyboardRegistry.available.count)
        return all
    }

    @Test func everyLayoutCarriesBothPagesAndValidates() throws {
        for definition in try definitions() {
            #expect(definition.validate().isEmpty, "\(definition.id): \(definition.validate())")
            for page in [ModeNames.emoji, ModeNames.emojiMore] {
                let mode = try #require(definition.mode(page), "\(definition.id) has no \(page)")
                #expect(mode.name == page)
                #expect(mode.autoTransitions.isEmpty, "an emoji page stays until it is left")
            }
        }
    }

    /// An unbound gesture falls through to the numeric mode's ghost keys and
    /// would type a digit or a symbol among the emoji.
    @Test func everyGestureOfEveryEmojiKeyIsBoundToAnEmoji() throws {
        let definition = try #require(KeyboardRegistry.load(id: "en_US"))
        let compiled = CompiledDefinition(definition)
        for page in [ModeNames.emoji, ModeNames.emojiMore] {
            let mode = try #require(definition.mode(page))
            let table = try #require(compiled.mode(page))
            let keys = GridSlot.allSlots.flatMap(\.self) + [GridSlot.recent]
            for keyId in keys {
                let slot = try #require(table.slot(for: keyId), "\(page)/\(keyId)")
                for gesture in GestureType.allCases where !gesture.isCircular {
                    let binding = try #require(
                        table.binding(slot: slot, gesture: gesture, isReturn: false),
                        "\(page)/\(keyId) \(gesture) is unbound"
                    )
                    guard case let .commitText(text) = binding.action else {
                        Issue.record("\(page)/\(keyId) \(gesture) is not text"); continue
                    }
                    #expect(EmojiText.isSingleEmoji(text), "\(page)/\(keyId) \(gesture) types \(text)")
                }
                // The circles turn the page and nothing else.
                for clockwise in [true, false] {
                    guard case let .binding(index) = table.circular(slot: slot, clockwise: clockwise) else {
                        Issue.record("\(page)/\(keyId) circle is not a binding"); continue
                    }
                    let target = page == ModeNames.emoji ? ModeNames.emojiMore : ModeNames.emoji
                    #expect(table.binding(at: index).action == .switchMode(target))
                }
                _ = mode
            }
        }
    }

    /// Every binding commits exactly one grapheme cluster, so one delete
    /// removes what one gesture typed.
    @Test func everyBindingCommitsOneGraphemeCluster() throws {
        for definition in try definitions() {
            for page in [ModeNames.emoji, ModeNames.emojiMore] {
                for (keyId, key) in try #require(definition.mode(page)).keys {
                    for (gesture, binding) in key.bindings {
                        for action in [binding.action, binding.returnAction].compactMap(\.self) {
                            guard case let .commitText(text) = action, keyId != UtilitySlot.space else { continue }
                            if gesture == .longPress && keyId == UtilitySlot.space { continue }
                            #expect(text.count == 1, "\(definition.id)/\(page)/\(keyId) \(gesture): \(text)")
                        }
                    }
                }
            }
        }
    }

    @Test func theUtilityColumnOffersTheWayBackDeleteSpaceAndReturn() throws {
        let definition = try #require(KeyboardRegistry.load(id: "en_US"))
        for page in [ModeNames.emoji, ModeNames.emojiMore] {
            let mode = try #require(definition.mode(page))
            #expect(mode.keys[UtilitySlot.symbols]?.bindings[.tap]?.action == .switchMode(ModeNames.main))
            #expect(mode.keys[UtilitySlot.delete]?.bindings[.tap]?.action == .deleteBackward)
            #expect(mode.keys[UtilitySlot.space]?.bindings[.tap]?.action == .space)
            #expect(mode.keys[UtilitySlot.return]?.bindings[.tap]?.action == .newline)
            #expect(mode.keys[UtilitySlot.globe]?.bindings[.swipeLeft]?.action == .advanceToNextInputMode)
        }
        let second = try #require(definition.mode(ModeNames.emojiMore))
        #expect(second.keys[UtilitySlot.symbols]?.bindings[.tap]?.label == "abc\u{00B2}", "page two says so")
    }

    @Test func aLayoutWithItsOwnBackLabelKeepsItOnTheWayBack() throws {
        let hebrew = try #require(KeyboardRegistry.available.first { $0.id.hasPrefix("he") })
        let definition = try #require(KeyboardRegistry.load(id: hebrew.id))
        let label = definition.numericBackToAlphaLabel
        #expect(definition.mode(ModeNames.emoji)?.keys[UtilitySlot.symbols]?.bindings[.tap]?.label == label)
    }

    @Test func theGestureThatEntersIsFreeOnTheSymbolsKeyOfEveryLayout() throws {
        for definition in try definitions() {
            for name in [ModeNames.main, ModeNames.shifted, ModeNames.capsLock] {
                guard let mode = definition.mode(name) else { continue }
                let bindings = try #require(mode.keys[UtilitySlot.symbols]).bindings
                #expect(bindings[.swipeDownRight]?.action == .switchMode(ModeNames.emoji), "\(definition.id)/\(name)")
                // Down-right is the only gesture of the key that goes there.
                let entries = bindings.filter { $0.value.action == .switchMode(ModeNames.emoji) }
                #expect(entries.count == 1)
            }
        }
    }

    @Test func theNumpadColumnLeavesTheEmojiPagesAlone() throws {
        let definition = try #require(KeyboardRegistry.load(id: "en_US")).addingNumpadColumn(style: .phone)
        for page in [ModeNames.emoji, ModeNames.emojiMore] {
            let mode = try #require(definition.mode(page))
            #expect(NumpadColumn.keyIds.allSatisfy { mode.keys[$0] == nil })
            #expect(mode.keys[GridSlot.recent] != nil)
        }
    }

    @Test func aCustomLayoutGetsTheEmojiPagesToo() {
        let layout = makeCustomLayout()
        let definition = layout.makeDefinition(basedOn: nil)
        #expect(definition.mode(ModeNames.emoji) != nil)
        #expect(definition.mode(ModeNames.main)?.keys[UtilitySlot.symbols]?.bindings[.swipeDownRight]?.action
            == .switchMode(ModeNames.emoji))
    }
}

// MARK: - Typing

@MainActor
struct EmojiModeTypingTests {
    private func enter(_ scenario: KeyboardScenario) {
        scenario.swipe(UtilitySlot.symbols, .swipeDownRight)
    }

    @Test func aSwipeDownRightOnTheSymbolsKeyEntersAndTheKeyLeaves() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        enter(scenario)
        #expect(scenario.mode == ModeNames.emoji)
        scenario.tap(UtilitySlot.symbols)
        #expect(scenario.mode == ModeNames.main)
        #expect(scenario.text.isEmpty)
    }

    @Test func itIsEnteredFromTheShiftedAndCapsLockModesToo() {
        let scenario = KeyboardScenario(language: "de_DE", autoCapitalize: true)
        #expect(scenario.mode == ModeNames.shifted, "a sentence start comes up shifted")
        enter(scenario)
        #expect(scenario.mode == ModeNames.emoji)
    }

    @Test func tapTypesTheFamilysPrototypeAndFlicksTypeTheNuances() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        enter(scenario)
        scenario.tap(GridSlot.topRight)
        scenario.swipe(GridSlot.topRight, .swipeUp)
        scenario.swipe(GridSlot.topRight, .swipeDown)
        scenario.swipe(GridSlot.topRight, .swipeRight)
        #expect(scenario.text == "😂🤣😊🎉")
        #expect(scenario.mode == ModeNames.emoji, "the mode stays up for the next emoji")
    }

    @Test func aReturnSwipeTypesTheSecondLevelVariant() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        enter(scenario)
        scenario.returnSwipe(GridSlot.topRight, .swipeUp)
        scenario.returnSwipe(GridSlot.midRight, .swipeUp)
        #expect(scenario.text == "🥳❤️‍🔥")
        scenario.target.reset()
        scenario.swipe(GridSlot.midRight, .swipeUp)
        #expect(scenario.text == "😘", "the plain flick is the first level")
    }

    @Test func aCircleTurnsThePageAndAnotherTurnsItBack() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        enter(scenario)
        scenario.circle(GridSlot.topRight)
        #expect(scenario.mode == ModeNames.emojiMore)
        scenario.tap(GridSlot.topRight)
        #expect(scenario.text == "😀", "page two's prototype of the joy family")
        scenario.circle(GridSlot.center, clockwise: false)
        #expect(scenario.mode == ModeNames.emoji)
        #expect(scenario.text == "😀", "a page turn types nothing")
    }

    @Test func theLettersKeyLeavesFromPageTwoToo() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        enter(scenario)
        scenario.circle(GridSlot.center)
        scenario.tap(UtilitySlot.symbols)
        #expect(scenario.mode == ModeNames.main)
    }

    /// Without a binding for the hold, the numeric mode's ghost key would type
    /// the key's digit among the emoji.
    @Test func aHoldTypesWhatTheTapTypesAndNeverADigit() {
        let scenario = KeyboardScenario(
            language: "en_US", autoCapitalize: false,
            settings: [.longPressBehaviour: LongPressType.digits.rawValue]
        )
        enter(scenario)
        scenario.longPress(GridSlot.topLeft)
        #expect(scenario.text == "😠")
        scenario.longPress(GridSlot.recent)
        #expect(scenario.text == "😠😂")
    }

    @Test func deleteTakesAWholeEmojiAndSpaceAndReturnStillWork() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        enter(scenario)
        scenario.returnSwipe(GridSlot.midRight, .swipeUp) // ❤️‍🔥, a ZWJ sequence
        #expect(scenario.text.count == 1)
        scenario.tap(UtilitySlot.delete)
        #expect(scenario.text.isEmpty)
        scenario.tap(GridSlot.center)
        scenario.tap(UtilitySlot.space)
        scenario.tap(UtilitySlot.return)
        #expect(scenario.text == "😜 \n")
        #expect(scenario.mode == ModeNames.emoji)
    }

    @Test func theNumbersAreOneSwipeLeftFromTheEmojiLettersKey() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        enter(scenario)
        scenario.swipe(UtilitySlot.symbols, .swipeLeft)
        #expect(scenario.mode == ModeNames.numeric)
    }

    @Test func theNumpadColumnDoesNotChangeTheEmojiPage() {
        let scenario = KeyboardScenario(
            language: "en_US", autoCapitalize: false,
            settings: [.numpadColumn: NumpadColumnPlacement.trailing.rawValue]
        )
        enter(scenario)
        #expect(scenario.mode == ModeNames.emoji)
        scenario.tap(GridSlot.center)
        #expect(scenario.text == "😜")
        let plan = scenario.viewModel.layoutPlan(forContainerWidth: scenario.containerWidth)
        #expect(plan?.arrangement.rows.flatMap { $0 }.contains { NumpadColumn.isNumpadKey($0.keyId) } == false)
    }
}

// MARK: - The recent key

struct EmojiRecentsTests {
    @Test func itStartsAsTheMostUsedEmoji() {
        #expect(EmojiRecents().items == EmojiRecents.seed)
        #expect(EmojiRecents.seed.count == EmojiRecents.capacity)
        #expect(EmojiRecents.seed.allSatisfy(EmojiText.isSingleEmoji))
    }

    @Test func recordingMovesToTheFrontAndKeepsNine() {
        var recents = EmojiRecents()
        recents.record("🔥")
        #expect(recents.items.first == "🔥")
        #expect(recents.items.count == 9)
        #expect(!recents.items.contains("😘"), "the oldest falls off")
        recents.record("😭")
        #expect(Array(recents.items.prefix(2)) == ["😭", "🔥"], "a repeat moves, it does not duplicate")
        #expect(Set(recents.items).count == 9)
        recents.record("😭")
        #expect(recents.items.first == "😭")
    }

    @Test func restoringDropsWhatIsNotOneEmojiAndPadsWithTheSeed() {
        let restored = EmojiRecents(restoring: ["🔥", "abc", "🔥", "", "👍👍", "5", "🥳"])
        #expect(Array(restored.items.prefix(2)) == ["🔥", "🥳"])
        #expect(restored.items.count == 9)
        #expect(Set(restored.items).count == 9)
        #expect(EmojiRecents(restoring: nil) == EmojiRecents())
        #expect(EmojiRecents(restoring: Array(repeating: "🔥", count: 20)).items.count == 9)
    }

    @Test func itRoundTripsThroughTheStoreAndWritesOnlyWhatChanged() {
        let defaults = InMemoryUserDefaults()
        #expect(EmojiRecents.load(from: defaults) == EmojiRecents())
        var recents = EmojiRecents()
        recents.record("🎉")
        recents.save(to: defaults)
        #expect(EmojiRecents.load(from: defaults) == recents)
        #expect(defaults.stringArray(forKey: SettingsKey.emojiRecents.rawValue)?.first == "🎉")
    }

    @Test func theRecentKeyReadsClockwiseFromTheCentre() {
        var recents = EmojiRecents()
        for emoji in ["🅰️", "🔥"].reversed() { _ = emoji }
        recents.record("🔥")
        let key = EmojiLayouts.recentKey(recents)
        #expect(key.bindings[.tap]?.label == "🔥", "the newest is the tap")
        #expect(key.bindings[.swipeUp]?.label == recents.items[1], "the one before is a flick up")
        #expect(key.bindings[.swipeUpRight]?.label == recents.items[2])
        #expect(key.bindings[.swipeUpLeft]?.label == recents.items[8], "the oldest closes the circle")
        #expect(key.id == GridSlot.recent)
    }
}

@MainActor
struct EmojiRecentsBehaviourTests {
    @Test func anEmojiTypedIsOnTheRecentKeyTheNextTimeTheModeIsEntered() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        scenario.swipe(UtilitySlot.symbols, .swipeDownRight)
        scenario.tap(GridSlot.topLeft) // 😠
        scenario.swipe(GridSlot.topRight, .swipeRight) // 🎉
        // While the mode is up the key does not move under the thumb.
        scenario.tap(GridSlot.recent)
        #expect(scenario.text == "😠🎉😂", "still the seed's first")
        scenario.tap(UtilitySlot.symbols)
        scenario.swipe(UtilitySlot.symbols, .swipeDownRight)
        scenario.target.reset()
        scenario.tap(GridSlot.recent)
        scenario.swipe(GridSlot.recent, .swipeUp)
        #expect(scenario.text == "😂🎉", "the newest on the tap, the one before it up")
    }

    @Test func theStoreIsWrittenWhenTheModeIsLeftNotPerEmoji() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        let key = SettingsKey.emojiRecents.rawValue
        scenario.swipe(UtilitySlot.symbols, .swipeDownRight)
        scenario.tap(GridSlot.topLeft)
        scenario.tap(GridSlot.center)
        #expect(scenario.defaults.stringArray(forKey: key) == nil, "nothing written while typing")
        scenario.tap(UtilitySlot.symbols)
        #expect(scenario.defaults.stringArray(forKey: key)?.prefix(2) == ["😜", "😠"])
    }

    @Test func aSecondKeyboardSessionStartsFromTheStore() {
        let first = KeyboardScenario(language: "en_US", autoCapitalize: false)
        first.swipe(UtilitySlot.symbols, .swipeDownRight)
        first.swipe(GridSlot.topRight, .swipeRight)
        first.tap(UtilitySlot.symbols)
        let stored = first.defaults.stringArray(forKey: SettingsKey.emojiRecents.rawValue)
        #expect(stored?.first == "🎉")

        let second = KeyboardScenario(
            language: "en_US", autoCapitalize: false,
            settings: [.emojiRecents: stored ?? []]
        )
        second.viewModel.reloadSettings()
        second.swipe(UtilitySlot.symbols, .swipeDownRight)
        second.tap(GridSlot.recent)
        #expect(second.text == "🎉")
    }

    @Test func nothingIsRememberedInASensitiveField() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        scenario.viewModel.fieldTraits = FieldTraits(isSensitive: true)
        scenario.swipe(UtilitySlot.symbols, .swipeDownRight)
        scenario.tap(GridSlot.topLeft)
        scenario.tap(UtilitySlot.symbols)
        #expect(scenario.defaults.stringArray(forKey: SettingsKey.emojiRecents.rawValue) == nil)
        #expect(scenario.viewModel.emojiRecents == EmojiRecents())
    }

    @Test func thePageTurnKeepsTheRecentKeyAndTheCompiledTablesAgree() throws {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        scenario.swipe(UtilitySlot.symbols, .swipeDownRight)
        scenario.tap(GridSlot.topLeft)
        scenario.tap(UtilitySlot.symbols)
        scenario.swipe(UtilitySlot.symbols, .swipeDownRight)
        let viewModel = scenario.viewModel
        let definition = try #require(viewModel.currentDefinition)
        let fresh = CompiledDefinition(definition)
        for page in [ModeNames.emoji, ModeNames.emojiMore] {
            let live = try #require(viewModel.compiledDefinition?.mode(page))
            let expected = try #require(fresh.mode(page))
            #expect(live.bindings == expected.bindings, "\(page)")
            #expect(live.table == expected.table, "\(page)")
        }
        #expect(definition.mode(ModeNames.emojiMore)?.keys[GridSlot.recent]?.bindings[.tap]?.label == "😠")
    }
}

// MARK: - What the eye and VoiceOver get

@MainActor
struct EmojiModePresentationTests {
    private func emojiKey(_ slot: String, page: String = ModeNames.emoji) throws -> KeyDefinition {
        let definition = try #require(KeyboardRegistry.load(id: "en_US"))
        return try #require(definition.mode(page)?.keys[slot])
    }

    @Test func theKeyIsNamedByItsFamilyAndItsPrototype() throws {
        let key = try emojiKey(GridSlot.topRight)
        let label = try #require(key.bindings[.tap]?.accessibilityLabel)
        #expect(label.contains("😂"))
        #expect(label.hasPrefix(EmojiLayouts.families[2].name))
        #expect(!EmojiLayouts.families[2].name.isEmpty)
    }

    /// Every emoji of every key is a rotor action named by itself and its
    /// gesture, which VoiceOver reads in the user's language; the return
    /// swipes say "and back".
    @Test func everyEmojiIsReachableWithoutGestures() throws {
        for family in EmojiLayouts.families {
            let key = try emojiKey(family.slot)
            let names = key.accessibilityActions.map(\.name)
            let cells = family.main.split(separator: " ").map(String.init)
            let returns = family.returns.split(separator: " ").map(String.init)
            for (index, gesture) in EmojiLayouts.gridGestures.enumerated() where gesture != .tap {
                #expect(names.contains { $0.hasPrefix(cells[index] + ", ") }, "\(family.id) \(gesture) \(cells[index])")
            }
            for (index, _) in EmojiLayouts.returnGestures.enumerated() {
                #expect(names.contains { $0.hasPrefix(returns[index] + ", ") && $0.hasSuffix(GestureType.spokenReturn) },
                        "\(family.id) return #\(index) \(returns[index])")
            }
            // The page turn is named, once, whichever way the thumb circles.
            #expect(names.filter { $0 == String(localized: "More emoji") }.count == 1)
        }
    }

    @Test func anEmojiActionIsReadWholeNotSpelledOut() throws {
        let key = try emojiKey(GridSlot.midRight)
        let zwj = try #require(key.accessibilityActions.first { $0.name.hasPrefix("❤️‍🔥") })
        #expect(zwj.glyph == nil, "an emoji has no spelled-out glyph; its name is the text")
    }

    @Test func emojiLabelsAreNeverHiddenByTheLabelToggles() throws {
        let key = try emojiKey(GridSlot.center)
        for binding in key.bindings.values where EmojiText.isEmoji(binding.label) {
            #expect(LabelCategory.of(binding).isVisible(
                areLetterLabelsHidden: true, areStandardSymbolLabelsHidden: true, areExtraSymbolLabelsHidden: true
            ), "\(binding.label)")
        }
        // And as plain symbols in a layout of the user's own.
        let symbol = KeyBinding(label: "😀", action: .commitText("😀"), category: nil, returnAction: nil, accessibilityLabel: nil)
        #expect(LabelCategory.of(symbol) == .functional)
        #expect(LabelCategory.classify("1") == .number, "a digit is not an emoji")
        #expect(LabelCategory.classify("#") != .functional)
    }

    @Test func theHintCanvasDrawsEveryNuanceAsAnEmoji() throws {
        let key = try emojiKey(GridSlot.topLeft)
        let hints = KeyHintCanvas.hints(
            for: key, languageLabel: "", isLanguageLabelShown: false, isLabelVisible: { _ in true }
        )
        #expect(hints.count == 8)
        for hint in hints {
            guard case let .emoji(text) = hint.content else {
                Issue.record("\(hint.gesture) is not an emoji hint"); continue
            }
            #expect(EmojiText.isSingleEmoji(text))
        }
    }

    @Test func theEntryGestureIsShownAsAHintAndNamed() throws {
        let definition = try #require(KeyboardRegistry.load(id: "en_US"))
        let key = try #require(definition.mode(ModeNames.main)?.keys[UtilitySlot.symbols])
        let hints = KeyHintCanvas.hints(
            for: key, languageLabel: "", isLanguageLabelShown: false,
            isLabelVisible: {
                LabelCategory.of($0).isVisible(
                    areLetterLabelsHidden: true, areStandardSymbolLabelsHidden: true, areExtraSymbolLabelsHidden: true
                )
            }
        )
        #expect(hints.contains { $0.gesture == .swipeDownRight }, "a modifier hint is not hideable")
        #expect(key.accessibilityActions.contains { $0.name == String(localized: "Emoji") })
    }

    @Test func theGuidePreviewsTheEmojiAReleaseWouldType() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        scenario.swipe(UtilitySlot.symbols, .swipeDownRight)
        let viewModel = scenario.viewModel
        #expect(viewModel.previewLabel(for: .swipeUp, keyId: GridSlot.topRight, isReturn: false) == "🤣")
        #expect(viewModel.previewLabel(for: .swipeUp, keyId: GridSlot.topRight, isReturn: true) == "🥳")
        #expect(viewModel.previewLabel(for: .circularClockwise, keyId: GridSlot.topRight, isReturn: false) == "\u{2461}")
    }

    @Test func theEmojiTextHelpersTellEmojiFromTheLookAlikes() {
        for yes in ["😂", "❤️", "☀️", "❤️‍🔥", "😮‍💨", "🫨", "👍", "‼️"] { #expect(EmojiText.isEmoji(yes), "\(yes)") }
        for no in ["", "a", "1", "#", "*", "©", "→", "♥", "ab"] { #expect(!EmojiText.isEmoji(no), "\(no)") }
        #expect(EmojiText.isSingleEmoji("👨‍👩‍👧"))
        #expect(!EmojiText.isSingleEmoji("😂😂"))
    }
}
