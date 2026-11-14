//
//  CompletionMiddleware.swift
//  Wurstfinger
//
//  Word completions in the action pipeline: the accept action, the space an
//  accepted word brings with it, and the cue to look the next word up.
//

import Foundation

/// Connects `WordCompletions` to the action pipeline.
///
/// - `.acceptCompletion` (the space bar's down-swipe) is consumed here: it
///   takes the first completion and goes no further down the chain.
/// - While the space typed by accepting a word is still the character before
///   the cursor, a space press is swallowed (the word has its space; a second
///   would double it) and a punctuation mark takes the auto-space back first
///   ("hello" accepted, "." typed: "hello.", not "hello .").
/// - Every other action ends the auto-space, and every action cues a lookup
///   for the word the cursor now follows. The cue is one flag read when the
///   row is off; see `WordCompletions` for what it costs when on.
///
/// Runs ahead of composition and text replacement so it sees the raw `.space`
/// and the raw punctuation, before either can rewrite them.
struct CompletionMiddleware: ActionMiddleware {
    let completions: WordCompletions
    /// Accepting is the view model's, which also re-evaluates auto-capitalization.
    let acceptTop: () -> Void

    func process(_ context: ActionContext, next: (ActionContext) -> Void) {
        guard completions.isActive else {
            next(context)
            return
        }
        switch context.action {
        case .acceptCompletion:
            acceptTop()
            return
        case .space where completions.isAutoSpacePending:
            if completions.swallowSpaceAfterAccept() {
                completions.noteKeystroke()
                return
            }
        case let .commitText(text) where completions.isAutoSpacePending && Self.attachesToWord(text):
            completions.takeBackAutoSpace()
        default:
            if completions.isAutoSpacePending { completions.endAutoSpace() }
        }
        next(context)
        completions.noteKeystroke()
    }

    /// Marks that close a word without a space before them.
    static let attachingMarks: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "…", ")", "]", "}", "%",
        "。", "、", "！", "？", "،", "؛", "؟", "।", "۔",
    ]

    /// Whether `text` is one of the marks that hug the word before it.
    static func attachesToWord(_ text: String) -> Bool {
        text.count == 1 && text.first.map(attachingMarks.contains) == true
    }
}
