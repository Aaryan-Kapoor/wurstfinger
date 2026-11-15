//
//  WordCompletions.swift
//  Wurstfinger
//
//  The word completion row's brain: when to look a word up, what to show, and
//  what accepting one does to the text.
//

import Foundation
import Observation

/// Completions of the word before the cursor, and the auto-space that follows
/// accepting one.
///
/// **Not on the keystroke path.** A keystroke only calls `noteKeystroke()`: a
/// flag check when the row is off, and otherwise a poke of one long-lived
/// `Waker` (or, after a slow lookup, one timer that waits for a pause). The
/// lookup itself runs when the waker does, after the keystroke has been
/// delivered and the run loop is free, and reads the text as it is *then*, so
/// a lookup can never describe a word the user has since moved past.
/// Keystrokes that arrive before it runs share it (coalescing); nothing in
/// that path reads the host's text, the dictionary or the learned words.
///
/// Observed state is only `candidates`; the row re-renders when that changes
/// and nothing else invalidates a view.
@MainActor
@Observable
final class WordCompletions {
    /// Shortest word a lookup is made for. One letter completes to everything.
    static let minimumPrefix = 2
    /// Completions shown.
    static let displayedCount = 3
    /// Completions asked of the dictionary, so duplicates and the learned
    /// words still leave `displayedCount` after merging.
    static let fetchedCount = 8
    /// How long a lookup waits after a keystroke when the last one was slow
    /// (over `slowLookup`): fast typing then shares one lookup per pause.
    static let slowLookupDelay: TimeInterval = 0.06
    static let slowLookup: TimeInterval = 0.006
    /// How long after the keyboard appears, or the language changes, the
    /// dictionary is warmed: after the appearance animation and before a
    /// first keystroke is likely, and never inside a touch.
    static let warmUpDelay: TimeInterval = 0.4
    /// Silence after which the top completion is spoken under VoiceOver
    /// gesture typing.
    static let announcementPause: TimeInterval = 1.0
    /// The space an accepted word is followed by.
    private static let space: Character = " "

    // MARK: - What the row shows

    /// The completions of the word being typed, best first (at most
    /// `displayedCount`). Empty when there are none or the row is off.
    private(set) var candidates: [Completion] = []

    // MARK: - Collaborators

    /// The dictionary. Replaceable so tests and the snapshot tool script it.
    @ObservationIgnored var source: any CompletionSource {
        didSet { reconfigure() }
    }
    @ObservationIgnored let learned: LearnedWordStore
    @ObservationIgnored private let timers: any TimerSource
    @ObservationIgnored private let target: () -> TextInputTarget?

    /// Asked before an announcement is armed: true when VoiceOver gesture
    /// typing is on and a screen reader is listening.
    @ObservationIgnored var canAnnounce: () -> Bool = { false }
    /// Speaks a completion ("Suggestion: hello").
    @ObservationIgnored var announce: (Completion) -> Void = { _ in }

    // MARK: - Configuration

    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var learnsWords = true
    @ObservationIgnored private var traits = FieldTraits.standard
    @ObservationIgnored private var locale = Locale(identifier: "en_US")

    /// Whether completions are being offered: the setting is on, the field
    /// allows them and the source has a dictionary for the language. Stored,
    /// so the keystroke path reads one flag.
    @ObservationIgnored private(set) var isActive = false

    // MARK: - Refresh state

    @ObservationIgnored private var pendingRefresh: TimerHandle?
    @ObservationIgnored private var pendingAnnouncement: TimerHandle?
    @ObservationIgnored private var pendingWarmUp: TimerHandle?
    /// Languages the source has been warmed for (this process).
    @ObservationIgnored private var warmedLanguages: Set<String> = []
    @ObservationIgnored private var lookupDelay: TimeInterval = 0
    /// The prefix `candidates` were looked up for.
    @ObservationIgnored private var candidatesPrefix = ""
    /// The longest word prefix a refresh last saw, to recognise the moment a
    /// word is finished (see `learnFinishedWord`).
    @ObservationIgnored private var lastObservedPrefix = ""
    /// Whether the space just before the cursor was typed by accepting a
    /// completion and nothing has happened since.
    @ObservationIgnored private(set) var isAutoSpacePending = false
    /// How often refreshes ran, for tests: proves coalescing.
    @ObservationIgnored private(set) var refreshCount = 0

    /// The lookup's trigger, made on the first keystroke with the row on:
    /// poking it is the whole cost of a keystroke from then on.
    @ObservationIgnored private var refreshWaker: Waker?

    /// The delayed trigger's action, built once.
    @ObservationIgnored private lazy var fireRefresh: @MainActor () -> Void = { [weak self] in
        self?.refreshFired()
    }

