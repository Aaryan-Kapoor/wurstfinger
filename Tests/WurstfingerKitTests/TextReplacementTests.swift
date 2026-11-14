//
//  TextReplacementTests.swift
//  WurstfingerTests
//
//  Text replacement (#259): the validated table and its storage, the
//  middleware that expands shortcuts at a word boundary and undoes them on
//  delete, and the interplay with the rest of the pipeline.
//

import Foundation
import Testing
@testable import WurstfingerKit
@testable import WurstfingerScenarioKit

private func entry(_ shortcut: String, _ phrase: String) -> TextReplacementEntry {
    TextReplacementEntry(shortcut: shortcut, phrase: phrase)
}

private let sampleTable = TextReplacementTable(entries: [
    entry("omw", "On my way!"),
    entry("gm", "good morning"),
    entry("brb", "be right back"),
    entry("addr", "1 Infinite Loop\nCupertino"),
])

// MARK: - Table

struct TextReplacementTableTests {
    @Test(arguments: [
        ("omw", "On my way!", nil as TextReplacementError?),
        ("", "x", .emptyShortcut),
        ("o m", "x", .shortcutContainsWhitespace),
        ("tab\there", "x", .shortcutContainsWhitespace),
        ("new\nline", "x", .shortcutContainsWhitespace),
        (String(repeating: "a", count: 32), "x", nil),
        (String(repeating: "a", count: 33), "x", .shortcutTooLong),
        ("a", "", .emptyPhrase),
        ("a", String(repeating: "p", count: 1000), nil),
        ("a", String(repeating: "p", count: 1001), .phraseTooLong),
    ])
    func validationRules(shortcut: String, phrase: String, expected: TextReplacementError?) {
        do {
            try TextReplacementTable.validate(shortcut: shortcut, phrase: phrase)
            #expect(expected == nil)
        } catch {
            #expect(error == expected)
        }
    }

