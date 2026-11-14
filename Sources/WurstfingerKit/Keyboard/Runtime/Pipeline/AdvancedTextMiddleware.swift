//
//  AdvancedTextMiddleware.swift
//  Wurstfinger
//
//  Handles text actions that require more than a simple proxy call:
//  delete-forward, capitalize-word, word-cursor movement, line movement,
//  and clipboard.
//

import Foundation

/// Handles advanced text-input actions that `TextInputMiddleware` leaves
/// as pass-through: delete-forward, capitalize-word, word-boundary cursor
/// movement, and clipboard (copy/paste/cut).
///
/// These actions need multi-step proxy interaction (e.g. read context,
/// delete, re-insert) and are therefore separated from the basic middleware
/// to keep each middleware focused and independently testable.
struct AdvancedTextMiddleware: ActionMiddleware {
    private let targetProvider: () -> TextInputTarget?
    private let localeProvider: () -> Locale
    private let onClipboardSuccess: () -> Void
    private let isCutAllEnabled: () -> Bool
    private let clipboard: any Clipboard

    init(
        target: @escaping () -> TextInputTarget?,
        locale: @escaping () -> Locale,
        onClipboardSuccess: @escaping () -> Void = {},
        isCutAllEnabled: @escaping () -> Bool = { true },
        clipboard: any Clipboard = ClipboardStore.shared
    ) {
        targetProvider = target
        localeProvider = locale
        self.onClipboardSuccess = onClipboardSuccess
        self.isCutAllEnabled = isCutAllEnabled
        self.clipboard = clipboard
    }

    func process(_ context: ActionContext, next: (ActionContext) -> Void) {
        if let target = targetProvider() {
            apply(action: context.action, to: target)
        }
        next(context)
    }

    private func apply(action: KeyAction, to target: TextInputTarget) {
        switch action {
        case .deleteForward:
            deleteForward(target: target)
        case let .capitalizeWord(uppercased):
            capitalizeWord(target: target, uppercased: uppercased)
        case .copy:
            handleCopy(target: target)
        case .paste:
            handlePaste(target: target)
        case .cut:
            handleCut(target: target)
        case .cutAll:
            handleCutAll(target: target)
        case .lineStart:
            moveCursor(to: .lineStart, target: target)
        case .lineEnd:
            moveCursor(to: .lineEnd, target: target)
        case .documentStart:
            moveCursor(to: .documentStart, target: target)
        case .documentEnd:
            moveCursor(to: .documentEnd, target: target)
        case .deleteWordBackward:
            deleteWordBackward(target: target)
        case .deleteWordForward:
            deleteWordForward(target: target)
        case .lineUp:
            moveToAdjacentLine(up: true, target: target)
        case .lineDown:
            moveToAdjacentLine(up: false, target: target)
        case let .cycleWordCase(ascending):
            cycleWordCase(target: target, ascending: ascending)
        default:
            break
        }
    }

    // MARK: - Cursor Jumps (Home / End)

    /// Where a cursor jump ends up.
    enum JumpTarget {
        case lineStart, lineEnd, documentStart, documentEnd

        /// Whether the jump runs forward (towards the end of the text).
        var isForward: Bool {
            switch self {
            case .lineEnd, .documentEnd: true
            case .lineStart, .documentStart: false
            }
        }

        /// Whether a newline stops the jump (line jumps) or not (document
        /// jumps, which only stop at the document's edge).
        var stopsAtNewline: Bool {
            switch self {
            case .lineStart, .lineEnd: true
            case .documentStart, .documentEnd: false
            }
        }
    }

    /// Upper bound on read-and-move rounds of one jump. Each round crosses one
    /// context window (the proxy exposes a few hundred characters at most), so
    /// the cap bounds the host round-trips a very long line can cost.
    static let maxJumpRounds = 64

