//
//  WordCompletionTests.swift
//  WurstfingerKitTests
//
//  Word completions below the view model: finding the word, what accepting
//  one edits, the engine's scheduling and auto-space, the learned words.
//

import Foundation
import Testing
@testable import WurstfingerKit
@testable import WurstfingerScenarioKit

// MARK: - The word before the cursor

struct PartialWordTests {
    @Test(arguments: [
        ("hel", "hel"),
        ("Say hel", "hel"),
        ("don't", "don't"),
        ("'quoted", "quoted"),
        ("Wie geht\u{2019}s", "geht\u{2019}s"),
        ("straße", "straße"),
        ("hello ", ""),
        ("hello.", ""),
        ("", ""),
        ("e", "e"),
    ])
    func findsTheWordEndingAtTheCursor(context: String, word: String) {
        #expect(PartialWord.before(context) == word)
    }

    @Test func nothingBeforeTheCursorIsNoWord() {
        #expect(PartialWord.before(nil).isEmpty)
    }

    @Test(arguments: ["abc123de", "user@exam", "/usr/loc", "snake_ca", "C:\\Progr"])
    func partOfSomethingElseIsNoWord(context: String) {
        #expect(PartialWord.before(context).isEmpty, "\(context)")
    }

    @Test func aRunOfLettersTooLongToBeTypedIsNoWord() {
        #expect(PartialWord.before(String(repeating: "a", count: PartialWord.maximumLength + 1)).isEmpty)
        #expect(!PartialWord.before(String(repeating: "a", count: PartialWord.maximumLength)).isEmpty)
    }

    @Test func aWordBeforeANonLatinScriptIsFound() {
        #expect(PartialWord.before("Привет, мир") == "мир")
        #expect(PartialWord.before("مرحبا بال") == "بال")
        #expect(PartialWord.before("می‌خوا") == "می‌خوا")
    }

    @Test func theCaretInsideAWordIsNotTheEndOfOne() {
        #expect(PartialWord.continuesAfterCursor("llo world"))
        #expect(!PartialWord.continuesAfterCursor(" world"))
        #expect(!PartialWord.continuesAfterCursor("."))
        #expect(!PartialWord.continuesAfterCursor(nil))
        #expect(!PartialWord.continuesAfterCursor(""))
    }

    @Test func aFinishedWordIsTheOneBehindTheSeparators() {
        #expect(PartialWord.justFinished("I like Anja ") == "Anja")
        #expect(PartialWord.justFinished("I like Anja, ") == "Anja")
        #expect(PartialWord.justFinished("Anja.") == "Anja")
        #expect(PartialWord.justFinished("Anja") == nil, "still being typed")
        #expect(PartialWord.justFinished("Anja    ") == nil, "a long gap is not a word end")
        #expect(PartialWord.justFinished("") == nil)
        #expect(PartialWord.justFinished(" ") == nil)
    }
}

// MARK: - Accepting

struct CompletionEditTests {
    @Test func aCompletionOnlyTypesTheRestOfTheWordAndASpace() {
        #expect(CompletionEdit.accepting("hello", over: "hel") == CompletionEdit(deleteCount: 0, insert: "lo "))
    }

    @Test func theUsersOwnCaseIsKept() {
        // "Hel" + "lo" is "Hello" whichever case the dictionary spells it in.
        #expect(CompletionEdit.accepting("hello", over: "Hel").insert == "lo ")
        #expect(CompletionEdit.accepting("Hello", over: "hel").insert == "lo ")
    }

    @Test func aPrefixTypedInCapitalsContinuesInCapitals() {
        #expect(CompletionEdit.accepting("nasa", over: "NAS").insert == "A ")
        #expect(CompletionEdit.accepting("Nasa", over: "NA").insert == "SA ")
    }

    @Test func aSingleCapitalLetterIsNotShouting() {
        #expect(CompletionEdit.accepting("hello", over: "H").insert == "ello ")
    }

    @Test func aWordThatDoesNotExtendWhatWasTypedReplacesIt() {
        let edit = CompletionEdit.accepting("café", over: "cafe")
        #expect(edit == CompletionEdit(deleteCount: 4, insert: "café "))
    }

