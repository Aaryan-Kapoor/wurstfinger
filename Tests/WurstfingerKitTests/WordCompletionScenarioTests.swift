//
//  WordCompletionScenarioTests.swift
//  WurstfingerKitTests
//
//  Word completions through the whole keyboard: gestures into the real touch
//  engine, the pipeline, the view model, the row's height and the settings.
//

import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import WurstfingerKit
@testable import WurstfingerScenarioKit

/// A keyboard whose deadlines the test moves and whose dictionary it wrote.
@MainActor
private struct Session {
    let scenario: KeyboardScenario
    let timers: ManualTimerSource
    let source: ScriptedCompletionSource

    var viewModel: KeyboardViewModel { scenario.viewModel }
    var completions: WordCompletions { viewModel.completions }
    var text: String { scenario.text }
    var candidates: [String] { completions.candidates.map(\.word) }

    init(
        enabled: Bool = true,
        language: String = "en_US",
        settings: [SettingsKey: Any] = [:],
        words: [String] = ["hello", "help", "helpful", "helmet", "world"],
        languages: Set<String>? = nil
    ) {
        let source = ScriptedCompletionSource(words: words, languages: languages)
        var all = settings
        if enabled { all[.wordCompletionsEnabled] = true }
        let timers = ManualTimerSource()
        scenario = KeyboardScenario(
            language: language, autoCapitalize: false, settings: all,
            timers: timers, completionSource: source
        )
        self.source = source
        self.timers = timers
    }

    /// Lets the engine's deferred lookup run, as the run loop would.
    func settle() {
        timers.advance(by: 0.001)
    }

    /// Types `string` a key at a time, the lookup running after each, as it
    /// does between a person's keystrokes.
    func typeSettling(_ string: String) {
        for character in string {
            scenario.type(String(character))
            settle()
        }
    }
}

@MainActor
struct WordCompletionRowTests {
    @Test func theRowIsOffByDefault() {
        let session = Session(enabled: false)
        #expect(!session.viewModel.typingBehavior.areWordCompletionsEnabled)
        #expect(session.viewModel.accessoryRowHeight == 0)
        session.typeSettling("hel")
        #expect(session.candidates.isEmpty)
        #expect(session.source.lookups.isEmpty)
    }

    @Test func theSettingGivesTheRowItsHeightAndTheLayoutMakesRoom() {
        let off = Session(enabled: false)
        let on = Session()
        #expect(on.viewModel.accessoryRowHeight == KeyboardConstants.Layout.completionRowHeight)
        let width = on.scenario.containerWidth
        let heightOff = off.viewModel.layoutMetrics(forContainerWidth: width).totalHeight
        let heightOn = on.viewModel.layoutMetrics(forContainerWidth: width).totalHeight
        #expect(heightOn > heightOff, "the keyboard grows (or its keys shrink) by the row")
        #expect(on.viewModel.layoutMetrics(forContainerWidth: width).accessoryHeight == KeyboardConstants.Layout.completionRowHeight)
        #expect(off.viewModel.layoutMetrics(forContainerWidth: width).accessoryHeight == 0)
    }

    @Test func aReloadFollowsTheSetting() {
        let session = Session(enabled: false)
        session.scenario.defaults.set(true, forKey: SettingsKey.wordCompletionsEnabled.rawValue)
        #expect(session.viewModel.accessoryRowHeight == 0, "a store write is invisible until the reload, as in production")
        session.viewModel.reloadSettings()
        #expect(session.viewModel.accessoryRowHeight == KeyboardConstants.Layout.completionRowHeight)
        session.scenario.defaults.set(false, forKey: SettingsKey.wordCompletionsEnabled.rawValue)
        session.viewModel.reloadSettings()
        #expect(session.viewModel.accessoryRowHeight == 0)
    }

    @Test func aLanguageWithoutADictionaryGivesTheHeightBack() {
        let session = Session(words: ["hello"], languages: ["en"])
        #expect(session.viewModel.accessoryRowHeight > 0)
        session.viewModel.loadDefinition(for: "de_DE")
        #expect(session.viewModel.accessoryRowHeight == 0)
        session.viewModel.loadDefinition(for: "en_US")
        #expect(session.viewModel.accessoryRowHeight > 0)
    }