    /// Moves the cursor to the start or end of the line or document.
    ///
    /// The proxy exposes only a bounded window of text around the cursor, so
    /// one read may not reach the line's end: when the window holds no
    /// newline, the cursor moves to the window's edge, the context is read
    /// again, and the walk continues. It stops at a newline, at the edge of
    /// the document (empty context), when the context stops changing (the host
    /// has not applied the move yet, or the text is repetitive enough that a
    /// move looks like none), or after `maxJumpRounds`. In the worst case the
    /// cursor lands at the edge of the window it could see, never past a
    /// newline.
    private func moveCursor(to jump: JumpTarget, target: TextInputTarget) {
        var previous: (before: String?, after: String?)?
        for _ in 0 ..< Self.maxJumpRounds {
            let before = target.documentContextBeforeInput
            let after = target.documentContextAfterInput
            if let previous, previous.before == before, previous.after == after { return }
            previous = (before, after)

            let offset = Self.jumpOffset(jump, before: before ?? "", after: after ?? "")
            guard offset.distance != 0 else { return }
            target.adjustTextPosition(byCharacterOffset: offset.distance)
            if offset.isFinal { return }
        }
    }

    /// The signed UTF-16 distance one jump round moves, and whether it reaches
    /// the destination (a newline, or the document's edge when the context is
    /// all there is) or only the edge of the visible window.
    static func jumpOffset(
        _ jump: JumpTarget, before: String, after: String
    ) -> (distance: Int, isFinal: Bool) {
        if jump.isForward {
            var distance = 0
            for character in after {
                if jump.stopsAtNewline, character.isNewline { return (distance, true) }
                distance += character.utf16.count
            }
            return (distance, false)
        }
        var distance = 0
        for character in before.reversed() {
            if jump.stopsAtNewline, character.isNewline { return (-distance, true) }
            distance += character.utf16.count
        }
        return (-distance, false)
    }

    // MARK: - Line Up / Line Down

    /// Moves the cursor one hard line up or down, keeping its column.
    ///
    /// A hard line is delimited by newline characters; a wrapped paragraph is
    /// one line, because the proxy knows nothing about how the host wraps it.
    /// The move is a single `adjustTextPosition` computed from one read of the
    /// context, so it does not depend on the host applying an intermediate
    /// move before the next read — the property the multi-round jumps above
    /// have to work around. When there is no line in that direction the
    /// cursor goes to the edge of the document instead, as arrow-up on the
    /// first line does in a text editor.
    private func moveToAdjacentLine(up: Bool, target: TextInputTarget) {
        let before = target.documentContextBeforeInput ?? ""
        let after = target.documentContextAfterInput ?? ""
        if let distance = Self.lineJumpOffset(up: up, before: before, after: after) {
            if distance != 0 { target.adjustTextPosition(byCharacterOffset: distance) }
        } else {
            moveCursor(to: up ? .documentStart : .documentEnd, target: target)
        }
    }

    /// The signed UTF-16 distance from the cursor to the same column on the
    /// adjacent line, or `nil` when the context shows no line break in that
    /// direction (the cursor is on the first or last line, or the line is
    /// longer than the window the proxy exposes).
    ///
    /// The column is the number of characters between the start of the cursor's
    /// line and the cursor; it is clamped to the length of the target line, so
    /// moving from the end of a long line onto a short one lands at the short
    /// line's end. Columns count grapheme clusters, distances sum UTF-16 units.
    static func lineJumpOffset(up: Bool, before: String, after: String) -> Int? {
        let behind = Array(before)
        let ahead = Array(after)
        let column = behind.lastIndex(where: \.isNewline).map { behind.count - $0 - 1 } ?? behind.count
        if up {
            // The newline that ends the previous line.
            guard let breakIndex = behind.lastIndex(where: \.isNewline) else { return nil }
            let lineStart = behind[..<breakIndex].lastIndex(where: \.isNewline).map { $0 + 1 } ?? 0
            let previousLength = breakIndex - lineStart
            let landing = lineStart + min(column, previousLength)
            return -behind[landing...].reduce(0) { $0 + $1.utf16.count }
        }
        guard let breakIndex = ahead.firstIndex(where: \.isNewline) else { return nil }
        let nextStart = breakIndex + 1
        let nextEnd = ahead[nextStart...].firstIndex(where: \.isNewline) ?? ahead.count
        let landing = nextStart + min(column, nextEnd - nextStart)
        return ahead[..<landing].reduce(0) { $0 + $1.utf16.count }
    }

    // MARK: - Delete Word

