//
//  TextReplacement.swift
//  Wurstfinger
//
//  The user's text-replacement shortcuts ("omw" -> "On my way!"): the entry
//  type, the validated lookup table the keyboard consults, and how both are
//  stored in the shared defaults.
//

import Foundation

/// One shortcut and the phrase it expands to.
///
/// `Codable` with the property names as the stored field names, so the JSON
/// in the shared defaults reads `[{"shortcut": "omw", "phrase": "On my way!"}]`
/// — those names are on disk and must not change.
struct TextReplacementEntry: Codable, Equatable, Sendable, Identifiable {
    var shortcut: String
    var phrase: String

    var id: String { shortcut }
}

/// Why a shortcut/phrase pair cannot be saved.
enum TextReplacementError: Error, Equatable, Sendable {
    case emptyShortcut
    case shortcutContainsWhitespace
    case shortcutTooLong
    case emptyPhrase
    case phraseTooLong
    case duplicateShortcut
    case tableFull
}

/// The shortcuts the keyboard expands, validated and indexed for lookup.
///
/// **Built once, read per keystroke.** The view model decodes the stored JSON
/// when settings change (`TypingBehavior.load`) and keeps the table in its
/// `typingBehavior` snapshot. A keystroke that ends a word then costs two
/// dictionary lookups — one exact, one case-folded — and never touches the
/// defaults store or the JSON.
///
/// **Case.** An exact match wins. Otherwise the shortcut is matched ignoring
/// case and the way the user capitalised what they typed carries over to the
/// phrase (see `lookup(_:locale:)`), so with `gm` -> `good morning` stored,
/// typing `Gm` gives `Good morning`.
struct TextReplacementTable: Sendable, Equatable {
    /// Longest shortcut, in characters.
    static let maxShortcutLength = 32
    /// Longest phrase, in characters.
    static let maxPhraseLength = 1000
    /// Most entries a table holds. Bounds what the keyboard decodes and what
    /// the shared defaults carry (a phrase can be long, and the store is
    /// read by both processes).
    static let maxEntries = 500

    static let empty = TextReplacementTable(entries: [])

    /// The valid entries, in the order the user keeps them.
    let entries: [TextReplacementEntry]

    /// The stored JSON this table was decoded from (`nil` when nothing was
    /// stored). Lets a settings reload that found the same string reuse the
    /// table instead of decoding it again.
    let source: String?

    private let exact: [String: String]
    private let folded: [String: String]

    var isEmpty: Bool { exact.isEmpty }

    /// Builds a table from `entries`, dropping any that are invalid or repeat
    /// an earlier shortcut exactly, and stopping at `maxEntries`.
    init(entries candidates: [TextReplacementEntry], source: String? = nil) {
        var kept: [TextReplacementEntry] = []
        var exact: [String: String] = [:]
        var folded: [String: String] = [:]
        for entry in candidates where kept.count < Self.maxEntries {
            guard (try? Self.validate(shortcut: entry.shortcut, phrase: entry.phrase)) != nil,
                  exact[entry.shortcut] == nil
            else { continue }
            kept.append(entry)
            exact[entry.shortcut] = entry.phrase
            // The first of several shortcuts that differ only in case answers
            // the case-insensitive lookup; each still matches itself exactly.
            let key = entry.shortcut.lowercased()
            if folded[key] == nil { folded[key] = entry.phrase }
        }
        entries = kept
        self.source = source
        self.exact = exact
        self.folded = folded
    }

    static func == (lhs: TextReplacementTable, rhs: TextReplacementTable) -> Bool {
        lhs.entries == rhs.entries
    }

    // MARK: - Validation

    /// Checks one shortcut/phrase pair against the rules: a shortcut is 1 to
    /// `maxShortcutLength` characters with no whitespace; a phrase is 1 to
    /// `maxPhraseLength` characters.
    static func validate(shortcut: String, phrase: String) throws(TextReplacementError) {
        guard !shortcut.isEmpty else { throw .emptyShortcut }
        guard !shortcut.contains(where: \.isWhitespace) else { throw .shortcutContainsWhitespace }
        guard shortcut.count <= maxShortcutLength else { throw .shortcutTooLong }
        guard !phrase.isEmpty else { throw .emptyPhrase }
        guard phrase.count <= maxPhraseLength else { throw .phraseTooLong }
    }

    /// Validates a pair about to be saved into `existing`. `replacing` is the
    /// shortcut of the entry being edited (it may keep its own shortcut).
    static func validate(
        shortcut: String, phrase: String, existing: [TextReplacementEntry], replacing: String? = nil
    ) throws(TextReplacementError) {
        try validate(shortcut: shortcut, phrase: phrase)
        if existing.contains(where: { $0.shortcut == shortcut && $0.shortcut != replacing }) {
            throw .duplicateShortcut
        }
        if replacing == nil, existing.count >= maxEntries { throw .tableFull }
    }

    // MARK: - Lookup

    /// The phrase to type for `typed`, or `nil` when it is not a shortcut.
    ///
    /// An exact match returns the phrase as stored. A match that differs only
    /// in case transfers the typed capitalisation:
    /// - all capitals (two or more letters, `GM`) -> the phrase in capitals;
    /// - a leading capital (`Gm`) -> the phrase with its first letter capitalised;
    /// - anything else -> the phrase as stored.
    func lookup(_ typed: String, locale: Locale = .current) -> String? {
        if let phrase = exact[typed] { return phrase }
        guard let phrase = folded[typed.lowercased()] else { return nil }
        let letters = typed.filter(\.isLetter)
        if letters.count >= 2, letters == letters.uppercased(with: locale),
           letters != letters.lowercased(with: locale) {
            return phrase.uppercased(with: locale)
        }
        if typed.first?.isUppercase == true {
            return Self.capitalizingFirst(phrase, locale: locale)
        }
        return phrase
    }

    private static func capitalizingFirst(_ phrase: String, locale: Locale) -> String {
        guard let first = phrase.first else { return phrase }
        return String(first).uppercased(with: locale) + phrase.dropFirst()
    }

    // MARK: - Storage

    /// Decodes the stored JSON. Anything unreadable is an empty table: a
    /// corrupt value must never stop the keyboard from typing.
    static func decode(_ json: String?) -> TextReplacementTable {
        guard let json, let data = json.data(using: .utf8),
              let entries = try? JSONDecoder().decode([TextReplacementEntry].self, from: data)
        else { return TextReplacementTable(entries: [], source: json) }
        return TextReplacementTable(entries: entries, source: json)
    }

    /// The JSON to store for `entries`.
    static func encode(_ entries: [TextReplacementEntry]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries), let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    /// Loads the table from a defaults store, reusing `previous` when the
    /// stored JSON has not changed. Call when settings change, never per
    /// keystroke.
    static func load(from store: UserDefaults, reusing previous: TextReplacementTable? = nil) -> TextReplacementTable {
        let json = store.string(forKey: SettingsKey.textReplacements.rawValue)
        if let previous, previous.source == json { return previous }
        return decode(json)
    }
}