    @Test func aShortcutMayBeEditedWithoutClashingWithItself() throws {
        let existing = [entry("omw", "a"), entry("gm", "b")]
        #expect(throws: TextReplacementError.duplicateShortcut) {
            try TextReplacementTable.validate(shortcut: "omw", phrase: "x", existing: existing)
        }
        try TextReplacementTable.validate(shortcut: "omw", phrase: "x", existing: existing, replacing: "omw")
        #expect(throws: TextReplacementError.duplicateShortcut) {
            try TextReplacementTable.validate(shortcut: "gm", phrase: "x", existing: existing, replacing: "omw")
        }
    }

    @Test func aFullTableTakesNoMoreEntries() {
        let full = (0 ..< TextReplacementTable.maxEntries).map { entry("s\($0)", "p") }
        #expect(throws: TextReplacementError.tableFull) {
            try TextReplacementTable.validate(shortcut: "extra", phrase: "p", existing: full)
        }
        #expect(TextReplacementTable(entries: full + [entry("extra", "p")]).entries.count == TextReplacementTable.maxEntries)
    }

    @Test func exactMatchReturnsThePhraseAsStored() {
        #expect(sampleTable.lookup("omw") == "On my way!")
    }

    @Test func aCapitalisedShortcutCapitalisesThePhrase() {
        #expect(sampleTable.lookup("Gm") == "Good morning")
        #expect(sampleTable.lookup("Brb") == "Be right back")
    }

    @Test func anAllCapitalShortcutShoutsThePhrase() {
        #expect(sampleTable.lookup("GM") == "GOOD MORNING")
        #expect(sampleTable.lookup("OMW") == "ON MY WAY!")
    }

    @Test func otherCapitalisationKeepsThePhraseAsStored() {
        #expect(sampleTable.lookup("gM") == "good morning")
    }

    @Test func aSingleCapitalLetterCapitalisesRatherThanShouts() {
        let table = TextReplacementTable(entries: [entry("a", "and then")])
        #expect(table.lookup("A") == "And then")
    }

    @Test func anExactMatchBeatsACaseInsensitiveOne() {
        let table = TextReplacementTable(entries: [entry("Gm", "Guten Morgen"), entry("gm", "good morning")])
        #expect(table.lookup("Gm") == "Guten Morgen")
        #expect(table.lookup("gm") == "good morning")
    }

    @Test func unknownWordsAreNotShortcuts() {
        #expect(sampleTable.lookup("omwx") == nil)
        #expect(sampleTable.lookup("") == nil)
        #expect(sampleTable.lookup("om") == nil)
    }

    @Test func invalidAndRepeatedEntriesAreDroppedOnBuild() {
        let table = TextReplacementTable(entries: [
            entry("ok", "fine"), entry("has space", "x"), entry("ok", "again"), entry("empty", ""),
        ])
        #expect(table.entries == [entry("ok", "fine")])
        #expect(table.lookup("ok") == "fine")
    }

    @Test func storageRoundTripsThroughJSON() {
        let entries = [entry("omw", "On my way!"), entry("emoji", "👍🏽 done — “ok”")]
        let json = TextReplacementTable.encode(entries)
        let table = TextReplacementTable.decode(json)
        #expect(table.entries == entries)
        #expect(table.source == json)
        #expect(json.contains("\"shortcut\":\"omw\""))
        #expect(json.contains("\"phrase\":\"On my way!\""))
    }

    @Test(arguments: [nil, "", "not json", "{}", "[1,2]", "[{\"shortcut\":1}]"] as [String?])
    func unreadableStorageIsAnEmptyTable(_ json: String?) {
        #expect(TextReplacementTable.decode(json).isEmpty)
    }

    @Test func aReloadThatFindsTheSameJSONKeepsTheTable() {
        let store = InMemoryUserDefaults()
        let json = TextReplacementTable.encode([entry("omw", "On my way!")])
        store.set(json, forKey: SettingsKey.textReplacements.rawValue)

        let first = TypingBehavior.load(from: store)
        let second = TypingBehavior.load(from: store, reusing: first)
        #expect(second == first)
        #expect(second.textReplacements.source == json)

        store.set(TextReplacementTable.encode([entry("gm", "good morning")]), forKey: SettingsKey.textReplacements.rawValue)
        let third = TypingBehavior.load(from: store, reusing: second)
        #expect(third != second)
        #expect(third.textReplacements.lookup("gm") == "good morning")
        #expect(third.textReplacements.lookup("omw") == nil)
    }

    @Test func aFreshInstallationHasNoShortcuts() {
        #expect(TypingBehavior.load(from: InMemoryUserDefaults()).textReplacements.isEmpty)
    }
}

// MARK: - Middleware

@MainActor
private struct Bench {
    let target = MockTextTarget()
    let middleware: TextReplacementMiddleware
    private let text: TextInputMiddleware

    init(table: TextReplacementTable = sampleTable, before: String = "", selection: String? = nil, locale: String = "en_US") {
        let target = target
        target.documentContextBeforeInput = before
        target.selectedText = selection
        middleware = TextReplacementMiddleware(
            table: { table },
            locale: { Locale(identifier: locale) },
            documentContextBefore: { target.documentContextBeforeInput },
            selectedText: { target.selectedText },
            deleteBackward: { target.deleteBackward() },
            insertText: { target.insertText($0) }
        )
        text = TextInputMiddleware(target: { target })
    }

    /// Runs `action` through the replacement middleware and then the text
    /// input, the way the pipeline does, and returns what was forwarded.
    @discardableResult
    func send(_ action: KeyAction) -> KeyAction {
        var forwarded = action
        middleware.process(ActionContext(action: action, binding: nil, mode: "main")) { next in
            forwarded = next.action
            text.process(next) { _ in }
        }
        return forwarded
    }

    var document: String { target.documentContextBeforeInput ?? "" }
}