    /// Deletes the word before the cursor together with the whitespace after
    /// it, using the word boundary the space bar's discrete cursor movement
    /// uses (`KeyboardViewModel.backwardWordOffset`): skip the trailing
    /// whitespace, then the run of non-whitespace.
    private func deleteWordBackward(target: TextInputTarget) {
        // A selection is deleted as one unit, exactly like a plain delete.
        if let selected = target.selectedText, !selected.isEmpty {
            target.deleteBackward()
            return
        }
        guard let context = target.documentContextBeforeInput, !context.isEmpty else { return }
        for _ in 0 ..< Self.wordLength(endingAt: context) {
            target.deleteBackward()
        }
    }

    /// Number of grapheme clusters from the end of `context` back to the start
    /// of the previous word: trailing whitespace, then the word. `deleteBackward`
    /// removes clusters, so this counts clusters (the cursor jumps count
    /// UTF-16 units instead).
    static func wordLength(endingAt context: String) -> Int {
        var count = 0
        var seenWord = false
        for character in context.reversed() {
            if character.isWhitespace {
                if seenWord { break }
            } else {
                seenWord = true
            }
            count += 1
        }
        return count
    }

    /// Deletes the word after the cursor together with the whitespace before
    /// it: the mirror of `deleteWordBackward`, using the boundary the space
    /// bar's discrete forward movement uses (`KeyboardViewModel.forwardWordOffset`).
    ///
    /// Deletion only runs backwards, so the cursor first steps over the span
    /// and then deletes it, the way `deleteForward` does for one character.
    private func deleteWordForward(target: TextInputTarget) {
        if let selected = target.selectedText, !selected.isEmpty {
            target.deleteBackward()
            return
        }
        guard let context = target.documentContextAfterInput, !context.isEmpty else { return }
        let span = Self.wordSpan(startingAt: context)
        guard span.clusters > 0 else { return }
        target.adjustTextPosition(byCharacterOffset: span.utf16Length)
        for _ in 0 ..< span.clusters {
            target.deleteBackward()
        }
    }

    /// The span from the start of `context` over leading whitespace and then
    /// the word that follows, in grapheme clusters (what `deleteBackward`
    /// removes) and UTF-16 code units (what `adjustTextPosition` moves).
    static func wordSpan(startingAt context: String) -> (clusters: Int, utf16Length: Int) {
        var clusters = 0
        var utf16Length = 0
        var seenWord = false
        for character in context {
            if character.isWhitespace {
                if seenWord { break }
            } else {
                seenWord = true
            }
            clusters += 1
            utf16Length += character.utf16.count
        }
        return (clusters, utf16Length)
    }

    // MARK: - Delete Forward

    private func deleteForward(target: TextInputTarget) {
        // The proxy deletes a selected range as one unit, so forward-delete
        // over a selection *is* a plain deleteBackward. Stepping over the
        // trailing context first would move past the selection and delete an
        // unrelated character — or, with nothing behind it, do nothing at all.
        if let selected = target.selectedText, !selected.isEmpty {
            target.deleteBackward()
            return
        }
        guard let next = target.documentContextAfterInput?.first else { return }
        // `adjustTextPosition` moves by UTF-16 code units, so cross the whole
        // grapheme cluster (emoji can span 2+ units); a fixed +1 would land
        // mid-surrogate and delete the wrong character.
        target.adjustTextPosition(byCharacterOffset: next.utf16.count)
        target.deleteBackward()
    }

    // MARK: - Capitalize Word

    private func capitalizeWord(target: TextInputTarget, uppercased: Bool) {
        // With a selection the case change applies to the selection itself:
        // inserting over it replaces it in one step. The word lookback below
        // would instead consume the whole selection with its first
        // deleteBackward and then eat the word in front of it.
        if let selected = target.selectedText, !selected.isEmpty {
            target.insertText(cased(selected, uppercased: uppercased))
            return
        }
        guard let context = target.documentContextBeforeInput, !context.isEmpty else { return }

        var characters: [Character] = []
        for character in context.reversed() {
            if character.isLetter {
                characters.append(character)
            } else {
                break
            }
        }
        guard !characters.isEmpty else { return }

        let word = String(characters.reversed())
        let transformed = cased(word, uppercased: uppercased)

        for _ in 0 ..< word.count {
            target.deleteBackward()
        }
        target.insertText(transformed)
    }

    // MARK: - Cycle Word Case

