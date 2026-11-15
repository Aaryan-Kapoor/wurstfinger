//
//  EmojiText.swift
//  Wurstfinger
//
//  What counts as an emoji for the keyboard's own purposes: drawing, naming
//  and the recent list.
//

import Foundation

/// Classification of key text as emoji.
///
/// Not a general emoji detector. It answers the questions the keyboard asks of
/// its own bindings: *is this label a pictograph* (so it is drawn at its own
/// size, never hidden with the symbol labels, and read by VoiceOver in the
/// user's language instead of being spelled out), and *is this one thing a
/// person would call one emoji* (so the recent list stays clean).
enum EmojiText {
    /// Whether `text` starts with an emoji in its colour presentation: a
    /// scalar that is emoji by default (😂), or a text-default scalar that
    /// carries the emoji selector U+FE0F (❤️, ☀️, ✌️) or a skin-tone modifier.
    ///
    /// The selector check is why this is not just `properties.isEmoji`: that
    /// property is also true of the ASCII digits, `#` and `*` (keycap bases),
    /// which are ordinary labels.
    static func isEmoji(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        guard let first = scalars.first else { return false }
        let properties = first.properties
        if properties.isEmojiPresentation { return true }
        guard properties.isEmoji, first.value > 0xFF else { return false }
        // The selector, or a skin-tone modifier after a text-default base (☝🏽).
        return scalars.contains { $0.value == 0xFE0F || (0x1F3FB ... 0x1F3FF).contains($0.value) }
    }

    /// Whether `text` is exactly one emoji: one grapheme cluster that
    /// `isEmoji` accepts. Skin-tone, ZWJ and flag sequences are one cluster,
    /// which is what makes a single delete key press remove them whole.
    static func isSingleEmoji(_ text: String) -> Bool {
        isEmoji(text) && text.count == 1
    }
}