    init(
        timers: any TimerSource,
        source: any CompletionSource,
        learned: LearnedWordStore,
        target: @escaping () -> TextInputTarget?
    ) {
        self.timers = timers
        self.source = source
        self.learned = learned
        self.target = target
    }

    // MARK: - Configuration

    /// Applies the settings, the field's traits and the language. Cheap and
    /// idempotent: the view model calls it whenever any of them may have
    /// changed.
    func configure(isEnabled: Bool, learnsWords: Bool, traits: FieldTraits, locale: Locale) {
        self.isEnabled = isEnabled
        self.learnsWords = learnsWords
        self.traits = traits
        let languageChanged = self.locale.identifier != locale.identifier
        self.locale = locale
        reconfigure()
        if languageChanged { warmUp() }
    }

    /// Warms the dictionary for the current language on a timer, once per
    /// language: the first lookup is the slow one (it loads the dictionary), and
    /// this moves that cost to a moment when no finger is on the keys. The
    /// controller calls it when the keyboard appears; `configure` when the
    /// language changes. A no-op while the row is off.
    func warmUp() {
        guard isActive, pendingWarmUp == nil, !warmedLanguages.contains(languageKey) else { return }
        pendingWarmUp = timers.schedule(after: Self.warmUpDelay) { [weak self] in
            guard let self else { return }
            pendingWarmUp = nil
            guard isActive, warmedLanguages.insert(languageKey).inserted else { return }
            source.warm(locale)
        }
    }

    private func reconfigure() {
        let active = isEnabled && traits.allowsCompletions && source.supports(locale)
        guard active != isActive else { return }
        isActive = active
        // Coming on mid-word (the setting, a field that allows it, a language
        // switch) fills the row for the word already there.
        if active { noteKeystroke() } else { reset() }
    }