    /// Steps the case of the word before the cursor (or of the selection)
    /// along lower → Title → UPPER, upwards or downwards. A step past either
    /// end leaves the text alone, which is what makes a repeated swipe safe.
    private func cycleWordCase(target: TextInputTarget, ascending: Bool) {
        if let selected = target.selectedText, !selected.isEmpty {
            let stepped = steppedCase(of: selected, ascending: ascending)
            if stepped != selected { target.insertText(stepped) }
            return
        }
        guard let context = target.documentContextBeforeInput, !context.isEmpty else { return }
        var characters: [Character] = []
        for character in context.reversed() {
            guard character.isLetter else { break }
            characters.append(character)
        }
        guard !characters.isEmpty else { return }
        let word = String(characters.reversed())
        let stepped = steppedCase(of: word, ascending: ascending)
        guard stepped != word else { return }
        for _ in 0 ..< word.count {
            target.deleteBackward()
        }
        target.insertText(stepped)
    }

    /// One step along lower → Title → UPPER. Mixed case counts as neither end:
    /// ascending takes it to UPPER and descending to Title, so a word that is
    /// neither can be normalised from either direction.
    private func steppedCase(of text: String, ascending: Bool) -> String {
        let locale = localeProvider()
        let lower = text.lowercased(with: locale)
        let upper = text.uppercased(with: locale)
        let title = Self.titled(lower, locale: locale)
        if ascending {
            switch text {
            case upper: return text
            case lower: return title
            default: return upper
            }
        }
        switch text {
        case lower: return text
        case title: return lower
        default: return title
        }
    }

    /// `lowercased` with its first letter in title case (the single glyph
    /// `ǆ` titles to `ǅ`, not `Ǆ`).
    private static func titled(_ lowercased: String, locale: Locale) -> String {
        guard let first = lowercased.first else { return lowercased }
        return String(first).capitalized(with: locale) + lowercased.dropFirst()
    }

    /// Case change in the active layout's locale (German `ß → SS`, Turkish
    /// dotless `i`, …).
    private func cased(_ text: String, uppercased: Bool) -> String {
        let locale = localeProvider()
        return uppercased ? text.uppercased(with: locale) : text.lowercased(with: locale)
    }

    // MARK: - Clipboard

    // The clipboard confirmation tick fires from the success paths below —
    // not from the haptic middleware — so a guarded no-op (no full access,
    // empty selection/pasteboard) stays silent, mirroring how mode and
    // language switches only tick on an actual change.

    private func handleCopy(target: TextInputTarget) {
        guard target.hasFullAccess else { return }
        if let selected = target.selectedText, !selected.isEmpty {
            clipboard.string = selected
            onClipboardSuccess()
            return
        }
        // Nothing selected: copy the text around the cursor, the way
        // Flickboard's copy selects everything first when there is no
        // selection. The proxy cannot select, so this reads the same context
        // `handleCutAll` does — the current paragraph in a long document, the
        // whole text in a single-line field — under the same size ceiling. Copy
        // changes nothing in the document, so unlike cut-all it needs no setting.
        let all = (target.documentContextBeforeInput ?? "") + (target.documentContextAfterInput ?? "")
        guard !all.isEmpty, !Self.exceedsCutLimit(all) else { return }
        clipboard.string = all
        onClipboardSuccess()
    }

    private func handlePaste(target: TextInputTarget) {
        guard target.hasFullAccess else { return }
        // The pasteboard is the gesture path's only external I/O — the writes in
        // handleCopy/handleCut/handleCutAll cross to pasteboardd on this same
        // thread — but this read is the one that can end up waiting on something
        // other than the daemon, and that is an accepted tradeoff: a Universal
        // Clipboard item makes the getter wait for the transfer from the other
        // device, and under the "Ask" paste permission it waits for the system
        // alert — the keyboard's main thread sits inside this line for as long
        // as that takes. What makes it acceptable rather than a hang: both are
        // user-initiated (this is a paste swipe), the system narrates them with
        // its own HUD or alert, the host app stays responsive throughout, and
        // UIKit's own paste blocks exactly the same way. `hasStrings` is no
        // escape — the fetch is what blocks, not the emptiness check.
        //
        // If it ever has to become non-blocking: read asynchronously through
        // `itemProviders`/`loadObject`, hop back to the main thread to insert,
        // and drop the result if the gesture that asked for it is no longer the
        // current one — by then the cursor may have moved or the keyboard may
        // have been torn down.
        if let text = clipboard.string, !text.isEmpty {
            // Cap pasted text so a multi-MB pasteboard cannot blow the
            // keyboard extension's jetsam memory budget. Truncates silently.
            target.insertText(Self.cappedForInsertion(text))
            onClipboardSuccess()
        }
    }