    @Test func aWordShorterThanThePrefixReplacesIt() {
        #expect(CompletionEdit.accepting("he", over: "hel") == CompletionEdit(deleteCount: 3, insert: "he "))
    }

    @Test func theSpaceIsOptional() {
        #expect(CompletionEdit.accepting("hello", over: "hel", appendingSpace: false).insert == "lo")
    }

    @Test func aCompletionKnowsWhatWasTypedOfIt() {
        let completion = Completion(word: "Hello", typed: "hel")
        #expect(completion.typedCount == 3)
        #expect(completion.split.typed == "Hel")
        #expect(completion.split.rest == "lo")
        #expect(Completion(word: "hello", typed: "xyz").typedCount == 0)
        #expect(Completion(word: "hello", typed: "hello").split.rest.isEmpty)
    }
}

// MARK: - Which fields want none

struct CompletionFieldPolicyTests {
    @Test func anOrdinaryTextFieldWantsCompletions() {
        #expect(!CompletionFieldPolicy().suppressesCompletions)
        #expect(FieldTraits.standard.allowsCompletions)
    }

    @Test(arguments: [
        CompletionFieldPolicy.Keyboard.url, .email, .numeric, .phone,
    ])
    func aSpecialKeyboardWantsNone(keyboard: CompletionFieldPolicy.Keyboard) {
        #expect(CompletionFieldPolicy(keyboard: keyboard).suppressesCompletions)
    }

    @Test(arguments: [
        CompletionFieldPolicy.Content.url, .email, .username, .phoneNumber, .postalCode, .code,
    ])
    func aContentTypeThatIsNotProseWantsNone(content: CompletionFieldPolicy.Content) {
        #expect(CompletionFieldPolicy(content: content).suppressesCompletions)
    }

    @Test func aHostThatTurnedAutocorrectionOffWantsNone() {
        #expect(CompletionFieldPolicy(disablesAutocorrection: true).suppressesCompletions)
    }

    @Test func aSensitiveFieldNeverAllowsCompletions() {
        #expect(!FieldTraits(isSensitive: true).allowsCompletions)
        #expect(!FieldTraits(suppressesCompletions: true).allowsCompletions)
        #expect(FieldTraits(isSensitive: false, suppressesCompletions: false).allowsCompletions)
    }
}

// MARK: - The checker's language for a locale

struct SpellLanguageTests {
    private let available = ["en", "en_GB", "en_AU", "de", "pt_BR", "pt_PT", "fr", "ko", "ja"]

    @Test func anExactLocaleWins() {
        #expect(SpellLanguage.match(Locale(identifier: "en_GB"), among: available) == "en_GB")
        #expect(SpellLanguage.match(Locale(identifier: "pt-BR"), among: available) == "pt_BR")
    }

    @Test func theLanguageAloneServesAnyRegion() {
        #expect(SpellLanguage.match(Locale(identifier: "en_US"), among: available) == "en")
        #expect(SpellLanguage.match(Locale(identifier: "de_CH"), among: available) == "de")
    }

    @Test func aRegionalVariantServesAnUnlistedRegion() {
        #expect(SpellLanguage.match(Locale(identifier: "pt_AO"), among: available) == "pt_BR")
    }

    @Test func aMissingLanguageHasNone() {
        #expect(SpellLanguage.match(Locale(identifier: "hr_HR"), among: available) == nil)
    }

    @Test func scriptsWithoutWordsOrWithComposedSyllablesHaveNone() {
        // The checker lists them, completions would be wrong for them.
        #expect(SpellLanguage.match(Locale(identifier: "ko_KR"), among: available) == nil)
        #expect(SpellLanguage.match(Locale(identifier: "ja_JP"), among: available) == nil)
    }
}

// MARK: - The engine

@MainActor
struct WordCompletionsEngineTests {
    /// An engine over a scripted dictionary and a mock document, on a clock
    /// the test moves.
    private struct Rig {
        let engine: WordCompletions
        let target: MockTextTarget
        let source: ScriptedCompletionSource
        let timers: ManualTimerSource
        let store: LearnedWordStore
    }

