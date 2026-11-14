//
//  CursorJumpTests.swift
//  WurstfingerTests
//
//  The text actions behind Home/End (#77) and the long swipes (#79): line and
//  document jumps through a bounded context window, delete-word, and the
//  terminal keys (Tab, Shift-Tab, Escape).
//

import Foundation
import Testing
@testable import WurstfingerKit

/// A document that, like `UITextDocumentProxy`, shows only a window of the
/// text around the cursor. `applyMovesImmediately == false` models the host
/// applying `adjustTextPosition` later than the read that follows it, which
/// is what the keyboard sees on a device.
@MainActor
private final class WindowedTarget: TextInputTarget {
    private(set) var text: [Character]
    private(set) var cursor: Int
    let window: Int
    let applyMovesImmediately: Bool
    private(set) var adjustCalls = 0

    init(_ text: String, cursor: Int? = nil, window: Int = 8, applyMovesImmediately: Bool = true) {
        self.text = Array(text)
        self.cursor = cursor ?? text.count
        self.window = window
        self.applyMovesImmediately = applyMovesImmediately
    }

    var documentContextBeforeInput: String? { String(text[max(0, cursor - window) ..< cursor]) }
    var documentContextAfterInput: String? { String(text[cursor ..< min(text.count, cursor + window)]) }
    var selectedText: String? { nil }
    var hasFullAccess: Bool { false }

    func insertText(_ string: String) {
        text.insert(contentsOf: Array(string), at: cursor)
        cursor += string.count
    }

    func deleteBackward() {
        guard cursor > 0 else { return }
        text.remove(at: cursor - 1)
        cursor -= 1
    }

    func adjustTextPosition(byCharacterOffset offset: Int) {
        adjustCalls += 1
        // Test text is BMP-only, so UTF-16 units and characters coincide.
        if applyMovesImmediately { cursor = min(max(cursor + offset, 0), text.count) }
    }
}

@MainActor
private func jump(_ action: KeyAction, on target: TextInputTarget) {
    let middleware = AdvancedTextMiddleware(target: { target }, locale: { Locale(identifier: "en_US") })
    middleware.process(ActionContext(action: action, binding: nil, mode: "main")) { _ in }
}

// MARK: - Line and document jumps

@MainActor
struct CursorJumpTests {
    @Test func lineStartStopsAtTheNewlineBeforeTheCursor() {
        let target = WindowedTarget("one\ntwo three", window: 64)
        jump(.lineStart, on: target)
        #expect(target.cursor == 4)
    }

    @Test func lineEndStopsAtTheNewlineAfterTheCursor() {
        let target = WindowedTarget("one two\nthree", cursor: 2, window: 64)
        jump(.lineEnd, on: target)
        #expect(target.cursor == 7)
    }

    @Test func lineStartOfTheFirstLineIsTheStartOfTheDocument() {
        let target = WindowedTarget("hello world", cursor: 6, window: 64)
        jump(.lineStart, on: target)
        #expect(target.cursor == 0)
    }

    @Test func lineEndOfTheLastLineIsTheEndOfTheDocument() {
        let target = WindowedTarget("hello world", cursor: 3, window: 64)
        jump(.lineEnd, on: target)
        #expect(target.cursor == 11)
    }

    @Test func alreadyAtTheLineEdgeDoesNothing() {
        let atStart = WindowedTarget("ab\ncd", cursor: 3, window: 64)
        jump(.lineStart, on: atStart)
        #expect(atStart.cursor == 3)
        #expect(atStart.adjustCalls == 0)

        let atEnd = WindowedTarget("ab\ncd", cursor: 2, window: 64)
        jump(.lineEnd, on: atEnd)
        #expect(atEnd.cursor == 2)
        #expect(atEnd.adjustCalls == 0)
    }

