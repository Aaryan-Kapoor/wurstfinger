//
//  EmojiRecentsMiddleware.swift
//  Wurstfinger
//
//  Remembers the emoji typed in the emoji mode, for its recent key.
//

import Foundation

/// Reports every emoji the emoji mode types, so the recent key can offer it.
///
/// Mode-gated and text-gated: in any other mode this is one string comparison
/// and returns, so the keystroke path of the letters is untouched, and in the
/// emoji mode it is the check of one binding and one `record` call that
/// allocates nothing (`EmojiRecents`). Nothing is read from or written to the
/// store here; that happens when settings reload and when the mode is left.
struct EmojiRecentsMiddleware: ActionMiddleware {
    /// Whether to remember at all: not in a sensitive field, where what the
    /// user types must not be kept anywhere, however harmless it looks.
    let isRecording: () -> Bool
    let record: (String) -> Void

    func process(_ context: ActionContext, next: (ActionContext) -> Void) {
        next(context)
        guard EmojiLayouts.isEmojiMode(context.mode),
              case let .commitText(text) = context.action,
              EmojiText.isSingleEmoji(text),
              isRecording()
        else { return }
        record(text)
    }
}
