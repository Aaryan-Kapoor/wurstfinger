//
//  CorpusTable.swift
//  WurstfingerLayoutLab
//
//  A language's text statistics: how often each character starts a word, ends
//  one, and follows another. The raw corpus is never kept; this table is what
//  is checked in (`tools/layout-lab/corpora/`).
//

import Foundation
@testable import WurstfingerKit

/// Counts of characters in running text, taken word by word.
///
/// A *character* is one NFC grapheme: a precomposed `ä` is one character here
/// and is expanded into `a` plus the diaeresis key only when a layout is scored
/// (`TextModel`), so the same table serves every arrangement of a language.
struct CorpusTable: Equatable {
    /// Free-form facts that travel with the numbers (source, licence, sizes).
    var meta: [String: String] = [:]
    /// Words starting with the character, weighted by word frequency.
    var initial: [String: Int] = [:]
    /// Words ending with the character.
    var final: [String: Int] = [:]
    /// Adjacent pairs inside words.
    var bigrams: [Pair: Int] = [:]

    struct Pair: Hashable {
        var first: String
        var second: String
    }

    /// Occurrences of each character: starts plus every position after another character.
    var occurrences: [String: Int] {
        var counts = initial
        for (pair, count) in bigrams { counts[pair.second, default: 0] += count }
        return counts
    }

    var tokenCount: Int { initial.values.reduce(0, +) }

    // MARK: Building from a word list

    /// Adds one word, `weight` times. Characters are lowercased with `locale`
    /// and NFC-normalized; a typographic apostrophe becomes `'`.
    mutating func add(word: String, weight: Int, locale: Locale) {
        let normalized = Self.normalize(word, locale: locale)
        let characters = normalized.map { String($0) }
        guard let first = characters.first, let last = characters.last else { return }
        initial[first, default: 0] += weight
        final[last, default: 0] += weight
        for index in 1 ..< characters.count {
            bigrams[Pair(first: characters[index - 1], second: characters[index]), default: 0] += weight
        }
    }

    static func normalize(_ word: String, locale: Locale) -> String {
        let folded = word.replacingOccurrences(of: "\u{2019}", with: "'")
        return folded.lowercased(with: locale).precomposedStringWithCanonicalMapping
    }

    /// Builds a table from `word count` lines (the FrequencyWords format),
    /// keeping a word only if `isTypable` accepts every character of it.
    static func fromWordList(
        _ text: String, locale: Locale, isTypable: (String) -> Bool, limit: Int = .max
    ) -> (table: CorpusTable, kept: Int, seen: Int) {
        var table = CorpusTable()
        var kept = 0
        var seen = 0
        var typable: [String: Bool] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if seen >= limit { break }
            let fields = line.split(separator: " ")
            guard fields.count == 2, let weight = Int(fields[1]) else { continue }
            seen += 1
            let word = normalize(String(fields[0]), locale: locale)
            let characters = word.map { String($0) }
            let ok = characters.allSatisfy { character in
                if let known = typable[character] { return known }
                let result = isTypable(character)
                typable[character] = result
                return result
            }
            guard ok, !characters.isEmpty else { continue }
            table.add(word: word, weight: weight, locale: locale)
            kept += 1
        }
        return (table, kept, seen)
    }

    // MARK: Text format

    /// `meta<TAB>key<TAB>value`, `init<TAB>c<TAB>n`, `final<TAB>c<TAB>n`,
    /// `big<TAB>a<TAB>b<TAB>n`; `#` starts a comment. Sorted, so the file is
    /// byte-identical for the same counts.
    func serialized(header: [String] = []) -> String {
        var lines = header.map { "# \($0)" }
        for key in meta.keys.sorted() { lines.append("meta\t\(key)\t\(meta[key]!)") }
        for key in initial.keys.sorted() { lines.append("init\t\(key)\t\(initial[key]!)") }
        for key in final.keys.sorted() { lines.append("final\t\(key)\t\(final[key]!)") }
        for pair in bigrams.keys.sorted(by: { ($0.first, $0.second) < ($1.first, $1.second) }) {
            lines.append("big\t\(pair.first)\t\(pair.second)\t\(bigrams[pair]!)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    init() {}

    init?(parsing text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "meta" where fields.count >= 3:
                meta[fields[1]] = fields[2...].joined(separator: "\t")
            case "init" where fields.count == 3:
                guard let count = Int(fields[2]) else { return nil }
                initial[fields[1]] = count
            case "final" where fields.count == 3:
                guard let count = Int(fields[2]) else { return nil }
                final[fields[1]] = count
            case "big" where fields.count == 4:
                guard let count = Int(fields[3]) else { return nil }
                bigrams[Pair(first: fields[1], second: fields[2])] = count
            default:
                return nil
            }
        }
        if initial.isEmpty { return nil }
    }
}
