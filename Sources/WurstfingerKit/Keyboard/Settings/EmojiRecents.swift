//
//  EmojiRecents.swift
//  Wurstfinger
//
//  The nine emoji the "recent" key offers, newest first.
//

import Foundation

/// The emoji the recent key carries: always exactly nine (one per gesture of
/// the 3×3 key), newest first, starting from the most used emoji worldwide.
///
/// A value type with no allocation in steady state, because `record(_:)` runs
/// on the keystroke that typed the emoji: the array is created at full
/// capacity, a record removes at most one element and inserts one, and an
/// emoji is a small string that lives inline. Persistence is separate and
/// never on that path: `load(from:)` runs when settings reload, `save(to:)`
/// when the emoji mode is left.
struct EmojiRecents: Equatable, Sendable {
    /// One per gesture of the recent key.
    static let capacity = 9

    /// What the key starts with, and pads with: the top of the Unicode
    /// Consortium's emoji frequency list that is not specific to a feeling
    /// family's own nuance (😂 ❤️ 😍 🤣 😊 🙏 💕 😭 😘).
    static let seed = ["😂", "❤️", "😍", "🤣", "😊", "🙏", "💕", "😭", "😘"]

    /// Newest first; `capacity` entries, no duplicates.
    private(set) var items: [String]

    init() {
        var items = Self.seed
        items.reserveCapacity(Self.capacity + 1)
        self.items = items
    }

    /// Rebuilds the list from what a defaults store held. Anything that is not
    /// one emoji, a repeat, or beyond the capacity is dropped (a hand-edited or
    /// corrupted value must not put text on a key), and the seed fills the rest.
    init(restoring stored: [String]?) {
        var items: [String] = []
        items.reserveCapacity(Self.capacity + 1)
        for candidate in stored ?? [] where items.count < Self.capacity
            && EmojiText.isSingleEmoji(candidate) && !items.contains(candidate) {
            items.append(candidate)
        }
        for filler in Self.seed where items.count < Self.capacity && !items.contains(filler) {
            items.append(filler)
        }
        self.items = items
    }

    /// Moves `emoji` to the front, or puts it there and drops the oldest.
    mutating func record(_ emoji: String) {
        if let index = items.firstIndex(of: emoji) {
            if index == 0 { return }
            items.remove(at: index)
        } else {
            items.removeLast()
        }
        items.insert(emoji, at: 0)
    }

    // MARK: - Persistence

    /// The list the store holds, or the seed when it holds none.
    static func load(from defaults: UserDefaults) -> EmojiRecents {
        EmojiRecents(restoring: defaults.stringArray(forKey: SettingsKey.emojiRecents.rawValue))
    }

    /// Writes the list, unless the store already holds it (every write fires
    /// `UserDefaults.didChangeNotification`, a full settings reload).
    func save(to defaults: UserDefaults) {
        let stored = defaults.stringArray(forKey: SettingsKey.emojiRecents.rawValue)
        guard stored != items else { return }
        defaults.set(items, forKey: SettingsKey.emojiRecents.rawValue)
    }
}
