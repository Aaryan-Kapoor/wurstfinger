//
//  KeyboardViewModel+Emoji.swift
//  Wurstfinger
//
//  The view model's side of the emoji mode: the recent key.
//

import Foundation

extension KeyboardViewModel {
    /// Called by `EmojiRecentsMiddleware` after an emoji was typed. Memory only:
    /// the key shows the new order the next time the mode is entered, so it
    /// never moves under the thumb, and the store is written when the mode is
    /// left.
    func recordEmoji(_ emoji: String) {
        emojiRecents.record(emoji)
        emojiRecentsAreUnsaved = true
    }

    /// Settings reloaded: take what the store holds, unless emoji typed since
    /// the last write are still waiting for it (the store is behind us then).
    func reloadEmojiRecents() {
        guard !emojiRecentsAreUnsaved else { return }
        let stored = EmojiRecents.load(from: sharedDefaults)
        if stored != emojiRecents { emojiRecents = stored }
    }

    /// The emoji mode is about to be entered from another mode, or left for one.
    ///
    /// Entering puts the current recents on the recent key, in the definition
    /// and in the compiled tables (the one mode that changes while the keyboard
    /// is up). Leaving writes them to the store: once per visit, not per emoji.
    func noteEmojiModeChange(from oldMode: String, to newMode: String) {
        let wasEmoji = EmojiLayouts.isEmojiMode(oldMode)
        let isEmoji = EmojiLayouts.isEmojiMode(newMode)
        if isEmoji, !wasEmoji {
            refreshRecentKey()
        } else if wasEmoji, !isEmoji {
            saveEmojiRecents()
        }
    }

    /// Rebuilds the emoji pages around `emojiRecents` when the recent key is
    /// out of date.
    private func refreshRecentKey() {
        guard let definition = currentDefinition, definition.mode(ModeNames.emoji) != nil,
              definition.mode(ModeNames.emoji)?.keys[GridSlot.recent] != EmojiLayouts.recentKey(emojiRecents)
        else { return }
        let updated = EmojiLayouts.applying(emojiRecents, to: definition)
        currentDefinition = updated
        compiledDefinition = compiledDefinition?.replacing([ModeNames.emoji, ModeNames.emojiMore], from: updated)
    }

    /// Writes the recents the mode collected. A no-op when nothing was typed.
    func saveEmojiRecents() {
        guard emojiRecentsAreUnsaved else { return }
        emojiRecentsAreUnsaved = false
        emojiRecents.save(to: sharedDefaults)
    }
}