    @Test func aViewModelWithoutADictionaryShowsNoRowEvenWithTheSettingOn() {
        // The default for previews, tests and tools: nothing to complete with.
        let scenario = KeyboardScenario(autoCapitalize: false, settings: [.wordCompletionsEnabled: true])
        #expect(scenario.viewModel.accessoryRowHeight == 0)
    }

    @Test func theSettingDefaultsAreOffForTheRowAndOnForLearning() {
        let behavior = TypingBehavior.load(from: EphemeralDefaults())
        #expect(!behavior.areWordCompletionsEnabled)
        #expect(behavior.learnsWords)
        #expect(behavior.learnedWordsClearToken == nil)
    }
}

@MainActor
struct WordCompletionTypingTests {
    @Test func typingAWordFillsTheRowAfterTheKeystrokeNotDuringIt() {
        let session = Session()
        session.scenario.type("hel")
        #expect(session.text == "hel")
        #expect(session.candidates.isEmpty, "nothing was looked up inside the keystrokes")
        #expect(session.source.lookups.isEmpty)
        session.settle()
        #expect(session.candidates == ["hello", "help", "helpful"])
        #expect(session.source.lookups == ["hel"], "three keystrokes, one lookup, for the word as it stands")
    }

    @Test func aKeystrokeSchedulesNoMoreThanOneLookup() {
        let session = Session()
        session.scenario.type("helpf")
        #expect(session.completions.refreshCount == 0)
        session.settle()
        #expect(session.completions.refreshCount == 1)
        #expect(session.candidates == ["helpful"])
    }

    @Test func aSpaceEmptiesTheRow() {
        let session = Session()
        session.typeSettling("hel")
        #expect(!session.candidates.isEmpty)
        session.scenario.tap(UtilitySlot.space)
        session.settle()
        #expect(session.candidates.isEmpty)
    }

    @Test func tappingACompletionTypesTheRestOfTheWordAndASpace() {
        let session = Session()
        session.typeSettling("hel")
        let help = session.completions.candidates[1]
        #expect(session.viewModel.acceptCompletion(help))
        #expect(session.text == "help ")
        #expect(session.candidates.isEmpty)
    }

    @Test func aNewWordStartsFreshAfterAnAccept() {
        let session = Session()
        session.typeSettling("hel")
        session.viewModel.acceptTopCompletion()
        session.typeSettling("wor")
        #expect(session.text == "hello wor")
        #expect(session.candidates == ["world"])
    }

    @Test func autoCapitalizationFollowsAnAcceptedWord() {
        let scenario = KeyboardScenario(
            autoCapitalize: true, settings: [.wordCompletionsEnabled: true],
            timers: ManualTimerSource(), completionSource: ScriptedCompletionSource(words: ["thanks"])
        )
        // "Thanks." then a new sentence: the accept does not leave a stale shift.
        scenario.type("Th")
        scenario.viewModel.completions.refresh()
        scenario.viewModel.acceptTopCompletion()
        #expect(scenario.text == "Thanks ")
        #expect(scenario.mode == ModeNames.main)
    }
}

@MainActor
struct WordCompletionGestureTests {
    private let swipeDown = CGSize(width: 0, height: 60)

    @Test func aSwipeDownOnTheSpaceBarTakesTheFirstCompletion() {
        let session = Session()
        session.typeSettling("hel")
        let outcome = session.scenario.drag(UtilitySlot.space, by: swipeDown)
        #expect(outcome.slidePhases == [.swipeDown])
        #expect(session.text == "hello ")
        #expect(session.candidates.isEmpty)
    }

    @Test func aSwipeDownWithNothingToTakeTypesNothing() {
        let session = Session()
        session.scenario.type("x")
        session.settle()
        let outcome = session.scenario.drag(UtilitySlot.space, by: swipeDown)
        #expect(outcome.slidePhases == [.swipeDown])
        #expect(session.text == "x")
    }