    @Test func aLineLongerThanTheWindowIsWalkedInRounds() {
        // 60 characters on the line, a window of 8: one read cannot see the
        // newline, so the jump moves to the window's edge and reads again.
        let line = String(repeating: "abcdefghij", count: 6)
        let target = WindowedTarget("first\n" + line, window: 8)
        jump(.lineStart, on: target)
        #expect(target.cursor == 6)
        #expect(target.adjustCalls > 1)

        let end = WindowedTarget(line + "\nlast", cursor: 0, window: 8)
        jump(.lineEnd, on: end)
        #expect(end.cursor == 60)
    }

    @Test func documentJumpsIgnoreNewlines() {
        let text = "alpha\nbeta\ngamma"
        let toStart = WindowedTarget(text, cursor: 9, window: 4)
        jump(.documentStart, on: toStart)
        #expect(toStart.cursor == 0)

        let toEnd = WindowedTarget(text, cursor: 2, window: 4)
        jump(.documentEnd, on: toEnd)
        #expect(toEnd.cursor == text.count)
    }

    @Test func aHostThatAppliesMovesLateStopsAfterOneWindow() {
        // The read after the move still shows the old caret: the context did
        // not change, so the jump must stop instead of looping to the cap.
        let target = WindowedTarget(
            String(repeating: "x", count: 100), window: 8, applyMovesImmediately: false
        )
        jump(.documentStart, on: target)
        #expect(target.adjustCalls == 1)
    }

    @Test func theRoundCapBoundsAVeryLongDocument() {
        let target = WindowedTarget(String(repeating: "xy", count: 2000), window: 4)
        jump(.documentStart, on: target)
        #expect(target.adjustCalls <= AdvancedTextMiddleware.maxJumpRounds)
        // 64 rounds of at most 4 characters each leave the cursor past the start.
        #expect(target.cursor > 0)
    }

    @Test func movesByUTF16UnitsSoEmojiAreNotSplit() {
        let target = MockTextTarget()
        target.documentContextBeforeInput = "a\nb👍c"
        target.documentContextAfterInput = ""
        jump(.lineStart, on: target)
        // "b👍c" is 1 + 2 + 1 UTF-16 units.
        #expect(target.events == [.adjustCursor(-4)])
        #expect(target.documentContextBeforeInput == "a\n")
    }

    @Test func jumpOffsetReportsWhetherItReachedTheDestination() {
        let reached = AdvancedTextMiddleware.jumpOffset(.lineStart, before: "x\nyz", after: "")
        #expect(reached.distance == -2)
        #expect(reached.isFinal)
        let onlyTheWindow = AdvancedTextMiddleware.jumpOffset(.lineStart, before: "xyz", after: "")
        #expect(onlyTheWindow.distance == -3)
        #expect(!onlyTheWindow.isFinal)
    }

    @Test func aWindowsLineBreakIsOneNewline() {
        // Swift reads "\r\n" as a single Character, which is a newline.
        let offset = AdvancedTextMiddleware.jumpOffset(.lineStart, before: "a\r\nbc", after: "")
        #expect(offset.distance == -2)
        #expect(offset.isFinal)
    }
}

// MARK: - Delete word

@MainActor
struct DeleteWordBackwardTests {
    private func run(_ context: String, selection: String? = nil) -> MockTextTarget {
        let target = MockTextTarget()
        target.documentContextBeforeInput = context
        target.selectedText = selection
        jump(.deleteWordBackward, on: target)
        return target
    }

    @Test func deletesTheWordBeforeTheCursor() {
        #expect(run("hello world").documentContextBeforeInput == "hello ")
    }

    @Test func deletesTheTrailingSpacesWithTheWord() {
        #expect(run("hello world   ").documentContextBeforeInput == "hello ")
    }

    @Test func deletesALoneWord() {
        #expect(run("hello").documentContextBeforeInput == "")
    }

    @Test func stopsAtANewline() {
        #expect(run("one\ntwo").documentContextBeforeInput == "one\n")
    }

    @Test func countsGraphemeClustersNotCodeUnits() {
        let target = run("say 👍🏽👍🏽")
        #expect(target.documentContextBeforeInput == "say ")
        #expect(target.events.count == 2) // one deleteBackward per emoji cluster
    }

