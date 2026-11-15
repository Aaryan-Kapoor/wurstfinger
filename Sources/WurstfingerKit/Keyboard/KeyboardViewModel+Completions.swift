//
//  KeyboardViewModel+Completions.swift
//  Wurstfinger
//
//  Word completions on the view model: building the engine, keeping the row's
//  height in step with the settings and the field, and the two ways to accept.
//

import Foundation

extension KeyboardViewModel {
    /// Builds the completion engine. The learned words persist only for a view
    /// model that persists settings (the keyboard itself) and never under the
    /// unit-test host; every other view model keeps them in memory, and its
    /// source is the null one unless a test or tool installs another.
    func makeCompletions() -> WordCompletions {
        let persists = shouldPersistSettings && !UnitTestHost.isActive
        let engine = WordCompletions(
            timers: timers,
            source: persists ? SystemCompletionSource() : NullCompletionSource(),
            learned: LearnedWordStore(fileURL: persists ? LearnedWordStore.defaultFileURL : nil, timers: timers),
            target: { [weak self] in self?.textInputTarget }
        )
        // Under VoiceOver gesture typing the row cannot be seen: after a pause
        // the top completion is spoken, in the same voice as the targets.
        engine.canAnnounce = { [weak self] in
            guard let self else { return false }
            return typingBehavior.isVoiceOverGestureTypingEnabled && spokenFeedback.isActive()
        }
        engine.announce = { [weak self] completion in
            self?.spokenFeedback.announce(.name(String(localized: "Suggestion: \(completion.word)")))
        }
        return engine
    }

    /// Re-reads everything the row depends on and sizes it: the setting, the
    /// field's traits and the language. Called after a settings reload, a
    /// field change and a definition load; idempotent.
    ///
    /// The row's height is `KeyboardConstants.Layout.completionRowHeight` while
    /// completions are offered and 0 otherwise, so a language without a
    /// dictionary, a sensitive field and the setting off all give the height
    /// back to the keys.
    func completionsConfigurationDidChange() {
        let behavior = typingBehavior
        completions.learned.applyClearToken(behavior.learnedWordsClearToken)
        completions.configure(
            isEnabled: behavior.areWordCompletionsEnabled,
            learnsWords: behavior.learnsWords,
            traits: fieldTraits,
            locale: pipelineLocale ?? Locale(identifier: "en_US")
        )
        let height = completions.isActive ? KeyboardConstants.Layout.completionRowHeight : 0
        if accessoryRowHeight != height { accessoryRowHeight = height }
    }

    /// Installs the dictionary behind the row (tests and the snapshot tool;
    /// the keyboard builds its own) and sizes the row for it.
    func useCompletionSource(_ source: any CompletionSource) {
        completions.source = source
        completionsConfigurationDidChange()
    }

    /// The keyboard appeared: warm the dictionary for the language on a timer
    /// (`WordCompletions.warmUp`). Called by the controller.
    func completionsKeyboardDidAppear() {
        completions.warmUp()
    }

    /// The host's text or caret changed outside a key of ours (a field switch,
    /// a caret tap): look the word up again. Called by the controller.
    func completionsHostTextDidChange() {
        completions.noteKeystroke()
    }

    /// The pipeline's piece of the feature.
    func makeCompletionMiddleware() -> CompletionMiddleware {
        CompletionMiddleware(completions: completions, acceptTop: { [weak self] in
            self?.acceptTopCompletion()
        })
    }

    /// Takes the first completion (the space bar's down-swipe).
    @discardableResult
    func acceptTopCompletion() -> Bool {
        guard let top = completions.candidates.first else { return false }
        return acceptCompletion(top)
    }

    /// Takes `completion` (a tap on the row): the rest of the word and a space.
    @discardableResult
    func acceptCompletion(_ completion: Completion) -> Bool {
        guard completions.accept(completion) else { return false }
        // A completed word can end a sentence's shift state like any typed one.
        refreshAutoCapitalization()
        return true
    }
}
