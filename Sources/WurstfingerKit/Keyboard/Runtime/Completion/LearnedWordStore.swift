//
//  LearnedWordStore.swift
//  Wurstfinger
//
//  The words the keyboard learned from its user: names and jargon the system
//  dictionary lacks, offered back once they have been typed twice.
//

import Foundation

/// The keyboard's own list of learned words.
///
/// **Privacy.** The list lives in a file in the keyboard extension's own
/// container: not in the shared app group, not in iCloud, nowhere the host app
/// or another process can read. The words are never sent anywhere, and the
/// store is never fed from a sensitive field (`WordCompletions` does not
/// observe one). Because the host app cannot reach that container, clearing
/// goes through a token in the shared settings: the app writes a fresh one
/// (`SettingsKey.learnedWordsClearToken`) and the keyboard wipes its list the
/// next time it reloads settings and sees a token it has not seen.
///
/// **What is learned** is decided by the caller (a word the dictionary lacks,
/// at least three letters); what is *offered* is decided here: a word needs
/// `minimumUses` sightings, so a typo typed once never comes back as a
/// suggestion. The list is capped (`capacity`), dropping the least used first.
///
/// `UITextChecker.learnWord` would put the words in the system's dictionary,
/// shared with every other app's autocorrect and not clearable from here; its
/// behaviour in an extension is unverified, so this list stays the keyboard's
/// own.
@MainActor
final class LearnedWordStore {
    /// How many times a word must have been seen before it is offered.
    static let minimumUses = 2
    /// Most words kept across all languages.
    static let capacity = 1500
    /// How long after the last change the file is written (a burst of typing
    /// writes once).
    static let saveDelay: TimeInterval = 5

    /// What the file holds. Versioned so a later format can migrate it.
    private struct Snapshot: Codable {
        var version = 1
        var clearToken: String?
        /// Language code -> word -> [uses, last-used tick].
        var words: [String: [String: [Int]]] = [:]
    }

    private let fileURL: URL?
    private let timers: any TimerSource
    private var snapshot = Snapshot()
    private var isLoaded = false
    /// The clear token the settings last carried, applied once the file is read.
    private var requestedClearToken: String?
    private var pendingSave: TimerHandle?
    /// Monotonic count of notes, to order words by recency without a clock.
    private var tick = 0

    /// - Parameters:
    ///   - fileURL: Where the list persists; nil keeps it in memory only
    ///     (previews, tests, tools).
    ///   - timers: The clock the delayed save runs on.
    init(fileURL: URL?, timers: any TimerSource) {
        self.fileURL = fileURL
        self.timers = timers
    }

    /// The keyboard's list: a file in its own container's Application Support.
    static var defaultFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Wurstfinger", isDirectory: true)
            .appendingPathComponent("LearnedWords.json")
    }

    /// How many words are stored, for tests and diagnostics.
    var count: Int {
        loadIfNeeded()
        return snapshot.words.values.reduce(0) { $0 + $1.count }
    }

    /// The learned words of `language` that complete `prefix`, most used
    /// first, at most `limit`. Only words seen at least `minimumUses` times.
    func completions(for prefix: String, language: String, limit: Int) -> [String] {
        loadIfNeeded()
        guard let entries = snapshot.words[language], !entries.isEmpty, !prefix.isEmpty else { return [] }
        let lowered = prefix.lowercased()
        let matches = entries.filter { word, usage in
            usage[0] >= Self.minimumUses && word.count > prefix.count && word.lowercased().hasPrefix(lowered)
        }
        return matches
            .sorted { ($0.value[0], $0.value[1], $1.key) > ($1.value[0], $1.value[1], $0.key) }
            .prefix(limit)
            .map(\.key)
    }

    /// Records one sighting of `word` (typed in full, or accepted from the row).
    func note(_ word: String, language: String) {
        loadIfNeeded()
        tick += 1
        var entries = snapshot.words[language] ?? [:]
        let uses = (entries[word]?[0] ?? 0) + 1
        entries[word] = [uses, tick]
        snapshot.words[language] = entries
        enforceCapacity()
        scheduleSave()
    }

    /// Records a use of a word that is already in the list (an accepted
    /// completion), and ignores any other.
    func noteUse(of word: String, language: String) {
        loadIfNeeded()
        guard snapshot.words[language]?[word] != nil else { return }
        note(word, language: language)
    }

    /// Forgets every word.
    func clear() {
        loadIfNeeded()
        snapshot.words = [:]
        scheduleSave()
    }

    /// Wipes the list when the host app asked for it since the keyboard last
    /// looked: `token` differs from the one the list remembers.
    ///
    /// The comparison waits for the file to be read (the first lookup or
    /// note), so a settings reload at launch never touches the disk.
    func applyClearToken(_ token: String?) {
        requestedClearToken = token
        if isLoaded { applyRequestedClearToken() }
    }

    private func applyRequestedClearToken() {
        guard let token = requestedClearToken, token != snapshot.clearToken else { return }
        snapshot.words = [:]
        snapshot.clearToken = token
        scheduleSave()
    }

    // MARK: - Persistence

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        defer { applyRequestedClearToken() }
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Snapshot.self, from: data),
              stored.version == 1
        else { return }
        snapshot = stored
        tick = stored.words.values.flatMap(\.values).map { $0[1] }.max() ?? 0
    }

    private func enforceCapacity() {
        var total = snapshot.words.values.reduce(0) { $0 + $1.count }
        guard total > Self.capacity else { return }
        // Least used, then least recent, goes first, across languages.
        let ranked = snapshot.words
            .flatMap { language, entries in entries.map { (language: language, word: $0.key, usage: $0.value) } }
            .sorted { ($0.usage[0], $0.usage[1]) < ($1.usage[0], $1.usage[1]) }
        for entry in ranked where total > Self.capacity {
            snapshot.words[entry.language]?[entry.word] = nil
            total -= 1
        }
    }

    private func scheduleSave() {
        guard fileURL != nil, pendingSave == nil else { return }
        pendingSave = timers.schedule(after: Self.saveDelay) { [weak self] in
            self?.pendingSave = nil
            self?.saveNow()
        }
    }

    /// Writes the list at once (also what the delayed save runs).
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
