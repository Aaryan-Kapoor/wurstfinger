//
//  ScenarioTextTarget.swift
//  WurstfingerScenarioKit
//
//  The document a scenario types into: text split around a cursor, edited the
//  way UIKit's text document proxy edits it.
//

import Foundation
@testable import WurstfingerKit

/// An in-memory `TextInputTarget`. The cursor moves in UTF-16 units, exactly
/// like `UITextDocumentProxy.adjustTextPosition(byCharacterOffset:)`, so a
/// layout that mixes up units shows in the output instead of passing.
final class ScenarioTextTarget: TextInputTarget {
    private(set) var before = ""
    private(set) var after = ""

    /// Every call the pipeline made, in order, for tests that assert on the
    /// calls rather than the resulting text.
    enum Event: Equatable {
        case insertText(String)
        case deleteBackward
        case adjustCursor(Int)
    }

    private(set) var events: [Event] = []

    /// The whole document, cursor ignored.
    var text: String { before + after }

    /// The caret position as a count of characters before it.
    var cursor: Int { before.count }

    var documentContextBeforeInput: String? { before }
    var documentContextAfterInput: String? { after }
    var selectedText: String? { nil }
    var hasFullAccess: Bool { false }

    func insertText(_ text: String) {
        events.append(.insertText(text))
        before += text
    }

    func deleteBackward() {
        events.append(.deleteBackward)
        if !before.isEmpty { before.removeLast() }
    }

    func adjustTextPosition(byCharacterOffset offset: Int) {
        events.append(.adjustCursor(offset))
        var head = Array(before.utf16)
        var tail = Array(after.utf16)
        if offset > 0 {
            let moved = min(offset, tail.count)
            head.append(contentsOf: tail.prefix(moved))
            tail.removeFirst(moved)
        } else if offset < 0 {
            let moved = min(-offset, head.count)
            tail.insert(contentsOf: head.suffix(moved), at: 0)
            head.removeLast(moved)
        }
        before = String(decoding: head, as: UTF16.self)
        after = String(decoding: tail, as: UTF16.self)
    }

    /// Replaces the document, leaving the caret at the end of `text`.
    func reset(to text: String = "") {
        before = text
        after = ""
        events = []
    }
}
