//
//  CompletionSource.swift
//  Wurstfinger
//
//  Where completions come from: the platform's spell checker, or a stand-in.
//

import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A dictionary that finishes words.
///
/// Main-actor, like everything that reaches the host's text and, on iOS,
/// `UITextChecker` itself. A lookup runs where `WordCompletions` puts it: on a
/// timer after the keystroke that asked for it, never inside the keystroke.
/// Cost is the reason: a warm lookup is a few milliseconds and the first one
/// in a language loads its dictionary (about 300 ms measured with
/// `NSSpellChecker` on a Mac), which is why nothing may call it from the
/// touch path.
@MainActor
protocol CompletionSource: AnyObject {
    /// Whether this source can complete words of `locale` at all. A language
    /// without one gets no row (and no height reserved for it).
    func supports(_ locale: Locale) -> Bool

    /// Completions of `prefix`, best first, at most `limit`. Every one begins
    /// with `prefix` apart from case and is longer than it.
    func completions(for prefix: String, locale: Locale, limit: Int) -> [String]

    /// Loads whatever the first lookup in `locale` would otherwise pay for (the
    /// dictionary), so that lookup is as fast as the rest. Called off the
    /// touch path, on a timer, when the keyboard appears and the language
    /// changes. Does nothing by default.
    func warm(_ locale: Locale)

    /// Whether the dictionary of `locale` has `word` (so a word it lacks can
    /// be learned).
    func knows(_ word: String, locale: Locale) -> Bool
}

extension CompletionSource {
    func warm(_ locale: Locale) {}
}

/// The source of a keyboard with nothing to complete with: previews, tests and
/// tools that must not depend on the machine's dictionaries. Supports no
/// language, so no row is shown.
@MainActor
final class NullCompletionSource: CompletionSource {
    func supports(_ locale: Locale) -> Bool { false }
    func completions(for prefix: String, locale: Locale, limit: Int) -> [String] { [] }
    func knows(_ word: String, locale: Locale) -> Bool { true }
}

/// Which of the platform checker's languages serves a keyboard locale.
enum SpellLanguage {
    /// Languages whose words are not typed as letters-then-space, or whose
    /// letters are composed into syllables as they are typed: completing the
    /// "word before the cursor" means nothing there.
    static let unsupported: Set<String> = ["ja", "zh", "ko", "th", "lo", "km", "my"]

    /// The checker language for `locale` among `available`: the exact locale
    /// ("de_DE"), else the same language in the same region, else the
    /// language alone ("en"), else its first regional variant. Nil when the
    /// checker has none, or the language is one completions do not suit.
    static func match(_ locale: Locale, among available: [String]) -> String? {
        guard let language = locale.language.languageCode?.identifier,
              !unsupported.contains(language)
        else { return nil }
        let identifier = locale.identifier.replacingOccurrences(of: "-", with: "_")
        if available.contains(identifier) { return identifier }
        if available.contains(language) { return language }
        return available.sorted().first { $0.hasPrefix(language + "_") }
    }
}

/// The platform's spell checker: `UITextChecker` in the keyboard,
/// `NSSpellChecker` on a Mac (the scenario harness and the snapshot tool).
///
/// Ranking is the checker's own; no frequency list ships. The two checkers
/// order a prefix's completions by likelihood in practice ("hel" gives hello,
/// help, helps) but neither documents it, which is why the learned words
/// (`LearnedWordStore`) are ranked by the user's own counts on top of it.
@MainActor
final class SystemCompletionSource: CompletionSource {
    /// Matched checker language per locale identifier (nil: unsupported).
    private var languages: [String: String?] = [:]

    #if os(iOS)
    // iOS-ONLY (compiled on the device, not on the build machine). UITextChecker
    // calls below are the documented API; their behaviour in a keyboard
    // extension is verified only on a device (docs/ios-verification.md).
    // Lazy: a keyboard with the row off never looks a word up, so it never
    // builds one.
    private lazy var checker = UITextChecker()

    private static var availableLanguages: [String] { UITextChecker.availableLanguages }

    private func rawCompletions(_ prefix: String, language: String) -> [String] {
        let range = NSRange(location: 0, length: (prefix as NSString).length)
        return checker.completions(forPartialWordRange: range, in: prefix, language: language) ?? []
    }

    private func rawKnows(_ word: String, language: String) -> Bool {
        let range = NSRange(location: 0, length: (word as NSString).length)
        let misspelled = checker.rangeOfMisspelledWord(
            in: word, range: range, startingAt: 0, wrap: false, language: language
        )
        return misspelled.location == NSNotFound
    }
    #elseif os(macOS)
    private static var availableLanguages: [String] { NSSpellChecker.shared.availableLanguages }

    private func rawCompletions(_ prefix: String, language: String) -> [String] {
        let range = NSRange(location: 0, length: (prefix as NSString).length)
        return NSSpellChecker.shared.completions(
            forPartialWordRange: range, in: prefix, language: language, inSpellDocumentWithTag: 0
        ) ?? []
    }

    private func rawKnows(_ word: String, language: String) -> Bool {
        let misspelled = NSSpellChecker.shared.checkSpelling(
            of: word, startingAt: 0, language: language, wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil
        )
        return misspelled.location == NSNotFound
    }
    #endif

    private func language(for locale: Locale) -> String? {
        if let known = languages[locale.identifier] { return known }
        let match = SpellLanguage.match(locale, among: Self.availableLanguages)
        languages[locale.identifier] = .some(match)
        return match
    }

    func supports(_ locale: Locale) -> Bool {
        language(for: locale) != nil
    }

    func completions(for prefix: String, locale: Locale, limit: Int) -> [String] {
        guard let language = language(for: locale), !prefix.isEmpty else { return [] }
        let lowered = prefix.lowercased()
        return rawCompletions(prefix, language: language)
            .filter { $0.count > prefix.count && $0.lowercased().hasPrefix(lowered) }
            .prefix(limit)
            .map { $0 }
    }

    func warm(_ locale: Locale) {
        guard let language = language(for: locale) else { return }
        // One throwaway lookup: the checker loads its dictionary for the
        // language on first use, which is the slow part (about 300 ms measured
        // with `NSSpellChecker`; unmeasured on a device).
        _ = rawCompletions("a", language: language)
    }

    func knows(_ word: String, locale: Locale) -> Bool {
        guard let language = language(for: locale) else { return true }
        return rawKnows(word, language: language)
    }
}