    @Test func aSwipeDownWithTheRowOffTypesNothing() {
        let session = Session(enabled: false)
        session.scenario.type("hel")
        session.scenario.drag(UtilitySlot.space, by: swipeDown)
        #expect(session.text == "hel")
    }

    @Test func aSwipeDownInASensitiveFieldTypesNothing() {
        let session = Session()
        session.typeSettling("hel")
        session.viewModel.fieldTraits = FieldTraits(isSensitive: true)
        session.scenario.drag(UtilitySlot.space, by: swipeDown)
        #expect(session.text == "hel")
    }

    @Test func theSpaceBarsOtherGesturesAreUntouched() {
        let session = Session()
        session.typeSettling("hel")
        session.scenario.tap(UtilitySlot.space)
        #expect(session.text == "hel ")
        session.scenario.drag(UtilitySlot.space, by: CGSize(width: -40, height: 0))
        #expect(session.scenario.cursor < 4, "the cursor slide still moves the cursor")
    }

    @Test func theBindingExistsOnTheSpaceBarOfEveryMode() throws {
        let definition = try #require(KeyboardRegistry.load(id: "en_US"))
        for (name, mode) in definition.modes {
            guard let space = mode.key(for: UtilitySlot.space) else { continue }
            #expect(space.bindings[.swipeDown]?.action == .acceptCompletion, "\(name)")
        }
    }

    @Test func voiceOverOffersItAsACustomActionOnTheSpaceBar() throws {
        let definition = try #require(KeyboardRegistry.load(id: "en_US"))
        let space = try #require(definition.mode(ModeNames.main)?.key(for: UtilitySlot.space))
        let action = try #require(space.accessibilityActions.first { $0.gesture == .swipeDown })
        #expect(action.name == "Accept suggestion")
    }

    @Test func theActionIsOfferedOnlyWhileTheRowIsOn() throws {
        let definition = try #require(KeyboardRegistry.load(id: "en_US"))
        let space = try #require(definition.mode(ModeNames.main)?.key(for: UtilitySlot.space))
        let withRow = KeyAccessibilityActions.actions(for: space, offersCompletionAction: true)
        let withoutRow = KeyAccessibilityActions.actions(for: space, offersCompletionAction: false)
        #expect(withRow.contains { $0.name == "Accept suggestion" })
        #expect(!withoutRow.contains { $0.name == "Accept suggestion" })
        #expect(withRow.count == withoutRow.count + 1)
        // Other keys are untouched.
        let delete = try #require(definition.mode(ModeNames.main)?.key(for: UtilitySlot.delete))
        #expect(KeyAccessibilityActions.actions(for: delete, offersCompletionAction: false) == delete.accessibilityActions)
    }

    @Test func theLabelTogglesOnTheSameKeyStillWork() {
        let session = Session()
        session.scenario.drag(UtilitySlot.space, by: CGSize(width: 0, height: -60))
        #expect(session.scenario.defaults.bool(forKey: SettingsKey.areExtraSymbolLabelsHidden.rawValue))
    }
}

@MainActor
struct WordCompletionAutoSpaceTests {
    private func acceptedHello() -> Session {
        let session = Session()
        session.typeSettling("hel")
        session.viewModel.acceptTopCompletion()
        return session
    }

    @Test func theNextSpaceTapDoesNotDoubleTheSpace() {
        let session = acceptedHello()
        session.scenario.tap(UtilitySlot.space)
        #expect(session.text == "hello ")
        session.scenario.tap(UtilitySlot.space)
        #expect(session.text == "hello  ", "only the first press is absorbed")
    }

    @Test func punctuationTakesTheAutoSpaceBack() {
        let session = acceptedHello()
        session.scenario.type(".")
        #expect(session.text == "hello.")
    }

    @Test func aLetterMakesTheSpaceOrdinary() {
        let session = acceptedHello()
        session.typeSettling("x")
        session.scenario.tap(UtilitySlot.space)
        #expect(session.text == "hello x ")
    }

