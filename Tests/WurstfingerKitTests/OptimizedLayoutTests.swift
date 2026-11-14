//
//  OptimizedLayoutTests.swift
//  WurstfingerTests
//
//  The English (Optimized) layout: that it is registered and selectable, that
//  it is a permutation of the MessagEase English letters and nothing else, that
//  it is the layout the optimizer wrote down, and that it types.
//

import Foundation
import Testing
@testable import WurstfingerKit
@testable import WurstfingerScenarioKit

private let optimizedId = "en_US_optimized"

/// The optimizer's output the shipped layout is pinned to: the best layout with
/// at most four letters moved from MessagEase (see `LanguageDefinitions.englishOptimized`).
private let shippedLayoutFile = "optimized_layout_k4.json"

/// Where the optimizer's output lives: this file is in `Tests/WurstfingerKitTests/`.
private func optimizerOutput(_ name: String, file: String = #filePath) throws -> [String: Any] {
    let root = URL(fileURLWithPath: file)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("scripts/layout-science/\(name)"))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private let letterSlots: [(String, Int, Int)] = [
    (GridSlot.topLeft, 0, 0), (GridSlot.topCenter, 0, 1), (GridSlot.topRight, 0, 2),
    (GridSlot.midLeft, 1, 0), (GridSlot.center, 1, 1), (GridSlot.midRight, 1, 2),
    (GridSlot.bottomLeft, 2, 0), (GridSlot.bottomCenter, 2, 1), (GridSlot.bottomRight, 2, 2),
]

/// The lowercase letter a gesture on a key commits, if it commits one.
private func letter(_ key: KeyDefinition?, _ gesture: GestureType) -> String? {
    guard case let .commitText(text)? = key?.bindings[gesture]?.action,
          text.count == 1, text.first?.isLetter == true
    else { return nil }
    return text
}

struct OptimizedLayoutRegistrationTests {
    @Test func theLayoutIsRegisteredAsAnEnglishVariant() throws {
        let metadata = try #require(KeyboardRegistry.available.first { $0.id == optimizedId })
        #expect(metadata.localeIdentifier == "en_US")
        #expect(metadata.family == .optimized, "the language list must not call it a MessagEase layout")
        #expect(LanguageMetadata.language(withId: optimizedId) != nil)
        #expect(KeyboardRegistry.load(id: optimizedId)?.id == optimizedId)
    }

    @Test func theMessagEaseEnglishLayoutIsStillThereAndStillTheDefault() throws {
        let english = try #require(KeyboardRegistry.available.first { $0.id == "en_US" })
        #expect(english.family == .messagEase)
        #expect(LanguageMetadata.english.id == "en_US")
        // The default language of a fresh installation does not change.
        #expect(LanguageSettings.nextLanguageId(after: "en_US", in: ["en_US"]) == "en_US")
    }

    @Test @MainActor func theGlobeKeyTellsTheTwoEnglishLayoutsApart() throws {
        let optimized = KeyboardScenario(language: optimizedId, autoCapitalize: false)
        let plain = KeyboardScenario(language: "en_US", autoCapitalize: false)
        #expect(plain.viewModel.currentLanguageLabel == "EN")
        #expect(optimized.viewModel.currentLanguageLabel == "EN+")
        // Every other language keeps the label its locale gives.
        let german = KeyboardScenario(language: "de_DE", autoCapitalize: false)
        #expect(german.viewModel.currentLanguageLabel == "DE")
    }

    @Test func itHasADisplayNameThatSaysWhatItIs() throws {
        let metadata = try #require(KeyboardRegistry.available.first { $0.id == optimizedId })
        #expect(metadata.title.localizedCaseInsensitiveContains("english"))
        #expect(metadata.title.localizedCaseInsensitiveContains("optimi"))
        #expect(metadata.title != LanguageMetadata.english.title)
        #expect(!metadata.family.subtitle.isEmpty)
    }

    @Test func itValidatesAndHasTheSameModesAsMessagEaseEnglish() throws {
        let optimized = try #require(KeyboardRegistry.load(id: optimizedId))
        let english = try #require(KeyboardRegistry.load(id: "en_US"))
        #expect(optimized.validate().isEmpty)
        #expect(Set(optimized.modes.keys) == Set(english.modes.keys))
        #expect(optimized.settings.autoCapitalize == english.settings.autoCapitalize)
    }
}

struct OptimizedLayoutStructureTests {
    private func definitions() throws -> (optimized: KeyboardMode, english: KeyboardMode) {
        let optimized = try #require(KeyboardRegistry.load(id: optimizedId)?.mode(ModeNames.main))
        let english = try #require(KeyboardRegistry.load(id: "en_US")?.mode(ModeNames.main))
        return (optimized, english)
    }