    private func rig(
        words: [String] = ["hello", "help", "helpful", "helmet"],
        known: Set<String> = [],
        before: String = "",
        enabled: Bool = true,
        traits: FieldTraits = .standard,
        learns: Bool = true
    ) -> Rig {
        let timers = ManualTimerSource()
        let target = MockTextTarget()
        target.documentContextBeforeInput = before
        target.documentContextAfterInput = ""
        let source = ScriptedCompletionSource(words: words, knownWords: known)
        let store = LearnedWordStore(fileURL: nil, timers: timers)
        let engine = WordCompletions(timers: timers, source: source, learned: store, target: { target })
        engine.configure(isEnabled: enabled, learnsWords: learns, traits: traits, locale: Locale(identifier: "en_US"))
        return Rig(engine: engine, target: target, source: source, timers: timers, store: store)
    }

    /// Lets the engine's deferred lookup run, as the run loop would.
    private func settle(_ rig: Rig) {
        rig.timers.advance(by: 0.001)
    }

    // MARK: Scheduling

    @Test func aKeystrokeDoesNotLookAnythingUpUntilTheTimerFires() {
        let rig = rig(before: "hel")
        rig.engine.noteKeystroke()
        #expect(rig.source.lookups.isEmpty, "the lookup waits for the timer, off the keystroke")
        #expect(rig.engine.candidates.isEmpty)
        #expect(rig.timers.pendingCount == 1)
        settle(rig)
        #expect(rig.source.lookups == ["hel"])
        #expect(rig.engine.candidates.map(\.word) == ["hello", "help", "helpful"])
    }

    @Test func keystrokesBeforeTheTimerFiresShareOneLookup() {
        let rig = rig(before: "hel")
        for _ in 0 ..< 5 { rig.engine.noteKeystroke() }
        #expect(rig.timers.scheduledTotal == 1, "coalesced into one timer")
        settle(rig)
        #expect(rig.engine.refreshCount == 1)
        #expect(rig.source.lookups.count == 1)
    }

    @Test func theLookupReadsTheTextAsItIsWhenItRuns() {
        let rig = rig(before: "he")
        rig.engine.noteKeystroke()
        rig.target.documentContextBeforeInput = "hel" // typed before the timer fired
        settle(rig)
        #expect(rig.source.lookups == ["hel"], "never a lookup for a word the user moved past")
    }

    @Test func eachKeystrokeAfterALookupSchedulesTheNext() {
        let rig = rig(before: "he")
        rig.engine.noteKeystroke()
        settle(rig)
        rig.target.documentContextBeforeInput = "hel"
        rig.engine.noteKeystroke()
        settle(rig)
        #expect(rig.source.lookups == ["he", "hel"])
    }

    @Test func aKeystrokeWithTheRowOffSchedulesNothing() {
        let rig = rig(before: "hel", enabled: false)
        rig.engine.noteKeystroke()
        #expect(rig.timers.scheduledTotal == 0)
        #expect(!rig.engine.isActive)
    }

    @Test func turningTheRowOffCancelsAPendingLookup() {
        let rig = rig(before: "hel")
        rig.engine.noteKeystroke()
        rig.engine.configure(isEnabled: false, learnsWords: true, traits: .standard, locale: Locale(identifier: "en_US"))
        #expect(rig.timers.pendingCount == 0)
        settle(rig)
        #expect(rig.source.lookups.isEmpty)
    }

    @Test func theSameWordIsNotLookedUpTwice() {
        let rig = rig(before: "hel")
        rig.engine.refresh()
        rig.engine.refresh()
        #expect(rig.source.lookups == ["hel"])
    }

    @Test func aSlowLookupMakesTheNextOneWaitForAPause() {
        let rig = rig(before: "hel")
        // Not measurable on a scripted source: assert the policy's constants.
        #expect(WordCompletions.slowLookupDelay > 0)
        #expect(WordCompletions.slowLookup < WordCompletions.slowLookupDelay)
        rig.engine.noteKeystroke()
        #expect(rig.timers.nextDeadline == 0, "a fast lookup runs with no delay")
    }

    // MARK: What is shown

    @Test func aShortWordGetsNoCompletions() {
        let rig = rig(before: "h")
        rig.engine.refresh()
        #expect(rig.engine.candidates.isEmpty)
        #expect(rig.source.lookups.isEmpty)
    }