    @Test func deletingTheAutoSpaceMakesTheNextSpaceOrdinary() {
        let session = acceptedHello()
        session.scenario.tap(UtilitySlot.delete)
        #expect(session.text == "hello")
        session.scenario.tap(UtilitySlot.space)
        #expect(session.text == "hello ")
    }

    @Test func aMovedCaretMakesTheNextSpaceOrdinary() {
        let session = acceptedHello()
        session.scenario.target.adjustTextPosition(byCharacterOffset: -2) // the host moved the caret
        session.scenario.tap(UtilitySlot.space)
        #expect(session.text == "hell o ", "the caret was not behind the auto-space, so the space types")
    }

    @Test func theDoubleSpacePeriodDoesNotSeeTheAbsorbedSpace() {
        let session = Session(settings: [.doubleSpacePeriodEnabled: true])
        session.typeSettling("hel")
        session.viewModel.acceptTopCompletion()
        session.scenario.tap(UtilitySlot.space)
        #expect(session.text == "hello ")
    }

    @Test func withTheRowOffASpaceIsAlwaysASpace() {
        let session = Session(enabled: false)
        session.scenario.type("hello ")
        session.scenario.tap(UtilitySlot.space)
        #expect(session.text == "hello  ")
    }
}

@MainActor
struct WordCompletionFieldTests {
    @Test func aSensitiveFieldHidesTheRowAndStopsEveryLookup() {
        let session = Session()
        session.typeSettling("hel")
        #expect(!session.candidates.isEmpty)
        session.viewModel.fieldTraits = FieldTraits(isSensitive: true)
        #expect(session.viewModel.accessoryRowHeight == 0)
        #expect(session.candidates.isEmpty)

        let lookups = session.source.lookups.count
        session.typeSettling("p")
        #expect(session.source.lookups.count == lookups, "nothing typed there reaches the dictionary")
        #expect(session.candidates.isEmpty)

        session.viewModel.fieldTraits = .standard
        #expect(session.viewModel.accessoryRowHeight == KeyboardConstants.Layout.completionRowHeight)
        session.settle()
        #expect(session.candidates.first?.hasPrefix("help") == true)
    }

    @Test func aHostThatWantsNoSuggestionsHidesTheRow() {
        let session = Session()
        session.viewModel.fieldTraits = FieldTraits(suppressesCompletions: true)
        #expect(session.viewModel.accessoryRowHeight == 0)
        session.typeSettling("hel")
        #expect(session.source.lookups.isEmpty)
    }

    @Test func movingBetweenFieldsKeepsTheSettingsReloadsOwnMask() {
        let session = Session()
        session.viewModel.fieldTraits = FieldTraits(isSensitive: true)
        session.viewModel.reloadSettings()
        #expect(session.viewModel.accessoryRowHeight == 0, "a reload does not unmask a sensitive field")
    }
}

@MainActor
struct WordCompletionLearningTests {
    @Test func aNameTypedTwiceIsOfferedAndCanBeCleared() {
        let session = Session(words: ["hello"])
        for _ in 0 ..< 2 {
            session.typeSettling("Anjalika")
            session.scenario.tap(UtilitySlot.space)
            session.settle()
        }
        #expect(session.completions.learned.count == 1)
        session.typeSettling("anj")
        #expect(session.candidates == ["Anjalika"])

        // The host app asks for a clear: a new token in the shared settings.
        session.scenario.defaults.set("token-1", forKey: SettingsKey.learnedWordsClearToken.rawValue)
        session.viewModel.reloadSettings()
        #expect(session.completions.learned.count == 0)
    }

    @Test func learningCanBeSwitchedOff() {
        let session = Session(settings: [.learnsWords: false], words: ["hello"])
        for _ in 0 ..< 2 {
            session.typeSettling("Anjalika")
            session.scenario.tap(UtilitySlot.space)
            session.settle()
        }
        #expect(session.completions.learned.count == 0)
    }