    @Test func withASelectionItDeletesTheSelectionOnly() {
        let target = run("hello world", selection: "world")
        #expect(target.events == [.deleteBackward])
    }

    @Test func doesNothingWithoutContext() {
        let target = MockTextTarget()
        jump(.deleteWordBackward, on: target)
        #expect(target.events.isEmpty)
    }

    @Test func usesTheSameBoundaryAsWordCursorMovement() {
        for context in ["hello world", "  spaced  ", "a b  ", "x", "tab\tword "] {
            let target = run(context)
            let deleted = context.count - (target.documentContextBeforeInput?.count ?? 0)
            #expect(deleted == AdvancedTextMiddleware.wordLength(endingAt: context))
            #expect(KeyboardViewModel.backwardWordOffset(in: context) == context.suffix(deleted).utf16.count)
        }
    }
}

// MARK: - Terminal keys

@MainActor
struct TerminalKeyActionTests {
    private func inserted(for action: KeyAction) -> [MockTextTarget.Event] {
        let target = MockTextTarget()
        let middleware = TextInputMiddleware(target: { target })
        middleware.process(ActionContext(action: action, binding: nil, mode: "main")) { _ in }
        return target.events
    }

    @Test func tabInsertsATab() {
        #expect(inserted(for: .tab) == [.insertText("\t")])
    }

    @Test func escapeInsertsTheEscapeCharacter() {
        #expect(inserted(for: .escape) == [.insertText("\u{1B}")])
    }

    @Test func backTabInsertsTheTerminalShiftTabSequence() {
        #expect(inserted(for: .backTab) == [.insertText("\u{1B}[Z")])
    }

    @Test func cursorJumpsAndWordDeleteAreNotTextInputsConcern() {
        for action in [KeyAction.lineStart, .lineEnd, .documentStart, .documentEnd, .deleteWordBackward] {
            #expect(inserted(for: action).isEmpty)
        }
    }

    @Test func onlyTextActionsAffectAutoCapitalization() {
        #expect(AutoCapitalizationMiddleware.affectsCapitalization(.tab))
        #expect(AutoCapitalizationMiddleware.affectsCapitalization(.deleteWordBackward))
        for action in [KeyAction.escape, .backTab, .lineStart, .lineEnd, .documentStart, .documentEnd] {
            #expect(!AutoCapitalizationMiddleware.affectsCapitalization(action))
        }
    }

    @Test func theNewActionsRoundTripThroughCodable() throws {
        let actions: [KeyAction] = [
            .tab, .backTab, .escape, .lineStart, .lineEnd, .documentStart, .documentEnd, .deleteWordBackward,
        ]
        for action in actions {
            let data = try JSONEncoder().encode(action)
            #expect(try JSONDecoder().decode(KeyAction.self, from: data) == action)
        }
    }
}

// MARK: - Home / End bindings

struct ReturnKeyHomeEndBindingTests {
    @Test func returnKeySwipesUpLeftToLineStartAndDownRightToLineEnd() throws {
        let key = CommonKeys.return
        #expect(key.bindings[.swipeUpLeft]?.action == .lineStart)
        #expect(key.bindings[.swipeDownRight]?.action == .lineEnd)
        // The return swipe goes the whole way.
        #expect(key.bindings[.swipeUpLeft]?.returnAction == .documentStart)
        #expect(key.bindings[.swipeDownRight]?.returnAction == .documentEnd)
        #expect(key.bindings[.tap]?.action == .newline)
    }

    @Test func theBindingsCollideWithNothingElseOnTheKey() {
        let swipes = Set(CommonKeys.return.bindings.keys.filter(\.isSwipe))
        #expect(swipes == [.swipeUpLeft, .swipeDownRight])
        #expect(CommonKeys.return.swipeMode.allows(.swipeUpLeft))
        #expect(CommonKeys.return.swipeMode.allows(.swipeDownRight))
    }

    @Test func theJumpsAreNamedForVoiceOver() {
        let names = CommonKeys.return.accessibilityActions.map(\.name)
        #expect(names == ["Line start", "Line end"])
    }
}
