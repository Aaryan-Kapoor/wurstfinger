//
//  TextReplacementMiddleware.swift
//  Wurstfinger
//
//  Expands the user's text-replacement shortcuts when a word ends
//  ("omw " -> "On my way! ") and undoes the expansion on the delete that
//  follows it, like the iOS system keyboard (issue #259).
//

import Foundation

/// Expands a shortcut when the word before the cursor ends.
///
/// **Trigger.** A *boundary* is committed: a space, a newline, or one of the
/// punctuation marks in `boundaryPunctuation`. At that point the run of
/// non-whitespace characters before the cursor is looked up in the table; on
/// a match it is deleted and the phrase typed in its place, and the boundary
/// itself then goes through the rest of the pipeline untouched, so it still
/// lands after the phrase and everything downstream (auto-capitalization, the
/// double-space period) sees the same action it would have seen anyway.
/// Apostrophes and hyphens are deliberately not boundaries: `don't` and
/// `e-mail` must not fire a shortcut called `don` or `e`.
///
/// **Leading punctuation.** A shortcut typed right after an opening quote or
/// bracket (`"omw`, `(omw`) still expands: when the whole run is not a
/// shortcut, the run without its leading punctuation is tried, and only that
/// part is replaced.
///
/// **Case.** See `TextReplacementTable.lookup(_:locale:)`: exact first, then
/// case-insensitive with the typed capitalisation carried to the phrase.
///
/// **Undo.** If the very next action is a delete, and the text before the
/// cursor is still the expansion followed by its boundary, the expansion is
/// reverted to what was typed — shortcut plus boundary — instead of deleting
/// one character of the phrase. Any other action in between ends the window.
///
/// **Position in the pipeline.** After compose and sequential composition
/// (so a boundary character composed from a dead key is already final), and
/// before the text-input middleware that types the boundary. It needs no
/// Full Access: it only reads the document context and edits through the
/// text proxy.
///
/// **Cost.** Inert (one closure call and an `isEmpty` check) while the table
/// is empty. Otherwise only boundary actions do any work: one read of the
/// context and at most two dictionary lookups. Nothing here reads
/// `UserDefaults`; the table arrives through the settings snapshot.
///
/// A class, like `DoubleSpacePeriodMiddleware`: the undo window is state.
final class TextReplacementMiddleware: ActionMiddleware {
    /// Punctuation that ends a word. A fixed, documented set rather than
    /// "every punctuation character": apostrophes, hyphens, `@`, `#` and `_`
    /// occur inside words and shortcuts.
    static let boundaryPunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", "\"", "\u{201D}", "\u{00BB}", "\u{2026}",
        "。", "、", "！", "？", "，", "；", "：", "）", "」", "』", "।", "،", "؛", "؟",
    ]

    /// How many characters of leading punctuation are skipped when the whole
    /// run is not a shortcut (`("omw` is two).
    private static let maxLeadingPunctuation = 4

    private let table: () -> TextReplacementTable
    private let locale: () -> Locale
    private let documentContextBefore: () -> String?
    private let selectedText: () -> String?
    private let deleteBackward: () -> Void
    private let insertText: (String) -> Void

    /// The expansion the next delete may undo, or nil.
    private var lastExpansion: Expansion?

    private struct Expansion {
        /// What the user typed (`Gm`).
        let typed: String
        /// What replaced it (`Good morning`).
        let phrase: String
        /// The character that ended the word and was typed after the phrase.
        let boundary: String
    }

    init(
        table: @escaping () -> TextReplacementTable,
        locale: @escaping () -> Locale,
        documentContextBefore: @escaping () -> String?,
        selectedText: @escaping () -> String?,
        deleteBackward: @escaping () -> Void,
        insertText: @escaping (String) -> Void
    ) {
        self.table = table
        self.locale = locale
        self.documentContextBefore = documentContextBefore
        self.selectedText = selectedText
        self.deleteBackward = deleteBackward
        self.insertText = insertText
    }

    func process(_ context: ActionContext, next: (ActionContext) -> Void) {
        // The undo window is one action wide.
        let pending = lastExpansion
        lastExpansion = nil

        let table = table()
        guard !table.isEmpty else {
            next(context)
            return
        }

        if case .deleteBackward = context.action, let pending, let undone = undo(pending) {
            // Forward the restored text as a commit so the middlewares after
            // this one (the text input, auto-capitalization) treat it like
            // any typed text.
            var rewritten = context
            rewritten.action = .commitText(undone)
            next(rewritten)
            return
        }

        if let boundary = Self.boundary(of: context.action),
           selectedText()?.isEmpty != false,
           let expansion = expand(before: boundary, in: table) {
            lastExpansion = expansion
        }
        next(context)
    }

    // MARK: - Expand

    /// Replaces the shortcut before the cursor with its phrase, if there is one.
    private func expand(before boundary: String, in table: TextReplacementTable) -> Expansion? {
        guard let text = documentContextBefore(), !text.isEmpty else { return nil }
        let locale = locale()
        for candidate in Self.candidates(endingAt: text) {
            guard let phrase = table.lookup(candidate, locale: locale) else { continue }
            for _ in 0 ..< candidate.count {
                deleteBackward()
            }
            insertText(phrase)
            return Expansion(typed: candidate, phrase: phrase, boundary: boundary)
        }
        return nil
    }

    /// The word the action ends, as the strings to look up in order of
    /// preference: the whole run of non-whitespace characters before the
    /// cursor, then (when it starts with punctuation) the run without it.
    /// Empty when there is no word or it is longer than any shortcut could be.
    static func candidates(endingAt context: String) -> [String] {
        var run: [Character] = []
        for character in context.reversed() {
            if character.isWhitespace { break }
            run.append(character)
            if run.count > TextReplacementTable.maxShortcutLength + maxLeadingPunctuation { return [] }
        }
        guard !run.isEmpty else { return [] }
        let word = Array(run.reversed())

        var result: [String] = []
        if word.count <= TextReplacementTable.maxShortcutLength { result.append(String(word)) }
        let leading = word.prefix { $0.isPunctuation || $0.isSymbol }.count
        if leading > 0, leading < word.count, leading <= maxLeadingPunctuation {
            let stripped = word.dropFirst(leading)
            if stripped.count <= TextReplacementTable.maxShortcutLength { result.append(String(stripped)) }
        }
        return result
    }

    /// The character an action types when it ends a word, or nil.
    static func boundary(of action: KeyAction) -> String? {
        switch action {
        case .space: " "
        case .newline: "\n"
        case let .commitText(text):
            if text.count == 1, let character = text.first,
               character.isWhitespace || boundaryPunctuation.contains(character) {
                text
            } else {
                nil
            }
        default: nil
        }
    }

    // MARK: - Undo

    /// Deletes the expansion and its boundary and returns what to type
    /// instead (the shortcut as typed, then the boundary), or nil when the
    /// text before the cursor is no longer the expansion.
    private func undo(_ expansion: Expansion) -> String? {
        let tail = expansion.phrase + expansion.boundary
        guard selectedText()?.isEmpty != false,
              let text = documentContextBefore(), text.hasSuffix(tail)
        else { return nil }
        for _ in 0 ..< tail.count {
            deleteBackward()
        }
        return expansion.typed + expansion.boundary
    }
}