    @Test func theLettersAreAPermutationOfTheAlphabet() throws {
        let (optimized, _) = try definitions()
        var seen: [String] = []
        for (slot, _, _) in letterSlots {
            for gesture in GestureType.allCases where gesture != .longPress {
                if let character = letter(optimized.keys[slot], gesture) { seen.append(character) }
            }
        }
        #expect(seen.count == 26)
        #expect(Set(seen) == Set("abcdefghijklmnopqrstuvwxyz".map(String.init)))
    }

    @Test func lettersOccupyExactlyTheSlotsMessagEaseLettersOccupy() throws {
        let (optimized, english) = try definitions()
        for (slot, _, _) in letterSlots {
            for gesture in GestureType.allCases where gesture != .longPress {
                #expect(
                    (letter(optimized.keys[slot], gesture) != nil) == (letter(english.keys[slot], gesture) != nil),
                    "\(slot).\(gesture)"
                )
            }
        }
    }

    @Test func everythingThatIsNotALetterIsExactlyWhereItIsInMessagEaseEnglish() throws {
        // Punctuation, symbols, dead keys, return swipes of symbols and every
        // utility binding: untouched, so muscle memory for them carries over.
        let (optimized, english) = try definitions()
        var compared = 0
        for (keyId, key) in english.keys {
            for (gesture, binding) in key.bindings where letter(key, gesture) == nil {
                #expect(optimized.keys[keyId]?.bindings[gesture] == binding, "\(keyId).\(gesture)")
                compared += 1
            }
        }
        #expect(compared > 60)
    }

    @Test func eachKeysTapLetterIsTheMostFrequentOfItsNine() throws {
        // The readability constraint the search ran under, against the same
        // letter counts the model uses (`data/boundaries.tsv`).
        let counts = try letterCounts()
        let (optimized, _) = try definitions()
        for (slot, _, _) in letterSlots {
            let key = optimized.keys[slot]
            let tap = try #require(letter(key, .tap))
            for gesture in GestureType.allCases where gesture.isSwipe {
                guard let swipe = letter(key, gesture) else { continue }
                #expect(counts[tap]! >= counts[swipe]!, "\(slot): swipe \(swipe) outranks tap \(tap)")
            }
        }
    }

    @Test func exactlyFourLettersMovedAndNothingElse() throws {
        // a h l z trade places; the other 22 letters keep the slot they have in
        // MessagEase English. This is the learnability bound the layout was
        // chosen under.
        let (optimized, english) = try definitions()
        var moved = Set<String>()
        for (slot, _, _) in letterSlots {
            for gesture in GestureType.allCases where gesture != .longPress {
                let now = letter(optimized.keys[slot], gesture)
                let before = letter(english.keys[slot], gesture)
                if now != before, let now { moved.insert(now) }
            }
        }
        #expect(moved == ["a", "h", "l", "z"])
    }

    @Test func theLayoutThatShipsIsTheOneTheOptimizerCalledFourLettersMoved() throws {
        let output = try optimizerOutput(shippedLayoutFile)
        #expect(output["letters_moved_from_messagease"] as? Int == 4)
        let cost = try #require(output["cost_per_char_bits"] as? Double)
        let baseline = try #require(output["messagease_cost_per_char_bits"] as? Double)
        #expect(cost < baseline, "the shipped layout must be the cheaper one under the model")
    }

    /// Letter counts of the corpus table the model uses.
    private func letterCounts(file: String = #filePath) throws -> [String: Int] {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(
            contentsOf: root.appendingPathComponent("scripts/layout-science/data/boundaries.tsv"), encoding: .utf8
        )
        var counts: [String: Int] = [:]
        for line in text.split(separator: "\n") where line.hasPrefix("letter\t") {
            let fields = line.split(separator: "\t")
            counts[String(fields[1])] = Int(fields[2])
        }
        #expect(counts.count == 26)
        return counts
    }

    @Test func shiftedModeHasTheUppercaseOfEveryLetter() throws {
        let shifted = try #require(KeyboardRegistry.load(id: optimizedId)?.mode(ModeNames.shifted))
        var uppercase = Set<String>()
        for (slot, _, _) in letterSlots {
            for gesture in GestureType.allCases where gesture != .longPress {
                if case let .commitText(text)? = shifted.keys[slot]?.bindings[gesture]?.action,
                   text.count == 1, text.first?.isUppercase == true { uppercase.insert(text) }
            }
        }
        #expect(uppercase == Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init)))
    }
}