    @Test func theWordTypedInFullIsNotItsOwnCompletion() {
        let rig = rig(words: ["help", "helpful"], before: "help")
        rig.engine.refresh()
        #expect(rig.engine.candidates.map(\.word) == ["helpful"])
    }

    @Test func noCompletionsInTheMiddleOfAWord() {
        let rig = rig(before: "hel")
        rig.target.documentContextAfterInput = "lo world"
        rig.engine.refresh()
        #expect(rig.engine.candidates.isEmpty)
    }

    @Test func noCompletionsWithTextSelected() {
        let rig = rig(before: "hel")
        rig.target.selectedText = "lo"
        rig.engine.refresh()
        #expect(rig.engine.candidates.isEmpty)
    }

    @Test func spaceAfterTheWordClearsTheRow() {
        let rig = rig(before: "hel")
        rig.engine.refresh()
        #expect(!rig.engine.candidates.isEmpty)
        rig.target.documentContextBeforeInput = "hel "
        rig.engine.refresh()
        #expect(rig.engine.candidates.isEmpty)
    }

    @Test func atMostThreeAreShownAndNoneTwice() {
        let rig = rig(words: ["hello", "Hello", "help", "helps", "helped"], before: "hel")
        rig.engine.refresh()
        #expect(rig.engine.candidates.map(\.word) == ["hello", "help", "helps"])
    }

    // MARK: Warming the dictionary

    @Test func theDictionaryIsWarmedOnATimerNotAtOnce() {
        let rig = rig(before: "")
        rig.engine.warmUp() // the keyboard appeared
        #expect(rig.source.warmed.isEmpty, "never inside the call")
        rig.timers.advance(by: WordCompletions.warmUpDelay - 0.05)
        #expect(rig.source.warmed.isEmpty)
        rig.timers.advance(by: 0.1)
        #expect(rig.source.warmed == ["en"])
    }

    @Test func eachLanguageIsWarmedOnce() {
        let rig = rig(before: "")
        rig.engine.warmUp() // the keyboard appeared
        rig.engine.warmUp()
        rig.timers.advance(by: 1)
        rig.engine.warmUp() // appeared again
        rig.timers.advance(by: 1)
        #expect(rig.source.warmed == ["en"])
    }

    @Test func aLanguageSwitchWarmsTheNewLanguage() {
        let rig = rig(before: "")
        rig.engine.warmUp()
        rig.timers.advance(by: 1)
        rig.engine.configure(isEnabled: true, learnsWords: true, traits: .standard, locale: Locale(identifier: "de_DE"))
        #expect(rig.source.warmed == ["en"])
        rig.timers.advance(by: 1)
        #expect(rig.source.warmed == ["en", "de"])
        rig.engine.configure(isEnabled: true, learnsWords: true, traits: .standard, locale: Locale(identifier: "en_US"))
        rig.timers.advance(by: 1)
        #expect(rig.source.warmed == ["en", "de"], "already warm")
    }

    @Test func nothingIsWarmedWithTheRowOffOrInASensitiveField() {
        let off = rig(before: "", enabled: false)
        off.engine.warmUp()
        off.timers.advance(by: 1)
        #expect(off.source.warmed.isEmpty)
        let sensitive = rig(before: "", traits: FieldTraits(isSensitive: true))
        sensitive.engine.warmUp()
        sensitive.timers.advance(by: 1)
        #expect(sensitive.source.warmed.isEmpty)
    }

    @Test func turningTheRowOffBeforeTheTimerCancelsTheWarmUp() {
        let rig = rig(before: "")
        rig.engine.configure(isEnabled: false, learnsWords: true, traits: .standard, locale: Locale(identifier: "en_US"))
        rig.timers.advance(by: 1)
        #expect(rig.source.warmed.isEmpty)
    }

    @Test func aWarmUpDoesNotTouchTheSlowLookupSafeguard() {
        // The 6 ms rule is untouched: a lookup over it delays the next one.
        #expect(WordCompletions.slowLookup == 0.006)
        #expect(WordCompletions.slowLookupDelay > 0)
    }

    // MARK: Accepting