    /// Forgets everything about the word being typed (a field switch, the row
    /// turning off).
    func reset() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        refreshWaker?.cancelPending()
        pendingAnnouncement?.cancel()
        pendingAnnouncement = nil
        pendingWarmUp?.cancel()
        pendingWarmUp = nil
        isAutoSpacePending = false
        lastObservedPrefix = ""
        candidatesPrefix = ""
        setCandidates([])
    }

    // MARK: - Keystrokes

    /// A keystroke was delivered: look the word up once the run loop is free.
    /// Called from the pipeline for every action; free when the row is off.
    func noteKeystroke() {
        guard isActive else { return }
        if lookupDelay == 0 {
            // The usual case: the waker costs a poke, not a timer.
            if refreshWaker == nil {
                refreshWaker = timers.makeWaker { [weak self] in self?.refreshFired() }
            }
            refreshWaker?.poke()
        } else if pendingRefresh == nil {
            // After a slow lookup the next one waits for a pause (a timer).
            pendingRefresh = timers.schedule(after: lookupDelay, fireRefresh)
        }
    }

    private func refreshFired() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        refresh()
    }

    /// Looks the word before the cursor up now. What the timer runs; tests and
    /// tools may call it directly.
    func refresh() {
        refreshCount += 1
        guard isActive, let target = target() else {
            setCandidates([])
            return
        }
        let context = target.documentContextBeforeInput
        let prefix = PartialWord.before(context)

        if prefix.isEmpty {
            learnFinishedWord(in: context)
            lastObservedPrefix = ""
        } else {
            lastObservedPrefix = prefix
        }

        guard prefix.count >= Self.minimumPrefix,
              target.selectedText?.isEmpty != false,
              !PartialWord.continuesAfterCursor(target.documentContextAfterInput)
        else {
            candidatesPrefix = ""
            setCandidates([])
            return
        }
        // The same word as the last lookup: nothing changed that it depends on.
        if prefix == candidatesPrefix, !candidates.isEmpty { return }

        let started = ProcessInfo.processInfo.systemUptime
        let system = source.completions(for: prefix, locale: locale, limit: Self.fetchedCount)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        lookupDelay = elapsed > Self.slowLookup ? Self.slowLookupDelay : 0

        candidatesPrefix = prefix
        setCandidates(merged(system: system, prefix: prefix))
        scheduleAnnouncement()
    }

    /// The learned words that complete `prefix`, then the dictionary's, without
    /// repeats, without the word as typed, at most `displayedCount`.
    private func merged(system: [String], prefix: String) -> [Completion] {
        let language = languageKey
        let own = learned.completions(for: prefix, language: language, limit: 2)
        let lowered = prefix.lowercased()
        var seen: Set<String> = [lowered]
        var result: [Completion] = []
        for word in own + system where word.count > prefix.count {
            guard seen.insert(word.lowercased()).inserted else { continue }
            result.append(Completion(word: word, typed: prefix))
            if result.count == Self.displayedCount { break }
        }
        return result
    }

    private func setCandidates(_ new: [Completion]) {
        guard candidates != new else { return }
        candidates = new
        if new.isEmpty {
            pendingAnnouncement?.cancel()
            pendingAnnouncement = nil
        }
    }

    /// Replaces the shown completions with `words` for the word before the
    /// cursor, bypassing the lookup. For the snapshot tool, which renders a
    /// row without running a run loop.
    func present(words: [String]) {
        let prefix = PartialWord.before(target()?.documentContextBeforeInput)
        candidatesPrefix = prefix
        setCandidates(words.map { Completion(word: $0, typed: prefix) })
    }

    // MARK: - Learning

    private var languageKey: String {
        locale.language.languageCode?.identifier ?? "und"
    }

    /// A word that looks like something worth remembering: letters (and an
    /// inner apostrophe), three or more of them, no digits.
    private static func isLearnable(_ word: String) -> Bool {
        word.count >= 3 && word.count <= 24 && word.allSatisfy { PartialWord.isWordCharacter($0) }
    }

    /// Notes the word that was just finished, when it is one the dictionary
    /// lacks. A word counts only if the refresh before saw it being typed
    /// (its last prefix is the word, or the word minus the letter that came
    /// in between): text that was pasted or typed into another field and then
    /// switched to is not the user's vocabulary.
    private func learnFinishedWord(in context: String?) {
        guard learnsWords, !lastObservedPrefix.isEmpty,
              let word = PartialWord.justFinished(context),
              word.hasPrefix(lastObservedPrefix),
              word.count - lastObservedPrefix.count <= 1,
              Self.isLearnable(word)
        else { return }
        if !source.knows(word, locale: locale) {
            learned.note(word, language: languageKey)
        } else {
            learned.noteUse(of: word, language: languageKey)
        }
    }

    // MARK: - Accepting

    /// Finishes the word before the cursor as `completion`: types the rest of
    /// it and a space. Returns whether anything was typed.
    ///
    /// Works from the text as it is now, not as it was when the row was drawn,
    /// so a completion that went stale (a letter typed since) still produces
    /// the word, never a mangled one. Nothing is typed when the cursor no
    /// longer follows a word (the user moved on) or text is selected.
    @discardableResult
    func accept(_ completion: Completion) -> Bool {
        guard isActive, let target = target(), target.selectedText?.isEmpty != false else { return false }
        let prefix = PartialWord.before(target.documentContextBeforeInput)
        guard !prefix.isEmpty else { return false }

        let edit = CompletionEdit.accepting(completion.word, over: prefix)
        for _ in 0 ..< edit.deleteCount { target.deleteBackward() }
        target.insertText(edit.insert)

        isAutoSpacePending = edit.insert.last == Self.space
        learned.noteUse(of: completion.word, language: languageKey)
        // The word is done; whatever the next refresh finds is the next word.
        lastObservedPrefix = ""
        candidatesPrefix = ""
        setCandidates([])
        noteKeystroke()
        return true
    }

    /// Accepts the first completion, if there is one.
    @discardableResult
    func acceptTop() -> Bool {
        guard let top = candidates.first else { return false }
        return accept(top)
    }

    // MARK: - Auto-space

    /// A space press while an auto-space stands. True when the press is to be
    /// swallowed: the word already has its space, and typing another would
    /// double it. False (and the press types normally) when the text no
    /// longer ends in that space, e.g. the cursor was moved.
    func swallowSpaceAfterAccept() -> Bool {
        guard isAutoSpacePending else { return false }
        isAutoSpacePending = false
        return target()?.documentContextBeforeInput?.last == Self.space
    }

    /// Punctuation typed right after an accepted word: takes the auto-space
    /// back, so "hello" plus "." reads "hello." and not "hello .".
    func takeBackAutoSpace() {
        guard isAutoSpacePending else { return }
        isAutoSpacePending = false
        guard let target = target(), target.documentContextBeforeInput?.last == Self.space else { return }
        target.deleteBackward()
    }

    /// Something other than a space or punctuation happened: the auto-space is
    /// an ordinary space now.
    func endAutoSpace() {
        isAutoSpacePending = false
    }

    // MARK: - VoiceOver

    /// After a pause with no keystroke, says the top completion (gesture
    /// typing under VoiceOver cannot see the row). Cancelled by the next
    /// refresh, so it never speaks over typing.
    private func scheduleAnnouncement() {
        pendingAnnouncement?.cancel()
        pendingAnnouncement = nil
        guard let top = candidates.first, canAnnounce() else { return }
        pendingAnnouncement = timers.schedule(after: Self.announcementPause) { [weak self] in
            guard let self else { return }
            pendingAnnouncement = nil
            guard self.canAnnounce(), candidates.first == top else { return }
            announce(top)
        }
    }
}