struct OptimizedLayoutMatchesTheOptimizerTests {
    @Test func theSwiftLayoutIsExactlyTheLayoutTheScriptWroteDown() throws {
        let output = try optimizerOutput(shippedLayoutFile)
        let grid = try #require(output["grid"] as? [[String]])
        let swipes = try #require(output["swipes"] as? [String: [String: String]])
        let main = try #require(KeyboardRegistry.load(id: optimizedId)?.mode(ModeNames.main))

        for (slot, row, column) in letterSlots {
            let key = main.keys[slot]
            #expect(letter(key, .tap) == grid[row][column], "\(slot) tap")
            var swipesFromScript = swipes[slot] ?? [:]
            for gesture in GestureType.allCases where gesture.isSwipe {
                let expected = swipesFromScript.removeValue(forKey: gesture.rawValue)
                #expect(letter(key, gesture) == expected, "\(slot).\(gesture)")
            }
            #expect(swipesFromScript.isEmpty, "\(slot): script names gestures the layout lacks")
        }
    }

    @Test func theScriptsTranscriptionOfMessagEaseEnglishIsTheShippedLayout() throws {
        // The cost model scores MessagEase from its own table; that table must
        // be the layout in the app, or every comparison is about something else.
        let messagease = try optimizerOutput("messagease_layout.json")
        let grid = try #require(messagease["grid"] as? [[String]])
        let swipes = try #require(messagease["swipes"] as? [String: [String: String]])
        let main = try #require(KeyboardRegistry.load(id: "en_US")?.mode(ModeNames.main))
        for (slot, row, column) in letterSlots {
            #expect(letter(main.keys[slot], .tap) == grid[row][column], "\(slot) tap")
            for (gesture, character) in swipes[slot] ?? [:] {
                let gestureType = try #require(GestureType(rawValue: gesture))
                #expect(letter(main.keys[slot], gestureType) == character, "\(slot).\(gesture)")
            }
        }
    }
}

@Suite(.serialized)
@MainActor
struct OptimizedLayoutTypingTests {
    @Test func aPangramTypesThroughTheRealInputEngine() {
        let scenario = KeyboardScenario(language: optimizedId, autoCapitalize: false)
        let sentence = "the quick brown fox jumps over the lazy dog"
        let missing = scenario.type(sentence)
        #expect(missing.isEmpty, "no gesture produces \(missing)")
        #expect(scenario.text == sentence)
    }

    @Test func aSentenceWithCapitalsAndPunctuationTypes() {
        let scenario = KeyboardScenario(language: optimizedId, autoCapitalize: true)
        let sentence = "Hello, World! Is it 4 o'clock? Yes."
        let missing = scenario.type(sentence)
        #expect(missing.isEmpty, "no gesture produces \(missing)")
        #expect(scenario.text == sentence)
    }

    @Test func everyLetterHasAGestureAndTypesItselfByTapOrSwipe() {
        let scenario = KeyboardScenario(language: optimizedId, autoCapitalize: false)
        let alphabet = "abcdefghijklmnopqrstuvwxyz"
        #expect(scenario.type(alphabet).isEmpty)
        #expect(scenario.text == alphabet)
    }

    @Test func theKeyTapsTypeWhatTheLayoutSays() throws {
        let output = try optimizerOutput(shippedLayoutFile)
        let grid = try #require(output["grid"] as? [[String]])
        let scenario = KeyboardScenario(language: optimizedId, autoCapitalize: false)
        for (slot, row, column) in letterSlots { scenario.tap(slot); _ = (row, column) }
        let expected = letterSlots.map { grid[$0.1][$0.2] }.joined()
        #expect(scenario.text == expected)
    }

    @Test func theSymbolsAndEditingGesturesAreUnchanged() {
        let scenario = KeyboardScenario(language: optimizedId, autoCapitalize: false)
        scenario.type("ab")
        scenario.swipe(UtilitySlot.return, .swipeLeft)          // delete word
        #expect(scenario.text.isEmpty)
        scenario.swipe(GridSlot.bottomCenter, .swipeDown)       // the period is where it always was
        #expect(scenario.text == ".")
        scenario.swipe(UtilitySlot.symbols, .swipeUpLeft)       // Ctrl is there too
        #expect(scenario.mode == ModeNames.control)
    }

    @Test func switchingFromMessagEaseEnglishAndBack() {
        let scenario = KeyboardScenario(
            language: "en_US", autoCapitalize: false,
            settings: [.enabledLanguageIds: ["en_US", optimizedId]]
        )
        scenario.swipe(UtilitySlot.globe, .swipeRight)
        #expect(scenario.viewModel.currentDefinition?.id == optimizedId)
        scenario.swipe(UtilitySlot.globe, .swipeUp)
        #expect(scenario.viewModel.currentDefinition?.id == "en_US")
    }
}