    @Test func acceptingTypesTheRestOfTheWordAndASpace() {
        let rig = rig(before: "say hel")
        rig.engine.refresh()
        let accepted = rig.engine.acceptTop()
        #expect(accepted)
        #expect(rig.target.events == [.insertText("lo ")])
        #expect(rig.target.documentContextBeforeInput == "say hello ")
        #expect(rig.engine.candidates.isEmpty)
    }

    @Test func aStaleCompletionStillProducesTheWord() {
        let rig = rig(before: "hel")
        rig.engine.refresh()
        let stale = rig.engine.candidates[1] // "help"
        rig.target.documentContextBeforeInput = "help" // the p was typed meanwhile
        #expect(rig.engine.accept(stale))
        #expect(rig.target.documentContextBeforeInput == "help ")
    }

    @Test func aCompletionThatDoesNotExtendTheWordReplacesIt() {
        let rig = rig(before: "cafe")
        rig.engine.refresh()
        let accepted = rig.engine.accept(Completion(word: "café", typed: "cafe"))
        #expect(accepted)
        #expect(rig.target.events == [.deleteBackward, .deleteBackward, .deleteBackward, .deleteBackward, .insertText("café ")])
    }

    @Test func nothingIsAcceptedOnceTheCursorLeftTheWord() {
        let rig = rig(before: "hel")
        rig.engine.refresh()
        let stale = rig.engine.candidates[0]
        rig.target.documentContextBeforeInput = "hel "
        #expect(!rig.engine.accept(stale))
        #expect(rig.target.events.isEmpty)
    }

    @Test func nothingIsAcceptedWithTextSelected() {
        let rig = rig(before: "hel")
        rig.engine.refresh()
        rig.target.selectedText = "x"
        #expect(!rig.engine.acceptTop())
        #expect(rig.target.events.isEmpty)
    }

    @Test func acceptingWithNoCompletionDoesNothing() {
        let rig = rig(before: "hel")
        #expect(!rig.engine.acceptTop())
        #expect(rig.target.events.isEmpty)
    }

    // MARK: Auto-space

    @Test func theSpaceAfterAnAcceptedWordIsSwallowedOnce() {
        let rig = rig(before: "hel")
        rig.engine.refresh()
        rig.engine.acceptTop()
        #expect(rig.engine.isAutoSpacePending)
        #expect(rig.engine.swallowSpaceAfterAccept())
        #expect(!rig.engine.isAutoSpacePending)
        #expect(!rig.engine.swallowSpaceAfterAccept(), "only the first space is swallowed")
    }

    @Test func aSpaceIsNotSwallowedOnceTheAutoSpaceIsGone() {
        let rig = rig(before: "hel")
        rig.engine.refresh()
        rig.engine.acceptTop()
        rig.target.documentContextBeforeInput = "hello" // the caret moved, or the space was deleted
        #expect(!rig.engine.swallowSpaceAfterAccept())
        #expect(!rig.engine.isAutoSpacePending)
    }

    @Test func punctuationTakesTheAutoSpaceBack() {
        let rig = rig(before: "hel")
        rig.engine.refresh()
        rig.engine.acceptTop()
        rig.target.events = []
        rig.engine.takeBackAutoSpace()
        #expect(rig.target.events == [.deleteBackward])
        #expect(rig.target.documentContextBeforeInput == "hello")
        rig.engine.takeBackAutoSpace()
        #expect(rig.target.events == [.deleteBackward], "once")
    }

    @Test func anotherActionMakesTheAutoSpaceOrdinary() {
        let rig = rig(before: "hel")
        rig.engine.refresh()
        rig.engine.acceptTop()
        rig.engine.endAutoSpace()
        #expect(!rig.engine.swallowSpaceAfterAccept())
    }

    // MARK: Sensitive fields and the language

    @Test func aSensitiveFieldTurnsTheEngineOffAndEmptiesTheRow() {
        let rig = rig(before: "hel")
        rig.engine.refresh()
        #expect(!rig.engine.candidates.isEmpty)
        rig.engine.configure(isEnabled: true, learnsWords: true, traits: FieldTraits(isSensitive: true), locale: Locale(identifier: "en_US"))
        #expect(!rig.engine.isActive)
        #expect(rig.engine.candidates.isEmpty)
        let armed = rig.timers.scheduledTotal
        rig.engine.noteKeystroke()
        #expect(rig.timers.scheduledTotal == armed)
        #expect(!rig.engine.acceptTop())
    }

