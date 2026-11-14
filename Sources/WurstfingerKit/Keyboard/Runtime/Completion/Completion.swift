//
//  Completion.swift
//  Wurstfinger
//
//  What a word completion is, how the word before the cursor is found, and
//  what accepting a completion changes in the text. Pure values and functions:
//  nothing here touches the host's text or a dictionary.
//

import Foundation

/// One suggested word, as the row above the keys shows it.
struct Completion: Equatable, Sendable, Identifiable {
    /// The whole word, as the dictionary spells it.
    let word: String
    /// How many leading characters of `word` the user has already typed, case
    /// aside. The row de-emphasizes them and sets the rest in the foreground.
    let typedCount: Int

    var id: String { word }

    /// A completion of `word` for what has been typed so far.
    init(word: String, typed prefix: String) {
        self.word = word
        typedCount = Self.commonPrefixLength(word, prefix)
    }

    /// Characters two words share from the start, compared without case.
    static func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        for (a, b) in zip(lhs, rhs) {
            guard Self.matches(a, b) else { break }
            count += 1
        }
        return count
    }

    /// Whether two characters are the same letter apart from case.
    static func matches(_ a: Character, _ b: Character) -> Bool {
        a == b || String(a).lowercased() == String(b).lowercased()
    }

    /// The word split at the end of what was typed: the part to de-emphasize
    /// and the part that accepting adds.
    var split: (typed: Substring, rest: Substring) {
        let index = word.index(word.startIndex, offsetBy: typedCount, limitedBy: word.endIndex) ?? word.endIndex
        return (word[..<index], word[index...])
    }
}

/// What accepting a completion does to the text: delete some characters
/// behind the cursor, then insert a string.
struct CompletionEdit: Equatable, Sendable {
    var deleteCount: Int
    var insert: String

    /// The edit that finishes `prefix` as `word`.
    ///
    /// A word that extends what was typed (case aside) only gets its missing
    /// end typed, so the user's own letters stay exactly as they are: "Hel"
    /// accepts "hello" as "Hello", and a prefix typed in capitals ("NAS")
    /// continues in capitals ("NASA"). A word that does not extend it (the
    /// dictionary changed a letter) replaces the typed prefix whole.
    ///
    /// - Parameter appendingSpace: The space that follows an accepted word.
    static func accepting(_ word: String, over prefix: String, appendingSpace: Bool = true) -> CompletionEdit {
        let space = appendingSpace ? " " : ""
        let typed = Array(prefix)
        let target = Array(word)
        let extends = target.count >= typed.count
            && zip(typed, target).allSatisfy { Completion.matches($0, $1) }
        guard extends else {
            return CompletionEdit(deleteCount: typed.count, insert: word + space)
        }
        var rest = String(target[typed.count...])
        if typed.count >= 2, typed.allSatisfy({ !$0.isLowercase }), typed.contains(where: \.isUppercase) {
            rest = rest.uppercased()
        }
        return CompletionEdit(deleteCount: 0, insert: rest + space)
    }
}

/// Finds the word being typed in the text around the cursor.
enum PartialWord {
    /// Longest word completions are looked up for: past this the "word" is a
    /// pasted run of letters, not something being typed.
    static let maximumLength = 40

    /// Characters a word is made of: letters (a letter with its combining
    /// marks and a Persian half-space is one `Character`, which counts as a
    /// letter by its first scalar) and the apostrophe inside "don't" (not at
    /// its start).
    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character == "'" || character == "\u{2019}"
    }

    /// Characters in front of a word that make it part of something else (a
    /// number, an address, a path, an identifier) that completions would only
    /// get wrong.
    private static let blockingPredecessors: Set<Character> = ["@", "/", "\\", "_"]

    /// The word that ends at the cursor, or "" when the cursor is not at the
    /// end of one.
    static func before(_ context: String?) -> String {
        guard let context, !context.isEmpty else { return "" }
        var characters: [Character] = []
        var predecessor: Character?
        for character in context.reversed() {
            if isWordCharacter(character) {
                characters.append(character)
                if characters.count > maximumLength { return "" }
            } else {
                predecessor = character
                break
            }
        }
        // A leading apostrophe is a quote, not part of the word.
        while let last = characters.last, last == "'" || last == "\u{2019}" {
            characters.removeLast()
        }
        guard !characters.isEmpty else { return "" }
        if let predecessor, predecessor.isNumber || blockingPredecessors.contains(predecessor) { return "" }
        return String(characters.reversed())
    }

    /// Whether the cursor sits inside a word: the character after it belongs
    /// to one. Completing there would splice a word into another.
    static func continuesAfterCursor(_ context: String?) -> Bool {
        guard let first = context?.first else { return false }
        return isWordCharacter(first)
    }

    /// The word the user just finished, when the cursor sits behind it and
    /// the one to three separator characters that ended it ("hello, ").
    /// Nil when the text before the cursor does not end like that.
    static func justFinished(_ context: String?) -> String? {
        guard let context, !context.isEmpty else { return nil }
        var separators = 0
        var end = context.endIndex
        while end > context.startIndex {
            let previous = context.index(before: end)
            guard !isWordCharacter(context[previous]) else { break }
            separators += 1
            if separators > 3 { return nil }
            end = previous
        }
        guard separators > 0 else { return nil }
        let word = before(String(context[..<end]))
        return word.isEmpty ? nil : word
    }
}

/// Which hosts want no suggestions, decided from what the field says about
/// itself. Platform-neutral: the controller maps UIKit's enums onto these.
struct CompletionFieldPolicy: Sendable, Equatable {
    /// The on-screen keyboard the field asked for.
    enum Keyboard: Sendable, Equatable {
        case standard, url, email, numeric, phone
    }

    /// What the field says it holds.
    enum Content: Sendable, Equatable {
        case text, url, email, username, phoneNumber, postalCode, code
    }

    var keyboard = Keyboard.standard
    var content = Content.text
    /// The host turned autocorrection off, which iOS's own keyboard reads as
    /// "no suggestions either" (code editors, search by exact name).
    var disablesAutocorrection = false

    /// Whether suggestions would be out of place here.
    var suppressesCompletions: Bool {
        if disablesAutocorrection { return true }
        switch keyboard {
        case .standard: break
        case .url, .email, .numeric, .phone: return true
        }
        switch content {
        case .text: return false
        case .url, .email, .username, .phoneNumber, .postalCode, .code: return true
        }
    }
}
