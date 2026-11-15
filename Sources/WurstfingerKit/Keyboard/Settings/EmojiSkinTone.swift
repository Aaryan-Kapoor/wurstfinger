//
//  EmojiSkinTone.swift
//  Wurstfinger
//
//  The one skin-tone preference of the emoji mode.
//

import Foundation

/// The skin tone the emoji mode's hands and people are drawn and typed in.
///
/// One stored preference rather than a tone per emoji: the map holds only the
/// default (yellow) form of every emoji, and `applying(to:)` turns the ones that
/// can carry a tone into base plus Fitzpatrick modifier when the pages are
/// built (`EmojiLayouts.modes`). Building is where this belongs, not the
/// keystroke: the hint, the guide card, VoiceOver and the typed text all read
/// the same binding, so they cannot disagree, and a keystroke does no extra
/// work (a tone step per commit would be a string built per emoji).
///
/// Every result is still one grapheme cluster: a base and its modifier are one.
enum EmojiSkinTone: Int, CaseIterable, Sendable {
    /// The default, yellow form: nothing is added.
    case none = 0
    case light, mediumLight, medium, mediumDark, dark

    /// The Fitzpatrick modifier U+1F3FB…U+1F3FF, or `nil` for the default.
    var modifier: Unicode.Scalar? {
        self == .none ? nil : Unicode.Scalar(0x1F3FB + UInt32(rawValue - 1))
    }

    /// Whether `emoji` is one emoji that takes a skin tone: a single
    /// `Emoji_Modifier_Base` scalar, with or without the emoji selector.
    /// Sequences (a ZWJ family, a flag) and faces are left alone.
    static func supportsTone(_ emoji: String) -> Bool {
        var base: Unicode.Scalar?
        for scalar in emoji.unicodeScalars where scalar.value != 0xFE0F {
            if base != nil { return false }
            base = scalar
        }
        return base?.properties.isEmojiModifierBase == true
    }

    /// `emoji` in this tone, or unchanged when it takes none (or this is the
    /// default). The selector U+FE0F drops out: a modified base needs none
    /// (`☝🏽`, not `☝️🏽`).
    func applying(to emoji: String) -> String {
        guard let modifier, Self.supportsTone(emoji),
              let base = emoji.unicodeScalars.first(where: { $0.value != 0xFE0F })
        else { return emoji }
        var result = String.UnicodeScalarView()
        result.append(base)
        result.append(modifier)
        return String(result)
    }

    /// The thumbs-up in this tone: how the setting shows its choices.
    var sample: String { applying(to: "👍") }

    // MARK: - Persistence

    /// The stored preference; anything unrecognised is the default.
    static func load(from defaults: UserDefaults) -> EmojiSkinTone {
        EmojiSkinTone(rawValue: defaults.integer(forKey: SettingsKey.emojiSkinTone.rawValue)) ?? .none
    }
}