@MainActor
struct TextReplacementMiddlewareTests {
    @Test func aSpaceAfterAShortcutExpandsIt() {
        let bench = Bench(before: "omw")
        bench.send(.space)
        #expect(bench.document == "On my way! ")
        #expect(bench.target.events == [
            .deleteBackward, .deleteBackward, .deleteBackward, .insertText("On my way!"), .insertText(" "),
        ])
    }

    @Test(arguments: [
        (KeyAction.newline, "\n"),
        (.commitText("."), "."), (.commitText(","), ","), (.commitText("!"), "!"), (.commitText("?"), "?"),
        (.commitText(";"), ";"), (.commitText(":"), ":"), (.commitText(")"), ")"),
        (.commitText(" "), " "), (.commitText("。"), "。"),
    ])
    func everyBoundaryEndsTheWord(action: KeyAction, boundary: String) {
        let bench = Bench(before: "good omw")
        bench.send(action)
        #expect(bench.document == "good On my way!" + boundary)
    }

    @Test(arguments: ["'", "’", "-", "@", "#", "_", "a", "1"])
    func innerWordCharactersDoNotEndTheWord(character: String) {
        let bench = Bench(before: "omw")
        bench.send(.commitText(character))
        #expect(bench.document == "omw" + character)
    }

    @Test func aWordThatIsNotAShortcutIsLeftAlone() {
        let bench = Bench(before: "hello")
        bench.send(.space)
        #expect(bench.document == "hello ")
        #expect(bench.target.events == [.insertText(" ")])
    }

    @Test func onlyTheWordBeforeTheCursorIsReplaced() {
        let bench = Bench(before: "tell mum omw")
        bench.send(.space)
        #expect(bench.document == "tell mum On my way! ")
    }

    @Test func theShortcutMustBeAWholeWord() {
        let bench = Bench(before: "xomw")
        bench.send(.space)
        #expect(bench.document == "xomw ")
    }

    @Test func aCapitalisedShortcutCapitalisesThePhrase() {
        let bench = Bench(before: "Gm")
        bench.send(.space)
        #expect(bench.document == "Good morning ")
    }

    @Test func aShortcutAfterOpeningPunctuationStillExpands() {
        let bench = Bench(before: "say (omw")
        bench.send(.commitText(")"))
        #expect(bench.document == "say (On my way!)")
    }

    @Test func aShortcutThatItselfStartsWithPunctuationMatchesWhole() {
        let table = TextReplacementTable(entries: [entry(":)", "smile"), entry("smile", "other")])
        let bench = Bench(table: table, before: "hi :)")
        bench.send(.space)
        #expect(bench.document == "hi smile ")
    }

    @Test func aRunLongerThanAnyShortcutIsIgnored() {
        let bench = Bench(before: String(repeating: "a", count: 80) + "omw")
        bench.send(.space)
        #expect(bench.document.hasSuffix("omw "))
    }

    @Test func aMultiLinePhraseIsInsertedWhole() {
        let bench = Bench(before: "addr")
        bench.send(.newline)
        #expect(bench.document == "1 Infinite Loop\nCupertino\n")
    }

    @Test func aSelectionIsNeverReplacedAroundTheShortcut() {
        let bench = Bench(before: "omw", selection: "selected")
        bench.send(.space)
        #expect(bench.document.hasPrefix("omw"))
        #expect(!bench.document.contains("On my way"))
    }

    @Test func anEmptyTableDoesNoWork() {
        var reads = 0
        let target = MockTextTarget()
        target.documentContextBeforeInput = "omw"
        let middleware = TextReplacementMiddleware(
            table: { .empty }, locale: { Locale(identifier: "en_US") },
            documentContextBefore: { reads += 1; return target.documentContextBeforeInput },
            selectedText: { nil }, deleteBackward: { target.deleteBackward() },
            insertText: { target.insertText($0) }
        )
        var forwarded: KeyAction?
        middleware.process(ActionContext(action: .space, binding: nil, mode: "main")) { forwarded = $0.action }
        #expect(forwarded == .space)
        #expect(reads == 0)
        #expect(target.events.isEmpty)
    }

    @Test func theBoundaryIsForwardedUnchanged() {
        let bench = Bench(before: "omw")
        #expect(bench.send(.space) == .space)
    }

    @Test func aPhraseThatContainsItsOwnShortcutDoesNotExpandAgain() {
        let table = TextReplacementTable(entries: [entry("hi", "hi there")])
        let bench = Bench(table: table, before: "hi")
        bench.send(.space)
        #expect(bench.document == "hi there ")
    }

    @Test func anEmojiShortcutIsDeletedAsOneCharacter() {
        let table = TextReplacementTable(entries: [entry("👍🏽", "agreed")])
        let bench = Bench(table: table, before: "ok 👍🏽")
        bench.send(.space)
        #expect(bench.document == "ok agreed ")
    }

    @Test func aTurkishLayoutCapitalisesWithItsOwnLocale() {
        let table = TextReplacementTable(entries: [entry("ik", "ışık")])
        let bench = Bench(table: table, before: "Ik", locale: "tr_TR")
        bench.send(.space)
        // Typed "Ik" capitalises the phrase's first letter in Turkish: ı -> I.
        #expect(bench.document == "Işık ")
    }
}

