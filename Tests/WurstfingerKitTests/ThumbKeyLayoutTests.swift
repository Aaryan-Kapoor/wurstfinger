//
//  ThumbKeyLayoutTests.swift
//  WurstfingerTests
//
//  The English Thumb-Key layout: its letter arrangement pinned against the
//  upstream layout table (dessalines/thumb-key, EN Thumb-Key), the way it is
//  registered, and typing on it end to end.
//

import Foundation
import Testing
@testable import WurstfingerKit
@testable import WurstfingerScenarioKit

@MainActor
struct ThumbKeyLayoutTests {
    private static let thumbKey = LanguageDefinitions.thumbKeyEnglish.makeDefinition()

    /// Every letter-key position of the upstream layout: the key (by its
    /// place on the 3x3 grid), then each gesture and what it types. Upstream
    /// `top` is a swipe up, `bottomRight` a swipe down-right, and so on.
    private static let table: [String: [GestureType: String]] = [
        GridSlot.topLeft: [.tap: "s", .swipeDownRight: "w"],
        GridSlot.topCenter: [.tap: "r", .swipeDown: "g"],
        GridSlot.topRight: [.tap: "o", .swipeDownLeft: "u"],
        GridSlot.midLeft: [.tap: "n", .swipeRight: "m"],
        GridSlot.center: [
            .tap: "h", .swipeUpLeft: "j", .swipeUp: "q", .swipeUpRight: "b", .swipeRight: "p",
            .swipeDownRight: "y", .swipeDown: "x", .swipeDownLeft: "v", .swipeLeft: "k",
        ],
        GridSlot.midRight: [.tap: "a", .swipeLeft: "l"],
        GridSlot.bottomLeft: [.tap: "t", .swipeUpRight: "c"],
        GridSlot.bottomCenter: [
            .tap: "i", .swipeUp: "f", .swipeUpRight: "'", .swipeRight: "z",
            .swipeDownRight: "-", .swipeDown: ".", .swipeDownLeft: "*",
        ],
        GridSlot.bottomRight: [.tap: "e", .swipeUpLeft: "d"],
    ]

    private func mode(_ name: String) throws -> KeyboardMode {
        try #require(Self.thumbKey.modes[name])
    }

    // MARK: - Binding table

    @Test func everyKeyTypesExactlyWhatUpstreamPutsThere() throws {
        let main = try mode(ModeNames.main)
        for (slot, expected) in Self.table {
            let key = try #require(main.keys[slot])
            for (gesture, text) in expected {
                #expect(key.bindings[gesture]?.action == .commitText(text), "\(slot) \(gesture) should type \(text)")
            }
        }
    }

