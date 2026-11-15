//
//  ScriptedCompletionSource.swift
//  WurstfingerScenarioKit
//
//  A dictionary the test or the snapshot tool writes, so the word completion
//  row shows the same words on every machine.
//

import Foundation
@testable import WurstfingerKit

/// A `CompletionSource` over a fixed word list: the completions of a prefix are
/// the listed words that begin with it, in list order. Records every lookup.
@MainActor
final class ScriptedCompletionSource: CompletionSource {
    /// The dictionary, best first.
    var words: [String]
    /// Words `knows` answers yes to (the rest are unknown, so they can be learned).
    var knownWords: Set<String>
    /// Languages it serves (a language code such as "en"); nil serves all.
    var languages: Set<String>?

    /// The prefixes looked up, in order.
    private(set) var lookups: [String] = []

    init(words: [String], knownWords: Set<String> = [], languages: Set<String>? = nil) {
        self.words = words
        self.knownWords = knownWords
        self.languages = languages
    }

    func supports(_ locale: Locale) -> Bool {
        guard let languages else { return true }
        return locale.language.languageCode.map { languages.contains($0.identifier) } ?? false
    }

    func completions(for prefix: String, locale: Locale, limit: Int) -> [String] {
        lookups.append(prefix)
        let lowered = prefix.lowercased()
        return words
            .filter { $0.count > prefix.count && $0.lowercased().hasPrefix(lowered) }
            .prefix(limit)
            .map { $0 }
    }

    /// The languages `warm` was called for, in order.
    private(set) var warmed: [String] = []

    func warm(_ locale: Locale) {
        warmed.append(locale.language.languageCode?.identifier ?? "und")
    }

    func knows(_ word: String, locale: Locale) -> Bool {
        knownWords.contains(word)
    }
}