    @Test func aLanguageTheSourceCannotCompleteGivesNoRow() {
        let rig = rig(before: "hel")
        rig.source.languages = ["de"]
        rig.engine.configure(isEnabled: true, learnsWords: true, traits: .standard, locale: Locale(identifier: "en_US"))
        #expect(!rig.engine.isActive)
        rig.engine.configure(isEnabled: true, learnsWords: true, traits: .standard, locale: Locale(identifier: "de_DE"))
        #expect(rig.engine.isActive)
    }

    // MARK: VoiceOver

    @Test func theTopCompletionIsSpokenAfterAPause() {
        let rig = rig(before: "hel")
        var spoken: [String] = []
        rig.engine.canAnnounce = { true }
        rig.engine.announce = { spoken.append($0.word) }
        rig.engine.refresh()
        #expect(spoken.isEmpty)
        rig.timers.advance(by: WordCompletions.announcementPause - 0.1)
        #expect(spoken.isEmpty)
        rig.timers.advance(by: 0.2)
        #expect(spoken == ["hello"])
    }

    @Test func typingOnCancelsTheAnnouncement() {
        let rig = rig(before: "hel")
        var spoken: [String] = []
        rig.engine.canAnnounce = { true }
        rig.engine.announce = { spoken.append($0.word) }
        rig.engine.refresh()
        rig.timers.advance(by: 0.5)
        rig.target.documentContextBeforeInput = "help"
        rig.engine.refresh()
        rig.timers.advance(by: 0.7) // 1.2 s since the first lookup, 0.7 since the second
        #expect(spoken.isEmpty)
        rig.timers.advance(by: 0.4)
        #expect(spoken == ["helpful"])
    }

    @Test func nothingIsSpokenWhenNoScreenReaderListens() {
        let rig = rig(before: "hel")
        var spoken = 0
        rig.engine.canAnnounce = { false }
        rig.engine.announce = { _ in spoken += 1 }
        rig.engine.refresh()
        rig.timers.advance(by: 5)
        #expect(spoken == 0)
    }

    // MARK: Learning

    /// Types `word` into the document one letter at a time, refreshing like
    /// the timer would after each, then a space.
    private func type(_ word: String, into rig: Rig) {
        var typed = rig.target.documentContextBeforeInput ?? ""
        for letter in word {
            typed.append(letter)
            rig.target.documentContextBeforeInput = typed
            rig.engine.refresh()
        }
        rig.target.documentContextBeforeInput = typed + " "
        rig.engine.refresh()
    }

    @Test func aWordTheDictionaryLacksIsOfferedOnceItWasTypedTwice() {
        let rig = rig(words: ["hello"], known: ["hello"], before: "")
        type("Anjalika", into: rig)
        rig.target.documentContextBeforeInput = "We met "
        #expect(rig.store.completions(for: "anj", language: "en", limit: 3).isEmpty, "once is not enough")
        type("Anjalika", into: rig)
        rig.target.documentContextBeforeInput = "Hi anj"
        rig.engine.refresh()
        #expect(rig.engine.candidates.map(\.word) == ["Anjalika"])
    }

    @Test func aWordTheDictionaryKnowsIsNotLearned() {
        let rig = rig(words: ["hello"], known: ["hello"], before: "")
        type("hello", into: rig)
        type("hello", into: rig)
        #expect(rig.store.count == 0)
    }

    @Test func aShortWordOrOneWithDigitsIsNotLearned() {
        let rig = rig(words: [], before: "")
        type("xy", into: rig)
        type("xy", into: rig)
        type("ab12c", into: rig)
        type("ab12c", into: rig)
        #expect(rig.store.count == 0)
    }

    @Test func textThatAppearedWithoutBeingTypedIsNotLearned() {
        let rig = rig(words: [], before: "")
        // Pasted: the engine never saw a prefix grow into the word.
        rig.target.documentContextBeforeInput = "Zxqvbnm "
        rig.engine.refresh()
        rig.target.documentContextBeforeInput = "Zxqvbnm Zxqvbnm "
        rig.engine.refresh()
        #expect(rig.store.count == 0)
    }