    @Test func letterKeysCarryNothingUpstreamDoesNotPutThere() throws {
        let main = try mode(ModeNames.main)
        for slot in CustomLayout.slots {
            let bound = Set(try #require(main.keys[slot]).bindings.keys)
            var expected = Set(Self.table[slot, default: [:]].keys)
            // The shift pair on `a`: up is upstream's shift; down is the
            // unlabelled carrier of the word-case return swipe (a plain down
            // swipe in main switches to main, i.e. does nothing).
            if slot == GridSlot.midRight { expected.formUnion([.swipeUp, .swipeDown]) }
            #expect(bound == expected, "\(slot) binds \(bound.subtracting(expected)) and lacks \(expected.subtracting(bound))")
        }
    }

    @Test func theShiftSwipesSitWhereUpstreamHasThem() throws {
        let main = try mode(ModeNames.main)
        let up = try #require(main.keys[GridSlot.midRight]?.bindings[.swipeUp])
        #expect(up.action == .switchMode(ModeNames.shifted))
        #expect(up.returnAction == .capitalizeWord(uppercased: true))

        // Shifted mode: up is caps lock, down goes back to the lowercase mode.
        let shifted = try mode(ModeNames.shifted)
        #expect(shifted.keys[GridSlot.midRight]?.bindings[.swipeUp]?.action == .switchMode(ModeNames.capsLock))
        #expect(shifted.keys[GridSlot.midRight]?.bindings[.swipeDown]?.action == .switchMode(ModeNames.main))
    }

    @Test func shiftedModeIsTheUppercasedMainMode() throws {
        let shifted = try mode(ModeNames.shifted)
        for (slot, expected) in Self.table {
            for (gesture, text) in expected {
                let typed = shifted.keys[slot]?.bindings[gesture]?.action
                // Upstream's shifted letters are the capitals; its punctuation
                // (' - . *) is the same in both modes.
                #expect(typed == .commitText(text.uppercased()), "\(slot) \(gesture) shifted")
            }
        }
    }

    // MARK: - Alphabet

    @Test func everyLatinLetterHasExactlyOneKeyPosition() throws {
        let main = try mode(ModeNames.main)
        var seen: [String: Int] = [:]
        for key in main.keys.values {
            for binding in key.bindings.values {
                if case let .commitText(text) = binding.action, text.count == 1, text.first?.isLetter == true {
                    seen[text, default: 0] += 1
                }
            }
        }
        let letters = Set("abcdefghijklmnopqrstuvwxyz".map(String.init))
        #expect(Set(seen.keys) == letters)
        #expect(seen.values.allSatisfy { $0 == 1 }, "a letter sits on two positions: \(seen.filter { $0.value > 1 }.keys)")
    }

    // MARK: - Structure and registration

    @Test func definitionIsStructurallyValid() {
        #expect(Self.thumbKey.validate().isEmpty)
        // ASCII letters, so the one-shot Ctrl and Alt modes are generated too.
        #expect(Self.thumbKey.modes.keys.sorted() == [
            ModeNames.alt, ModeNames.capsLock, ModeNames.control, ModeNames.main, ModeNames.numeric, ModeNames.shifted,
        ])
    }

    @Test func numericModeStillOffersTheShortcutsToPunctuation() throws {
        // Upstream keeps punctuation on its numeric and symbol pages; here it
        // is the numeric mode, reached by the "123" key.
        let numeric = try mode(ModeNames.numeric)
        let punctuation = numeric.keys.values.flatMap { $0.bindings.values.map(\.action) }
        #expect(punctuation.contains(.commitText("!")))
        #expect(punctuation.contains(.commitText(",")))
        #expect(punctuation.contains(.commitText("?")))
    }

    @Test func registeredNextToEnglishAsThumbKeyFamily() throws {
        let metadata = try #require(KeyboardRegistry.available.first { $0.id == "en_US_thumbkey" })
        #expect(metadata.family == .thumbKey)
        #expect(metadata.title == "English (Thumb-Key)")
        #expect(metadata.localeIdentifier == "en_US")
        #expect(KeyboardRegistry.load(id: "en_US_thumbkey")?.id == "en_US_thumbkey")
        #expect(KeyboardRegistry.available.first { $0.id == "en_US" }?.family == .messagEase)
    }

    @Test func englishSystemLanguagesStillResolveToMessagEase() {
        for preferred in ["en-US", "en-GB", "en-AU", "en"] {
            #expect(LanguageSettings.detectSystemLanguage(preferredLanguages: [preferred]) == "en_US", "\(preferred)")
        }
    }

    // MARK: - Typing

    @Test func typesThePangramThroughSwipes() {
        let scenario = KeyboardScenario(language: "en_US_thumbkey", autoCapitalize: false)
        let missing = scenario.type("the quick brown fox jumps over the lazy dog")
        #expect(missing.isEmpty, "no gesture produces \(missing)")
        #expect(scenario.text == "the quick brown fox jumps over the lazy dog")
    }

    @Test func autoCapitalizationAndTheShiftSwipeWork() {
        let scenario = KeyboardScenario(language: "en_US_thumbkey", autoCapitalize: true)
        #expect(scenario.mode == ModeNames.shifted)
        let missing = scenario.type("Sea it")
        #expect(missing.isEmpty, "no gesture produces \(missing)")
        #expect(scenario.text == "Sea it")

        // A swipe up on the `a` key engages shift by hand; the next letter is a capital.
        scenario.clear()
        #expect(scenario.mode == ModeNames.shifted)
        scenario.tap(GridSlot.topLeft) // S
        #expect(scenario.mode == ModeNames.main)
        scenario.swipe(GridSlot.midRight, .swipeUp)
        #expect(scenario.mode == ModeNames.shifted)
        scenario.tap(GridSlot.topRight) // O
        #expect(scenario.text == "SO")
    }

    @Test func punctuationLivesInTheNumericMode() {
        let scenario = KeyboardScenario(language: "en_US_thumbkey", autoCapitalize: false)
        let missing = scenario.type("it's a-ha, ok? 42!")
        #expect(missing.isEmpty, "no gesture produces \(missing)")
        #expect(scenario.text == "it's a-ha, ok? 42!")
    }
}