    @Test func nothingTypedInASensitiveFieldIsLearned() {
        let session = Session(words: ["hello"])
        session.viewModel.fieldTraits = FieldTraits(isSensitive: true)
        for _ in 0 ..< 3 {
            session.typeSettling("Anjalika")
            session.scenario.tap(UtilitySlot.space)
            session.settle()
        }
        #expect(session.completions.learned.count == 0)
    }

    @Test func aViewModelUnderTestNeverTouchesTheRealLearnedFile() {
        // Persistence is for the keyboard itself; a test's view model, even one
        // that persists settings, keeps the list in memory.
        let viewModel = KeyboardViewModel(userDefaults: EphemeralDefaults(), shouldPersistSettings: true)
        _ = viewModel.completions
        #expect(UnitTestHost.isActive)
        #expect(viewModel.completions.source is NullCompletionSource)
    }
}

@MainActor
struct WordCompletionSpeechTests {
    @Test func theTopCompletionIsSpokenAfterAPauseUnderVoiceOverGestureTyping() {
        let session = Session(settings: [.voiceOverGestureTyping: true])
        var spoken: [SpokenTarget] = []
        session.viewModel.spokenFeedback = SpokenFeedback(isActive: { true }, announce: { spoken.append($0) })
        session.typeSettling("hel")
        spoken.removeAll() // the per-key targets
        session.timers.advance(by: WordCompletions.announcementPause + 0.1)
        #expect(spoken == [.name("Suggestion: hello")])
    }

    @Test func nothingIsSpokenWithoutVoiceOver() {
        let session = Session()
        var spoken: [SpokenTarget] = []
        session.viewModel.spokenFeedback = SpokenFeedback(isActive: { false }, announce: { spoken.append($0) })
        session.typeSettling("hel")
        session.timers.advance(by: 5)
        #expect(spoken.isEmpty)
    }

    @Test func nothingIsSpokenWithGestureTypingOff() {
        let session = Session()
        var spoken: [SpokenTarget] = []
        session.viewModel.spokenFeedback = SpokenFeedback(isActive: { true }, announce: { spoken.append($0) })
        session.typeSettling("hel")
        session.timers.advance(by: 5)
        #expect(spoken.isEmpty)
    }
}

@MainActor
struct CompletionRowViewTests {
    @Test func aRightToLeftLanguageReadsRightToLeft() {
        for id in ["ar_SA", "he_IL", "fa_IR", "ur_PK"] {
            #expect(KeyboardAccessoryRow.direction(of: Locale(identifier: id)) == .rightToLeft, "\(id)")
        }
        for id in ["en_US", "de_DE", "ru_RU", "hi_IN"] {
            #expect(KeyboardAccessoryRow.direction(of: Locale(identifier: id)) == .leftToRight, "\(id)")
        }
        #expect(KeyboardAccessoryRow.direction(of: nil) == .leftToRight)
    }

    @Test func theTypedPartIsDeEmphasizedAndTheRestIsNot() {
        let styled = CompletionRow.styled(Completion(word: "hello", typed: "hel"))
        #expect(String(styled.characters) == "hello")
        let runs = styled.runs.map { (String(styled[$0.range].characters), $0.foregroundColor) }
        #expect(runs.map(\.0) == ["hel", "lo"])
        #expect(runs[0].1 != runs[1].1)
    }

    @Test func aWordNothingWasTypedOfIsAllForeground() {
        let styled = CompletionRow.styled(Completion(word: "hello", typed: ""))
        #expect(styled.runs.count == 1)
    }

    @Test func theRowRendersInBothStylesAndSchemes() {
        let candidates = [
            Completion(word: "hello", typed: "hel"), Completion(word: "help", typed: "hel"),
            Completion(word: "helpful", typed: "hel"),
        ]
        for style in [KeyboardStyle.classic, .liquidGlass] {
            for scheme in [ColorScheme.light, .dark] {
                let row = CompletionRow(candidates: candidates, keyboardStyle: style, accept: { _ in })
                    .frame(width: 320, height: 40)
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: row)
                #expect(renderer.cgImage != nil, "\(style) \(scheme)")
            }
        }
    }
}
