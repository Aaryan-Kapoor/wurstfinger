//
//  LayoutLabTests.swift
//  WurstfingerTests
//
//  The layout lab: that its cost model is the Python one, that its optimizer is
//  deterministic and obeys the rules that keep a layout the same keyboard, and
//  that the corpus tables and generated layouts it produces hold together.
//

import Foundation
import Testing
@testable import WurstfingerKit
@testable import WurstfingerLayoutLab
@testable import WurstfingerScenarioKit

private func repositoryRoot(file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

/// The English table the Python model reads: `bigrams_1w.tsv` plus the word
/// boundaries of `boundaries.tsv`, both derived from Norvig's `count_1w.txt`.
private func pythonEnglishTable() throws -> CorpusTable {
    let directory = repositoryRoot().appendingPathComponent("scripts/layout-science/data")
    var table = CorpusTable()
    let bigrams = try String(contentsOf: directory.appendingPathComponent("bigrams_1w.tsv"), encoding: .utf8)
    for line in bigrams.split(separator: "\n") where !line.hasPrefix("#") {
        let fields = line.split(separator: "\t")
        let pair = String(fields[0])
        table.bigrams[CorpusTable.Pair(first: String(pair.first!), second: String(pair.last!))] = Int(fields[1])!
    }
    let boundaries = try String(contentsOf: directory.appendingPathComponent("boundaries.tsv"), encoding: .utf8)
    for line in boundaries.split(separator: "\n") where line.hasPrefix("letter\t") {
        let fields = line.split(separator: "\t")
        table.initial[String(fields[1])] = Int(fields[3])!
        table.final[String(fields[1])] = Int(fields[4])!
    }
    return table
}

/// A Python-schema layout JSON (`grid` + `swipes`) as a letter assignment.
private func assignment(fromLayoutFile name: String) throws -> LetterAssignment {
    let url = repositoryRoot().appendingPathComponent("scripts/layout-science/\(name)")
    let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let grid = try #require(object["grid"] as? [[String]])
    let swipes = try #require(object["swipes"] as? [String: [String: String]])
    let keyNames = GridSlot.allSlots.joined().map { $0 }
    var out: LetterAssignment = [:]
    for row in 0 ..< 3 {
        for column in 0 ..< 3 { out[LabSlot(key: row * 3 + column, gesture: .tap)] = grid[row][column] }
    }
    for (key, byGesture) in swipes {
        for (gesture, letter) in byGesture {
            out[LabSlot(key: try #require(keyNames.firstIndex(of: key)), gesture: try #require(GestureType(rawValue: gesture)))] = letter
        }
    }
    return out
}

struct CostModelParityTests {
    @Test func geometryIsTheKeyboardsAt393Points() {
        let model = CostModel()
        #expect(abs(model.cellWidth - 88.5) < 1e-9)
        #expect(abs(model.centres[0].x - (12 + 88.5 / 2)) < 1e-9)
        #expect(abs(model.centres[4].y - (4 + 88.5 / 2 + 93.5)) < 1e-9)
        // The space bar is three cells and two gaps wide.
        #expect(abs(model.sizes[9].width - 275.5) < 1e-9)
        // The same cell the app resolves.
        let metrics = KeyboardLayoutMetrics.resolve(
            wishWidth: 393, aspectRatio: 1, columns: 4, availableWidth: 393, screenHeight: 0
        )
        #expect(abs(Double(metrics.cellWidth) - model.cellWidth) < 1e-9)
    }

    @Test func strokeBitsAreTheDocumentedOnes() {
        let model = CostModel()
        #expect(model.strokeBits(.tap) == 0)
        #expect(abs(model.strokeBits(.swipeUp) - 1.0) < 1e-12)
        #expect(abs(model.strokeBits(.swipeUpLeft) - log2(1 + 2.0.squareRoot())) < 1e-12)
    }

    /// The numbers `scripts/layout-science/model.py` prints for the same table,
    /// one thumb, 393 pt, text from `count_1w`.
    @Test(arguments: [
        ("messagease_layout.json", 1.62784517909644),
        ("optimized_layout_k4.json", 1.5957461812725255),
        ("optimized_layout.json", 1.555158608983236),
    ])
    func swiftScoresMatchPython(file: String, expected: Double) throws {
        let problem = try LayoutProblem(languageId: "en_US")
        let text = TextModel(table: try pythonEnglishTable(), problem: problem)
        #expect(text.coverage == 1)
        let optimizer = LayoutOptimizer(problem: problem, text: text)
        let scored = optimizer.score(try assignment(fromLayoutFile: file))
        #expect(abs(scored.cost - expected) < 1e-9, "\(file): \(scored.cost) vs \(expected)")
    }

    @Test func theShippedEnglishLayoutsAreTheOnesPythonScored() throws {
        let english = try LayoutProblem(languageId: "en_US")
        #expect(english.base == (try assignment(fromLayoutFile: "messagease_layout.json")))
        let optimized = try LayoutProblem(languageId: "en_US_optimized")
        #expect(optimized.base == (try assignment(fromLayoutFile: "optimized_layout_k4.json")))
    }
}

struct LayoutProblemTests {
    @Test func englishHasTwentySixLetterSlotsAndNothingElseMoves() throws {
        let problem = try LayoutProblem(languageId: "en_US")
        #expect(problem.movableSlots.count == 26)
        #expect(Set(problem.letters) == Set("abcdefghijklmnopqrstuvwxyz".map(String.init)))
        // Punctuation and the dead keys are fixed, with their real slots.
        #expect(problem.fixedCharacters["'"] != nil)
        #expect(problem.fixedCharacters["."] != nil)
        #expect(problem.triggerSlots["¨"] != nil)
        #expect(problem.triggerSlots["´"] != nil)
    }

    @Test func noShippedLayoutRepeatsALetter() throws {
        // The Greek layout used to bind ω twice; its second slot now holds ί.
        for language in KeyboardRegistry.available where language.variantOf == nil {
            guard let problem = try? LayoutProblem(languageId: language.id) else { continue }
            #expect(problem.duplicateSlots.isEmpty, "\(language.id)")
        }
        let greek = try LayoutProblem(languageId: "el_GR")
        #expect(greek.movableSlots.count == 26)
        #expect(greek.letters.contains("ί") && greek.letters.filter { $0 == "ω" }.count == 1)
    }

    @Test func theCaselessRightToLeftLayoutsAreProblemsToo() throws {
        for id in ["he_IL", "ar", "fa_IR"] {
            let problem = try LayoutProblem(languageId: id)
            #expect(problem.movableSlots.count >= 22, "\(id)")
        }
        // Hebrew's final letters ride the return swipe of their base letter.
        let hebrew = try LayoutProblem(languageId: "he_IL")
        #expect(hebrew.formOfLetter["כ"] == "ך")
        #expect(hebrew.formOfLetter["פ"] == "ף")
        #expect(hebrew.formOfLetter["צ"] == "ץ")
        // The tatweel is a decoration and stays put, and so does its ZWNJ return in Persian.
        let persian = try LayoutProblem(languageId: "fa_IR")
        #expect(!persian.letters.contains("ـ"))
        #expect(persian.fixedCharacters["\u{200C}"]?.form == true)
    }

    @Test func everyCasedLanguageIsAProblem() {
        for id in ["en_US", "de_DE", "fr_FR", "es_ES", "ca_ES", "it_IT", "pt_PT", "pl_PL", "hr_HR", "sv_SE",
                   "fi_FI", "et_EE", "tl_PH", "vi_VN", "ru_RU", "uk_UA", "el_GR"] {
            #expect((try? LayoutProblem(languageId: id)) != nil, "\(id)")
        }
    }

    @Test func accentedCharactersExpandThroughTheLayoutsOwnRoutes() throws {
        let french = try LayoutProblem(languageId: "fr_FR")
        let frenchIndex = Dictionary(uniqueKeysWithValues: french.letters.enumerated().map { ($1, $0) })
        // é is on a key in French.
        #expect(TextModel.expand("é", problem: french, letterIndex: frenchIndex)?.count == 1)
        // ï is no key and French binds no diaeresis: it is i and the 🅒 key, as often as the cycle needs.
        let cycled = try #require(TextModel.expand("ï", problem: french, letterIndex: frenchIndex))
        #expect(cycled.first == .letter("i"))
        #expect(cycled.dropFirst().allSatisfy { $0 == .fixed(french.cycleSlot!) })
        // Something the layout cannot type at all is refused, not guessed.
        #expect(TextModel.expand("ж", problem: french, letterIndex: frenchIndex) == nil)

        // Where a layout binds the trigger, the base letter plus the trigger's slot.
        let english = try LayoutProblem(languageId: "en_US")
        let englishIndex = Dictionary(uniqueKeysWithValues: english.letters.enumerated().map { ($1, $0) })
        let umlaut = try #require(TextModel.expand("ü", problem: english, letterIndex: englishIndex))
        #expect(umlaut == [.letter("u"), .fixed(try #require(english.triggerSlots["¨"]))])
    }

    @Test func vietnameseIsTypedTelex() throws {
        let problem = try LayoutProblem(languageId: "vi_VN")
        #expect(problem.usesTelex)
        let letterIndex = Dictionary(uniqueKeysWithValues: problem.letters.enumerated().map { ($1, $0) })
        // ế = e, e (circumflex), s (acute)
        let tokens = TextModel.expand("ế", problem: problem, letterIndex: letterIndex)
        #expect(tokens == [.letter("e"), .letter("e"), .letter("s")])
    }
}

struct CorpusTableTests {
    @Test func wordsAreCountedByTheirFrequency() {
        var table = CorpusTable()
        table.add(word: "ab", weight: 3, locale: Locale(identifier: "en_US"))
        table.add(word: "Abc", weight: 2, locale: Locale(identifier: "en_US"))
        #expect(table.initial == ["a": 5])
        #expect(table.final == ["b": 3, "c": 2])
        #expect(table.bigrams[CorpusTable.Pair(first: "a", second: "b")] == 5)
        #expect(table.bigrams[CorpusTable.Pair(first: "b", second: "c")] == 2)
        #expect(table.occurrences == ["a": 5, "b": 5, "c": 2])
    }

    @Test func theTextFormatRoundTripsAndIsCanonical() throws {
        var table = CorpusTable()
        table.meta["source"] = "test"
        let locale = Locale(identifier: "de_DE")
        for (word, weight) in [("schön", 5), ("straße", 3), ("o'clock", 1)] { table.add(word: word, weight: weight, locale: locale) }
        let text = table.serialized()
        let parsed = try #require(CorpusTable(parsing: text))
        #expect(parsed == table)
        #expect(parsed.serialized() == text, "sorted, so the same counts are the same bytes")
    }

    @Test func aWordWithAnUntypableCharacterIsDroppedWhole() {
        let list = "good 10\nbad1 5\nfine 3\n"
        let (table, kept, seen) = CorpusTable.fromWordList(
            list, locale: Locale(identifier: "en_US"), isTypable: { $0.first?.isLetter == true }
        )
        #expect(seen == 3 && kept == 2)
        #expect(table.initial == ["g": 10, "f": 3])
    }

    @Test func typographicApostrophesAreFolded() {
        var table = CorpusTable()
        table.add(word: "don\u{2019}t", weight: 1, locale: Locale(identifier: "en_US"))
        #expect(table.bigrams[CorpusTable.Pair(first: "n", second: "'")] == 1)
    }
}

struct OptimizerTests {
    private func englishOptimizer() throws -> (LayoutOptimizer, LayoutProblem) {
        let problem = try LayoutProblem(languageId: "en_US")
        let text = TextModel(table: try pythonEnglishTable(), problem: problem)
        return (LayoutOptimizer(problem: problem, text: text), problem)
    }

    private let quick = AnnealingSettings(restarts: 6, steps: 6_000, seed: 3)

    @Test func theSameSeedGivesTheSameLayoutAndCost() throws {
        let (optimizer, _) = try englishOptimizer()
        let first = optimizer.optimize(maxMoved: 4, settings: quick)
        let second = optimizer.optimize(maxMoved: 4, settings: quick)
        #expect(first == second)
        let free = optimizer.optimize(maxMoved: nil, settings: quick)
        #expect(free == optimizer.optimize(maxMoved: nil, settings: quick))
    }

    @Test func theRandomGeneratorIsFixedAcrossMachines() {
        var generator = LayoutLabRandom(seed: 0)
        #expect(generator.next() == 0xE220_A839_7B1D_CDAF)
        #expect(generator.next() == 0x6E78_9E6A_A1B9_65F4)
        var other = LayoutLabRandom(seed: 42)
        let values = (0 ..< 3).map { _ in other.below(1000) }
        var again = LayoutLabRandom(seed: 42)
        #expect(values == (0 ..< 3).map { _ in again.below(1000) })
    }

    @Test func aBudgetOfFourMovesAtMostFourLettersAndNeverCostsMore() throws {
        let (optimizer, problem) = try englishOptimizer()
        let shipped = optimizer.score(problem.base)
        let gentle = optimizer.optimize(maxMoved: 4, settings: quick)
        #expect(gentle.moved.count <= 4)
        #expect(gentle.cost <= shipped.cost + 1e-12)
        #expect(problem.isPermutation(gentle.assignment))
    }

    @Test func aBudgetOfZeroKeepsTheShippedLayout() throws {
        let (optimizer, problem) = try englishOptimizer()
        let result = optimizer.optimize(maxMoved: 0, settings: quick)
        #expect(result.assignment == problem.base)
        #expect(result.moved.isEmpty)
    }

    @Test func theFreeOptimumIsAtLeastAsCheapAsAnyBudgetedOne() throws {
        let (optimizer, _) = try englishOptimizer()
        let free = optimizer.optimize(maxMoved: nil, settings: quick)
        let gentle = optimizer.optimize(maxMoved: 4, settings: quick)
        #expect(free.cost <= gentle.cost + 1e-9)
    }

    @Test func everyResultKeepsTheTapMostFrequentOnItsKey() throws {
        let (optimizer, problem) = try englishOptimizer()
        let text = optimizer.text
        let occurrences = Dictionary(uniqueKeysWithValues: zip(text.letters, text.letterOccurrences))
        for budget in [nil, 4, 8] as [Int?] {
            let result = optimizer.optimize(maxMoved: budget, settings: quick)
            for key in 0 ..< 9 {
                let tap = try #require(result.assignment[LabSlot(key: key, gesture: .tap)])
                for slot in problem.movableSlots where slot.key == key && slot.gesture != .tap {
                    #expect(occurrences[tap]! >= occurrences[result.assignment[slot]!]!, "key \(key), budget \(String(describing: budget))")
                }
            }
        }
    }

    @Test func theFullSearchFindsAtLeastWhatPythonFoundOnTheSameData() throws {
        let (optimizer, _) = try englishOptimizer()
        let free = optimizer.optimize(maxMoved: nil, settings: AnnealingSettings(restarts: 24, steps: 20_000, seed: 0))
        // Python's best under this text model (optimized_layout.json): 1.55516.
        #expect(free.cost <= 1.5552 + 1e-4, "found \(free.cost)")
    }
}

// MARK: - The generated variants

@Suite(.serialized)
@MainActor
struct OptimizedVariantTests {
    private static let table = OptimizedArrangements.table

    private func baseId(_ variantId: String) -> String {
        for (_, suffix) in OptimizedArrangements.variants where variantId.hasSuffix("_" + suffix) {
            return String(variantId.dropLast(suffix.count + 1))
        }
        return variantId
    }

    @Test func thereAreVariantsAndEachIsRegisteredWithItsBase() throws {
        #expect(Self.table.count >= 20, "the pipeline has run for the cased languages")
        for id in Self.table.keys.sorted() {
            let metadata = try #require(KeyboardRegistry.available.first { $0.id == id }, "\(id) is not registered")
            #expect(metadata.variantOf == baseId(id))
            #expect(metadata.family == .optimized)
            #expect(metadata.variant != .standard)
            #expect(KeyboardRegistry.available.contains { $0.id == baseId(id) })
        }
    }

    @Test func aVariantIsTheBaseLayoutWithItsLettersPermuted() throws {
        for id in Self.table.keys.sorted() {
            let variant = try LayoutProblem(languageId: id)
            let base = try LayoutProblem(languageId: baseId(id))
            #expect(Set(variant.movableSlots) == Set(base.movableSlots), "\(id): same letter slots")
            #expect(variant.isPermutation(variant.base) && Set(variant.letters) == Set(base.letters), "\(id): same letters")
            #expect(variant.fixedCharacters == base.fixedCharacters, "\(id): punctuation did not move")
            #expect(variant.triggerSlots == base.triggerSlots, "\(id): compose triggers did not move")
            #expect(variant.cycleSlot == base.cycleSlot, "\(id): the accent cycle did not move")
            #expect(variant.duplicateSlots == base.duplicateSlots, "\(id): a repeated letter stays put")
            // Forms that are not just the capital (final letters, accented capitals) travel with their letter;
            // the capital itself is a return swipe only on a swipe slot, so it comes and goes with the slot kind.
            func special(_ forms: [String: String]) -> [String: String] {
                forms.filter { $0.value != $0.key.uppercased() && $0.value != $0.key.keyboardUppercased(with: base.locale) }
            }
            #expect(special(variant.formOfLetter) == special(base.formOfLetter), "\(id): what a letter's form types travels with the letter")
        }
    }

    @Test func everythingThatIsNotALetterIsBindingForBindingTheBases() throws {
        for id in Self.table.keys.sorted() {
            let variant = try #require(KeyboardRegistry.load(id: id))
            let base = try #require(KeyboardRegistry.load(id: baseId(id)))
            #expect(variant.modes.keys == base.modes.keys, "\(id)")
            for (modeName, mode) in base.modes where modeName == ModeNames.numeric || modeName == ModeNames.main {
                for (keyId, key) in mode.keys {
                    for (gesture, binding) in key.bindings {
                        if case let .commitText(text) = binding.action, text.count == 1, text.first?.isLetter == true,
                           modeName == ModeNames.main { continue }
                        #expect(variant.mode(modeName)?.keys[keyId]?.bindings[gesture] == binding, "\(id) \(modeName) \(keyId).\(gesture)")
                    }
                }
            }
            #expect(variant.validate().isEmpty, "\(id)")
        }
    }

    @Test func aVariantTypesEveryCharacterItsBaseTypes() throws {
        for id in Self.table.keys.sorted() {
            let variant = try #require(KeyboardRegistry.load(id: id))
            let base = try #require(KeyboardRegistry.load(id: baseId(id)))
            func typable(_ definition: KeyboardDefinition) -> Set<String> {
                var out = Set<String>()
                for (_, mode) in definition.modes {
                    for (_, key) in mode.keys {
                        for (_, binding) in key.bindings {
                            if case let .commitText(text) = binding.action { out.insert(text) }
                            if case let .commitText(text)? = binding.returnAction { out.insert(text) }
                            if case let .compose(trigger) = binding.action { out.insert(trigger) }
                        }
                    }
                }
                return out
            }
            #expect(typable(variant) == typable(base), "\(id)")
        }
    }

    @Test func aVariantTypesThroughTheRealInputEngine() throws {
        let samples = ["de_DE": "Schöne Grüße aus Köln", "fr_FR": "Où est la bibliothèque", "es_ES": "El niño comió pingüino",
                       "ru_RU": "Привет мир", "el_GR": "Καλημέρα κόσμε", "pl_PL": "Zażółć gęślą jaźń",
                       "fi_FI": "Hyvää päivää", "sv_SE": "Hur mår du i dag", "it_IT": "Perché non andiamo",
                       "pt_PT": "O coração não tem razão", "hr_HR": "Čovjek je šetao", "uk_UA": "Добрий день",
                       "vi_VN": "xin chao", "tl_PH": "Magandang umaga po", "ca_ES": "Bon dia, com estàs",
                       "et_EE": "Tere hommikust", "en_US": "the quick brown fox jumps over the lazy dog",
                       "he_IL": "שלום עולם מה שלומך", "ar": "مرحبا بالعالم", "fa_IR": "سلام دنیا"]
        var checked = 0
        for id in Self.table.keys.sorted() {
            guard let sample = samples[baseId(id)] else { continue }
            let scenario = KeyboardScenario(language: id, autoCapitalize: false)
            let baseScenario = KeyboardScenario(language: baseId(id), autoCapitalize: false)
            let missing = scenario.type(sample)
            let baseMissing = baseScenario.type(sample)
            #expect(missing == baseMissing, "\(id): \(missing) vs base \(baseMissing)")
            #expect(scenario.text == baseScenario.text, "\(id)")
            checked += 1
        }
        #expect(checked >= 20)
    }

    @Test func theGeneratedClaimsHoldUnderTheCheckedInCorpora() throws {
        let corpora = repositoryRoot().appendingPathComponent("tools/layout-lab/corpora")
        for id in Self.table.keys.sorted() {
            let base = baseId(id)
            let text = try String(contentsOf: corpora.appendingPathComponent("\(base).tsv"), encoding: .utf8)
            let table = try #require(CorpusTable(parsing: text), "\(base)")
            let problem = try LayoutProblem(languageId: base)
            let optimizer = LayoutOptimizer(problem: problem, text: TextModel(table: table, problem: problem))
            let shipped = optimizer.score(problem.base)
            let variant = optimizer.score(try LayoutProblem(languageId: id).base)
            #expect(variant.cost <= shipped.cost + 1e-12, "\(id) must not cost more than the layout it replaces")
            if id.hasSuffix("_optimized") {
                #expect(variant.moved.count <= LabBudget.gentle, "\(id): gentle means at most \(LabBudget.gentle) letters moved")
            }
        }
    }

    @Test func gentleNeverMovesMoreThanFullAndNeverCostsLess() throws {
        let corpora = repositoryRoot().appendingPathComponent("tools/layout-lab/corpora")
        for id in Self.table.keys.sorted() where id.hasSuffix("_optimized") {
            let base = baseId(id)
            guard Self.table[base + "_full"] != nil else { continue }
            let table = try #require(CorpusTable(
                parsing: try String(contentsOf: corpora.appendingPathComponent("\(base).tsv"), encoding: .utf8)
            ))
            let problem = try LayoutProblem(languageId: base)
            let optimizer = LayoutOptimizer(problem: problem, text: TextModel(table: table, problem: problem))
            let gentle = optimizer.score(try LayoutProblem(languageId: id).base)
            let full = optimizer.score(try LayoutProblem(languageId: base + "_full").base)
            #expect(full.cost <= gentle.cost + 1e-9, "\(base): the unconstrained optimum is at least as cheap")
        }
    }

    @Test func theLanguageListShowsOneRowPerLanguageAndNeverMatchesTheSystemToAVariant() {
        let rows = LanguageMetadata.allLanguages.filter { $0.variantOf == nil }
        #expect(rows.count == LanguageMetadata.allLanguages.count - Self.table.count - 1, "variants are not rows (+ the hand-declared English one)")
        #expect(!LanguageMetadata.systemMatchableLanguages.contains { $0.variantOf != nil })
        #expect(LanguageSettings.detectSystemLanguage(preferredLanguages: ["de-DE"]) == "de_DE")
    }

    @Test func theGlobeKeyTellsAVariantFromItsBase() throws {
        let optimized = KeyboardScenario(language: "de_DE_optimized", autoCapitalize: false)
        let full = KeyboardScenario(language: "de_DE_full", autoCapitalize: false)
        let standard = KeyboardScenario(language: "de_DE", autoCapitalize: false)
        #expect(standard.viewModel.currentLanguageLabel == "DE")
        #expect(optimized.viewModel.currentLanguageLabel == "DE+")
        #expect(full.viewModel.currentLanguageLabel == "DE++")
    }
}

// MARK: - Switching layouts in the settings

@MainActor
struct LayoutSwitchingTests {
    private func settings(_ enabled: [String], selected: String, pinned: String? = nil) -> LanguageSettings {
        let defaults = InMemoryUserDefaults()
        LanguageSettings.saveEnabledLanguageIds(enabled, to: defaults)
        defaults.set(selected, forKey: SettingsKey.selectedLanguageId.rawValue)
        if let pinned { defaults.set(pinned, forKey: SettingsKey.pinnedLanguageId.rawValue) }
        return LanguageSettings(userDefaults: defaults)
    }

    @Test func switchingKeepsThePlaceTheSelectionAndThePin() {
        let languages = settings(["en_US", "de_DE", "fr_FR"], selected: "de_DE", pinned: "de_DE")
        languages.switchLayout(from: "de_DE", to: "de_DE_optimized")
        #expect(languages.enabledLanguageIds == ["en_US", "de_DE_optimized", "fr_FR"])
        #expect(languages.selectedLanguageId == "de_DE_optimized")
        #expect(languages.pinnedLanguageId == "de_DE_optimized")
        languages.switchLayout(from: "de_DE_optimized", to: "de_DE")
        #expect(languages.enabledLanguageIds == ["en_US", "de_DE", "fr_FR"])
    }

    @Test func switchingALanguageThatIsNotEnabledDoesNothing() {
        let languages = settings(["en_US"], selected: "en_US")
        languages.switchLayout(from: "de_DE", to: "de_DE_optimized")
        #expect(languages.enabledLanguageIds == ["en_US"])
    }

    @Test func switchingToALayoutThatIsAlreadyEnabledMergesInsteadOfDuplicating() {
        let languages = settings(["de_DE", "de_DE_optimized"], selected: "de_DE")
        languages.switchLayout(from: "de_DE", to: "de_DE_optimized")
        #expect(languages.enabledLanguageIds == ["de_DE_optimized"])
        #expect(languages.selectedLanguageId == "de_DE_optimized")
    }

    @Test func nobodysLayoutChangesOnItsOwn() {
        // A stored, enabled standard layout stays the standard layout: nothing in
        // the settings path swaps in a variant.
        let languages = settings(["en_US", "de_DE"], selected: "de_DE")
        languages.reloadFromStore()
        #expect(languages.enabledLanguageIds == ["en_US", "de_DE"])
        #expect(languages.selectedLanguageId == "de_DE")
        #expect(LanguageSettings.resolvedLanguageId("de_DE") == "de_DE")
    }
}


// MARK: - Forms travel with their letters

@MainActor
struct FormTravelTests {
    private func locate(_ letter: String, in definition: KeyboardDefinition) -> (KeyDefinition, GestureType)? {
        guard let main = definition.mode(ModeNames.main) else { return nil }
        for (_, key) in main.keys {
            for (gesture, binding) in key.bindings where binding.action == .commitText(letter) && (gesture == .tap || gesture.isSwipe) {
                return (key, gesture)
            }
        }
        return nil
    }

    /// What the gesture that makes the letter's form types, wherever the letter sits.
    private func form(of letter: String, in definition: KeyboardDefinition) -> String? {
        guard let (key, gesture) = locate(letter, in: definition) else { return nil }
        let binding = gesture == .tap ? key.bindings[.circularClockwise] : key.bindings[gesture]
        let action = gesture == .tap ? binding?.action : binding?.returnAction
        if case let .commitText(text)? = action { return text }
        return nil
    }

    @Test func hebrewFinalLettersStayOnTheirBaseLettersInEveryVariant() throws {
        let finals = ["כ": "ך", "פ": "ף", "צ": "ץ", "נ": "ן"]
        for id in ["he_IL", "he_IL_optimized", "he_IL_full"] {
            let definition = try #require(KeyboardRegistry.load(id: id))
            for (base, final) in finals {
                #expect(form(of: base, in: definition) == final, "\(id): \(base) must still give \(final) on its form gesture")
            }
        }
    }

    @Test func aFinalLetterThatLandsOnATapIsOnItsCircle() throws {
        // Wherever the optimizer put a letter with a final form, the form is reachable:
        // a return swipe on a swipe slot, the circle on a tap (a tap has no return swipe).
        for id in ["he_IL_optimized", "he_IL_full"] {
            let definition = try #require(KeyboardRegistry.load(id: id))
            let main = try #require(definition.mode(ModeNames.main))
            for base in ["כ", "פ", "צ", "נ"] {
                let (key, gesture) = try #require(locate(base, in: definition))
                if gesture == .tap {
                    #expect(key.bindings[.circularClockwise] != nil && key.bindings[.circularCounterclockwise] != nil, "\(id) \(base)")
                } else {
                    #expect(key.bindings[gesture]?.returnAction != nil, "\(id) \(base)")
                }
                _ = main
            }
        }
    }

    @Test func everyCharacterOfTheBaseStillHasAGestureInTheCaselessVariants() throws {
        for base in ["he_IL", "ar", "fa_IR"] {
            for suffix in ["optimized", "full"] {
                let id = "\(base)_\(suffix)"
                let variant = try #require(KeyboardRegistry.load(id: id))
                let original = try #require(KeyboardRegistry.load(id: base))
                func produced(_ definition: KeyboardDefinition) -> Set<String> {
                    var out = Set<String>()
                    for (_, mode) in definition.modes {
                        for (_, key) in mode.keys {
                            for (_, binding) in key.bindings {
                                if case let .commitText(text) = binding.action { out.insert(text) }
                                if case let .commitText(text)? = binding.returnAction { out.insert(text) }
                            }
                        }
                    }
                    return out
                }
                #expect(produced(variant) == produced(original), "\(id)")
            }
        }
    }

    @Test func caselessVariantsAreRegisteredAndUrduAndThaiAreNot() {
        for id in ["he_IL", "ar", "fa_IR"] {
            #expect(OptimizedArrangements.table["\(id)_optimized"] != nil && OptimizedArrangements.table["\(id)_full"] != nil, "\(id)")
        }
        for id in ["ur", "th_TH", "hi_IN", "ja_JP", "ko_KR"] {
            #expect(OptimizedArrangements.table["\(id)_optimized"] == nil, "\(id) is not modelled")
        }
    }

    @Test func greekHasNoRepeatedLetterAndItsCapitalKeepsTheAccent() throws {
        let greek = try #require(KeyboardRegistry.load(id: "el_GR"))
        let (key, gesture) = try #require(locate("ί", in: greek))
        #expect(gesture == .swipeUp)
        #expect(form(of: "ί", in: greek) == "Ί")
        #expect("ί".keyboardUppercased(with: Locale(identifier: "el_GR")) == "Ί")
        #expect(form(of: "ω", in: greek) != nil || locate("ω", in: greek) != nil)
        _ = key
        // The shifted mode agrees with the return swipe.
        let shifted = try #require(greek.mode(ModeNames.shifted))
        #expect(shifted.keys.values.contains { $0.bindings.values.contains { $0.action == .commitText("Ί") } })
    }
}

// MARK: - What a language starts on

@MainActor
struct StartingLayoutTests {
    @Test func aLanguageWithAnOptimizedVariantStartsOnIt() {
        #expect(LanguageSettings.startingLayoutId(for: "de_DE") == "de_DE_optimized")
        #expect(LanguageSettings.startingLayoutId(for: "he_IL") == "he_IL_optimized")
        #expect(LanguageSettings.startingLayoutId(for: "en_US") == "en_US_optimized", "the frozen English one")
    }

    @Test func everythingElseStartsOnItself() {
        for id in ["ur", "th_TH", "hi_IN", "ja_JP", "ko_KR", "en_US_thumbkey", "de_DE_optimized", "de_DE_full", "no_such_layout"] {
            #expect(LanguageSettings.startingLayoutId(for: id) == id, "\(id)")
        }
    }

    private func settings(enabled: [String]? = nil, selected: String? = nil) -> LanguageSettings {
        let defaults = InMemoryUserDefaults()
        if let enabled { LanguageSettings.saveEnabledLanguageIds(enabled, to: defaults) }
        if let selected { defaults.set(selected, forKey: SettingsKey.selectedLanguageId.rawValue) }
        return LanguageSettings(userDefaults: defaults)
    }

    @Test func aFreshInstallationStartsOnTheSystemLanguagesOptimizedLayout() {
        let languages = settings()
        let expected = LanguageSettings.startingLayoutId(for: LanguageSettings.detectSystemLanguage())
        #expect(languages.enabledLanguageIds == [expected])
        #expect(languages.selectedLanguageId == expected)
    }

    @Test func aStoredSelectionWithoutAListIsNotRewritten() {
        // An older version stored only the selection: that is somebody's choice.
        let languages = settings(selected: "de_DE")
        #expect(languages.enabledLanguageIds == ["de_DE"])
        #expect(languages.selectedLanguageId == "de_DE")
    }

    @Test func languagesAlreadyEnabledAreNeverChanged() {
        let languages = settings(enabled: ["de_DE", "fr_FR", "ru_RU"], selected: "fr_FR")
        languages.reloadFromStore()
        #expect(languages.enabledLanguageIds == ["de_DE", "fr_FR", "ru_RU"])
        #expect(languages.selectedLanguageId == "fr_FR")
    }

    @Test func turningALanguageOnStartsItOnTheOptimizedLayoutAndTheMenuCanGoBack() throws {
        let languages = settings(enabled: ["en_US"], selected: "en_US")
        let german = try #require(LanguageMetadata.language(withId: "de_DE"))
        languages.toggleLanguage(LanguageSettings.startingLayout(for: german))
        #expect(languages.enabledLanguageIds == ["en_US", "de_DE_optimized"])
        languages.switchLayout(from: "de_DE_optimized", to: "de_DE")
        #expect(languages.enabledLanguageIds == ["en_US", "de_DE"], "Standard is one menu pick away")
    }
}