// MARK: - Undo

@MainActor
struct TextReplacementUndoTests {
    @Test func aDeleteRightAfterAnExpansionRestoresWhatWasTyped() {
        let bench = Bench(before: "omw")
        bench.send(.space)
        #expect(bench.document == "On my way! ")
        bench.send(.deleteBackward)
        #expect(bench.document == "omw ")
    }

    @Test func theRestoredShortcutKeepsItsTypedCapitalisation() {
        let bench = Bench(before: "Gm")
        bench.send(.space)
        bench.send(.deleteBackward)
        #expect(bench.document == "Gm ")
    }

    @Test func theUndoKeepsPunctuationBoundaries() {
        let bench = Bench(before: "hi omw")
        bench.send(.commitText("!"))
        #expect(bench.document == "hi On my way!!")
        bench.send(.deleteBackward)
        #expect(bench.document == "hi omw!")
    }

    @Test func theNextDeleteIsOrdinary() {
        let bench = Bench(before: "omw")
        bench.send(.space)
        bench.send(.deleteBackward)
        bench.send(.deleteBackward)
        #expect(bench.document == "omw")
    }

    @Test func anyActionInBetweenEndsTheUndoWindow() {
        let bench = Bench(before: "omw")
        bench.send(.space)
        bench.send(.commitText("x"))
        bench.send(.deleteBackward)
        #expect(bench.document == "On my way! ")
    }

    @Test func aDeleteForAnUnrelatedWordIsOrdinary() {
        let bench = Bench(before: "plain")
        bench.send(.space)
        bench.send(.deleteBackward)
        #expect(bench.document == "plain")
    }

    @Test func ifTheTextChangedUnderneathTheDeleteIsOrdinary() {
        let bench = Bench(before: "omw")
        bench.send(.space)
        // The host moved the caret or rewrote the text behind our back.
        bench.target.documentContextBeforeInput = "somewhere else"
        bench.send(.deleteBackward)
        #expect(bench.document == "somewhere els")
    }

    @Test func theRestoredTextIsForwardedAsATypedCommit() {
        let bench = Bench(before: "omw")
        bench.send(.space)
        #expect(bench.send(.deleteBackward) == .commitText("omw "))
    }

    @Test func anExpansionCanBeUndoneAndTypedAgain() {
        let bench = Bench(before: "omw")
        bench.send(.space)
        bench.send(.deleteBackward)
        bench.send(.deleteBackward) // remove the space
        bench.send(.space) // a fresh boundary after the shortcut
        #expect(bench.document == "On my way! ")
    }
}

// MARK: - Through the keyboard

@MainActor
@Suite(.serialized)
struct TextReplacementEndToEndTests {
    private static let table = TextReplacementTable.encode([
        entry("gm", "good morning"),
        entry("omw", "on my way."),
        entry("sig", "Best regards,\nRobert"),
    ])