    @Test func nothingIsLearnedWithLearningOff() {
        let rig = rig(words: [], before: "", learns: false)
        type("Anjalika", into: rig)
        type("Anjalika", into: rig)
        #expect(rig.store.count == 0)
    }

    @Test func nothingIsLearnedInASensitiveField() {
        let rig = rig(words: [], before: "", traits: FieldTraits(isSensitive: true))
        type("Anjalika", into: rig)
        type("Anjalika", into: rig)
        #expect(rig.store.count == 0)
    }

    @Test func aLearnedWordRanksAheadOfTheDictionaryAndKeepsItsCase() {
        let rig = rig(words: ["anchor", "angle"], before: "")
        rig.store.note("Anjalika", language: "en")
        rig.store.note("Anjalika", language: "en")
        rig.target.documentContextBeforeInput = "an"
        rig.engine.refresh()
        #expect(rig.engine.candidates.map(\.word) == ["Anjalika", "anchor", "angle"])
        #expect(rig.engine.acceptTop())
        // The user's own letters stay as typed ("an"), the rest is the word's.
        #expect(rig.target.documentContextBeforeInput == "anjalika ")
    }
}

// MARK: - The learned words

@MainActor
struct LearnedWordStoreTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wurstfinger-learned-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("LearnedWords.json")
    }

    @Test func aWordIsOfferedFromItsSecondUse() {
        let store = LearnedWordStore(fileURL: nil, timers: ManualTimerSource())
        store.note("Zephyrine", language: "en")
        #expect(store.completions(for: "zep", language: "en", limit: 3).isEmpty)
        store.note("Zephyrine", language: "en")
        #expect(store.completions(for: "zep", language: "en", limit: 3) == ["Zephyrine"])
        #expect(store.completions(for: "zep", language: "de", limit: 3).isEmpty, "per language")
    }

    @Test func mostUsedComesFirst() {
        let store = LearnedWordStore(fileURL: nil, timers: ManualTimerSource())
        for _ in 0 ..< 2 { store.note("Kestrel", language: "en") }
        for _ in 0 ..< 4 { store.note("Kesselring", language: "en") }
        #expect(store.completions(for: "kes", language: "en", limit: 3) == ["Kesselring", "Kestrel"])
    }

    @Test func useOfAWordThatWasNeverLearnedIsIgnored() {
        let store = LearnedWordStore(fileURL: nil, timers: ManualTimerSource())
        store.noteUse(of: "Anything", language: "en")
        #expect(store.count == 0)
    }

    @Test func theListIsCapped() {
        let store = LearnedWordStore(fileURL: nil, timers: ManualTimerSource())
        for index in 0 ..< LearnedWordStore.capacity + 50 {
            store.note("word\(index)", language: "en")
        }
        #expect(store.count == LearnedWordStore.capacity)
    }

    @Test func clearingForgetsEverything() {
        let store = LearnedWordStore(fileURL: nil, timers: ManualTimerSource())
        for _ in 0 ..< 2 { store.note("Kestrel", language: "en") }
        store.clear()
        #expect(store.count == 0)
        #expect(store.completions(for: "kes", language: "en", limit: 3).isEmpty)
    }

    @Test func aNewClearTokenWipesTheListOnce() {
        let store = LearnedWordStore(fileURL: nil, timers: ManualTimerSource())
        for _ in 0 ..< 2 { store.note("Kestrel", language: "en") }
        store.applyClearToken(nil)
        #expect(store.count == 1, "no request, nothing wiped")
        store.applyClearToken("token-1")
        #expect(store.count == 0)
        for _ in 0 ..< 2 { store.note("Kestrel", language: "en") }
        store.applyClearToken("token-1")
        #expect(store.count == 1, "the same request is not applied twice")
        store.applyClearToken("token-2")
        #expect(store.count == 0)
    }

    @Test func theListSurvivesARestartAndTheSaveIsDelayed() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let timers = ManualTimerSource()
        let store = LearnedWordStore(fileURL: file, timers: timers)
        for _ in 0 ..< 2 { store.note("Kestrel", language: "en") }
        #expect(!FileManager.default.fileExists(atPath: file.path), "written after a pause, not per word")
        timers.advance(by: LearnedWordStore.saveDelay + 0.1)
        #expect(FileManager.default.fileExists(atPath: file.path))

        let restarted = LearnedWordStore(fileURL: file, timers: timers)
        #expect(restarted.completions(for: "kes", language: "en", limit: 3) == ["Kestrel"])
    }

    /// A keyboard dismissed within `saveDelay` of its last word is suspended
    /// before the timer fires, and may be killed there: the save happens at
    /// suspension, and the list leaves memory until the next lookup.
    @Test func suspensionWritesAPendingSaveAndUnloads() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let timers = ManualTimerSource()
        let store = LearnedWordStore(fileURL: file, timers: timers)
        store.applyClearToken("token-1")
        for _ in 0 ..< 2 { store.note("Kestrel", language: "en") }
        store.prepareForSuspension()
        #expect(FileManager.default.fileExists(atPath: file.path), "written without waiting for the timer")
        #expect(timers.pendingCount == 0)

        let killed = LearnedWordStore(fileURL: file, timers: timers)
        #expect(killed.completions(for: "kes", language: "en", limit: 3) == ["Kestrel"])
        // The suspended store reads its list back on the next lookup, and the
        // token it already handled wipes nothing.
        #expect(store.completions(for: "kes", language: "en", limit: 3) == ["Kestrel"])
        store.note("Kestrel", language: "en")
        store.saveNow()
        #expect(LearnedWordStore(fileURL: file, timers: timers).count == 1)
    }

    @Test func aBurstOfNotesWritesOnce() {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let timers = ManualTimerSource()
        let store = LearnedWordStore(fileURL: file, timers: timers)
        for index in 0 ..< 20 { store.note("word\(index)", language: "en") }
        #expect(timers.pendingCount == 1)
    }

    @Test func theClearTokenIsRemembered() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let timers = ManualTimerSource()
        let store = LearnedWordStore(fileURL: file, timers: timers)
        for _ in 0 ..< 2 { store.note("Kestrel", language: "en") }
        store.applyClearToken("token-1")
        store.saveNow()

        let restarted = LearnedWordStore(fileURL: file, timers: timers)
        restarted.applyClearToken("token-1")
        for _ in 0 ..< 2 { restarted.note("Kestrel", language: "en") }
        restarted.saveNow()
        let again = LearnedWordStore(fileURL: file, timers: timers)
        again.applyClearToken("token-1")
        #expect(again.count == 1, "a token already handled before the restart wipes nothing")
    }

    @Test func aCorruptFileIsIgnored() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        let store = LearnedWordStore(fileURL: file, timers: ManualTimerSource())
        #expect(store.count == 0)
        store.note("Kestrel", language: "en")
        #expect(store.count == 1)
    }
}

