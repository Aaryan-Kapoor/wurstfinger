//
//  KeyAction.swift
//  Wurstfinger
//
//  All possible actions a key binding can trigger.
//

import Foundation

/// All possible actions a key binding can trigger.
enum KeyAction: Codable, Equatable, Sendable {
    /// Insert text
    case commitText(String)

    /// Compose trigger (accent composition with previous character)
    case compose(trigger: String)

    /// Cycle through accents (ä → â → à → ...)
    case cycleAccents

    /// Switch to another mode by name.
    /// e.g. "shifted", "numeric", "emoji", "symbols", "main"
    case switchMode(String)

    /// Capitalize/uncapitalize last word
    case capitalizeWord(uppercased: Bool)

    /// Next input method (Globe key)
    case advanceToNextInputMode

    /// Dismiss keyboard
    case dismissKeyboard

    /// Switch to the next enabled language
    case switchToNextLanguage

    /// Delete backward
    case deleteBackward

    /// Delete forward
    case deleteForward

    /// Space
    case space

    /// Newline
    case newline

    /// Move cursor
    case moveCursor(offset: Int)

    /// Clipboard
    case copy, paste, cut

    /// Cut everything the document proxy exposes, without a prior selection.
    /// The proxy offers no way to select text, so this reads the context
    /// around the cursor instead — see `AdvancedTextMiddleware.handleCutAll`.
    case cutAll

    /// Insert a horizontal tab (`U+0009`). Terminal apps and code editors read
    /// it as Tab; fields that cannot take a tab simply ignore it.
    case tab

    /// Shift-Tab ("back tab"). A text proxy has no key events, so it is sent
    /// as the escape sequence a terminal emulator receives for Shift-Tab,
    /// `ESC [ Z` (the xterm `CBT` code, `\u{1B}[Z`). Apps that interpret
    /// terminal input (SSH clients, Termius, Blink) act on it; a plain text
    /// field shows the control characters, which is why it is a deliberate,
    /// opt-in binding (see `LongSwipeConfiguration`).
    case backTab

    /// Escape (`U+001B`), the byte a terminal receives for the Esc key.
    case escape

    /// Move the cursor to the start of the current line.
    /// See `AdvancedTextMiddleware.moveToLineStart`.
    case lineStart

    /// Move the cursor to the end of the current line.
    case lineEnd

    /// Move the cursor to the start of the document.
    case documentStart

    /// Move the cursor to the end of the document.
    case documentEnd

    /// Delete the previous word together with the spaces after it.
    case deleteWordBackward

    /// No action (empty slot)
    case none
}