    private func scenario(
        autoCapitalize: Bool = false, doubleSpace: Bool = false, language: String = "en_US"
    ) -> KeyboardScenario {
        KeyboardScenario(
            language: language, autoCapitalize: autoCapitalize,
            settings: [
                .textReplacements: Self.table,
                .doubleSpacePeriodEnabled: doubleSpace,
            ]
        )
    }

    @Test func aShortcutTypedByGestureExpandsOnSpace() {
        let scenario = scenario()
        #expect(scenario.type("gm").isEmpty)
        scenario.tap(UtilitySlot.space)
        #expect(scenario.text == "good morning ")
    }

    @Test func itWorksWithoutFullAccess() {
        let scenario = scenario()
        #expect(!scenario.target.hasFullAccess)
        scenario.type("gm")
        scenario.tap(UtilitySlot.return)
        #expect(scenario.text == "good morning\n")
    }

    @Test func autoCapitalisedShortcutsCarryTheCapitalToThePhrase() {
        let scenario = scenario(autoCapitalize: true)
        scenario.type("Gm")
        scenario.tap(UtilitySlot.space)
        #expect(scenario.text == "Good morning ")
    }

    @Test func aPunctuationSwipeEndsTheWord() {
        let scenario = scenario()
        scenario.type("gm")
        scenario.swipe(GridSlot.bottomCenter, .swipeDown) // "."
        #expect(scenario.text == "good morning.")
    }

    @Test func theDeleteKeyUndoesTheExpansion() {
        let scenario = scenario()
        scenario.type("gm")
        scenario.tap(UtilitySlot.space)
        scenario.tap(UtilitySlot.delete)
        #expect(scenario.text == "gm ")
    }

    @Test func itLeavesOrdinaryTypingAlone() {
        let scenario = scenario()
        scenario.type("hello world")
        scenario.tap(UtilitySlot.space)
        #expect(scenario.text == "hello world ")
    }

    @Test func doubleSpacePeriodStillWorksAfterAnExpansion() {
        let scenario = scenario(doubleSpace: true)
        scenario.type("gm")
        scenario.tap(UtilitySlot.space)
        scenario.tap(UtilitySlot.space)
        // The expansion ended in a word, the first space is the pending one,
        // so the second turns it into the sentence terminator.
        #expect(scenario.text == "good morning. ")
    }

    @Test func aTerminatedExpansionDoesNotGetADoubleSpacePeriod() {
        let scenario = scenario(doubleSpace: true)
        scenario.type("omw")
        scenario.tap(UtilitySlot.space)
        scenario.tap(UtilitySlot.space)
        // "on my way. " ends in punctuation, so the rule leaves the spaces.
        #expect(scenario.text == "on my way.  ")
    }

    @Test func autoCapitalisationSeesTheExpandedText() {
        let scenario = scenario(autoCapitalize: true)
        scenario.type("Omw")
        scenario.tap(UtilitySlot.space)
        #expect(scenario.text == "On my way. ")
        // The phrase ends a sentence, so the next letter comes up capitalised.
        #expect(scenario.mode == ModeNames.shifted)
    }

    @Test func aLineBreakInAPhraseDoesNotConfuseTheNextWord() {
        let scenario = scenario()
        scenario.type("sig")
        scenario.tap(UtilitySlot.space)
        scenario.type("gm")
        scenario.tap(UtilitySlot.space)
        #expect(scenario.text == "Best regards,\nRobert good morning ")
    }

    @Test func shortcutsAppearOnlyAfterTheSettingsReload() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        scenario.type("gm")
        scenario.tap(UtilitySlot.space)
        #expect(scenario.text == "gm ")

        scenario.defaults.set(Self.table, forKey: SettingsKey.textReplacements.rawValue)
        scenario.clear()
        scenario.type("gm")
        scenario.tap(UtilitySlot.space)
        // The store write alone is invisible to the keystroke path.
        #expect(scenario.text == "gm ")

        scenario.viewModel.reloadSettings()
        scenario.clear()
        scenario.type("gm")
        scenario.tap(UtilitySlot.space)
        #expect(scenario.text == "good morning ")
    }
}