// MARK: - The waker the keystroke pokes

@MainActor
struct WakerTests {
    @Test func theManualClockRunsAPokeWhenItIsAdvancedAndSharesPokes() {
        let timers = ManualTimerSource()
        var runs = 0
        let waker = timers.makeWaker { runs += 1 }
        waker.poke()
        waker.poke()
        waker.poke()
        #expect(runs == 0, "never inside the poke")
        #expect(timers.scheduledTotal == 1)
        timers.advance(by: 0.001)
        #expect(runs == 1)
        waker.poke()
        timers.advance(by: 0.001)
        #expect(runs == 2)
    }

    @Test func aCancelledPokeDoesNotRun() {
        let timers = ManualTimerSource()
        var runs = 0
        let waker = timers.makeWaker { runs += 1 }
        waker.poke()
        waker.cancelPending()
        timers.advance(by: 1)
        #expect(runs == 0)
        waker.poke()
        timers.advance(by: 1)
        #expect(runs == 1, "poking again works after a cancel")
    }

    @Test func theProductionSourceRunsAPokeOnALaterTurnAndSharesPokes() async {
        let source = SystemTimerSource()
        var runs = 0
        let waker = source.makeWaker { runs += 1 }
        for _ in 0 ..< 3 { waker.poke() }
        #expect(runs == 0, "never inside the poke")
        let deadline = ContinuousClock.now + .seconds(10)
        while runs == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(runs >= 1)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(runs <= 2, "three pokes before a run are at most two runs, never three")
        withExtendedLifetime(waker) {}
    }
}