    private func handleCut(target: TextInputTarget) {
        guard target.hasFullAccess else { return }
        if let selected = target.selectedText, !selected.isEmpty {
            clipboard.string = selected
            target.deleteBackward()
            onClipboardSuccess()
        }
    }

    /// Cuts everything the proxy exposes around the cursor: the surrounding
    /// context goes to the pasteboard and is then deleted.
    ///
    /// This is as close to "select all and cut" as an extension can get. The
    /// proxy has no API to set a selection, so `handleCut` above can only act
    /// on a selection the user made by hand; here the text is read from the
    /// two context properties instead. Those reach no further than the current
    /// paragraph, so in a multi-paragraph field this cuts that paragraph
    /// rather than the whole document — single-line fields, where the feature
    /// earns its keep, are unaffected.
    ///
    /// Deletion is destructive and unaided by undo, hence cut rather than
    /// delete: the pasteboard copy makes an accidental circle recoverable
    /// with the paste swipe on the same key.
    private func handleCutAll(target: TextInputTarget) {
        guard isCutAllEnabled(), target.hasFullAccess else { return }
        // With an active selection the context properties describe the text
        // *around* it, so the selection must be stitched back in for the
        // pasteboard — and consumed by its own deleteBackward below, because
        // the proxy deletes a selected range as one unit and the counting
        // loop would otherwise run past the document.
        let before = target.documentContextBeforeInput ?? ""
        let selected = target.selectedText ?? ""
        let after = target.documentContextAfterInput ?? ""
        let all = before + selected + after
        guard !all.isEmpty else { return }
        // Bounded like a paste: every character below costs one deleteBackward
        // round-trip to the host app, and the proxy imposes no size limit of
        // its own. Past the cap the cut is refused rather than half-applied —
        // a silent no-op like the guards above.
        guard !Self.exceedsCutLimit(all) else { return }

        clipboard.string = all

        if !selected.isEmpty {
            target.deleteBackward()
        }
        // Deletion only runs backwards, so park the cursor past the trailing
        // context first. The offset is in UTF-16 code units (see the protocol).
        if !after.isEmpty {
            target.adjustTextPosition(byCharacterOffset: after.utf16.count)
        }
        // Counted over the joined string, not the two halves: a combining mark
        // leading `after` fuses with the last character of `before` into one
        // grapheme cluster, and deleteBackward removes clusters, so summing the
        // halves separately would delete one character too many.
        for _ in 0 ..< (before + after).count {
            target.deleteBackward()
        }
        onClipboardSuccess()
    }

    /// Returns `text` capped at `KeyboardConstants.TextInput.maxPasteUTF16Length`
    /// UTF-16 code units, cut at a grapheme-cluster boundary so no emoji or
    /// combining sequence is ever split. The cheap `utf16.count` check makes
    /// the common (small) case allocation-free; the truncating path walks at
    /// most the capped prefix, so the memory bound holds for the copy too.
    static func cappedForInsertion(
        _ text: String,
        maxUTF16Length: Int = KeyboardConstants.TextInput.maxPasteUTF16Length
    ) -> String {
        guard text.utf16.count > maxUTF16Length else { return text }
        var usedUTF16 = 0
        var end = text.startIndex
        while end < text.endIndex {
            let next = text.index(after: end)
            usedUTF16 += text[end].utf16.count
            if usedUTF16 > maxUTF16Length { break }
            end = next
        }
        return String(text[..<end])
    }

    /// Whether `text` is too large to cut in one gesture. Shares
    /// `KeyboardConstants.TextInput.maxPasteUTF16Length` with
    /// `cappedForInsertion`, so a single action moves at most that much text in
    /// either direction: an oversized insertion truncates, an oversized
    /// deletion is refused — truncating it would mangle the document while
    /// putting only part of it on the pasteboard.
    static func exceedsCutLimit(
        _ text: String,
        maxUTF16Length: Int = KeyboardConstants.TextInput.maxPasteUTF16Length
    ) -> Bool {
        text.utf16.count > maxUTF16Length
    }
}
