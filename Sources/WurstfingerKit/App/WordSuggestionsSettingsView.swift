//
//  WordSuggestionsSettingsView.swift
//  wurstfinger
//
//  The word completion row: whether it is shown, whether the keyboard learns
//  words, and the way to make it forget them.
//

import SwiftUI

struct WordSuggestionsSettingsView: View {
    @AppStorage(SettingsKey.wordCompletionsEnabled.rawValue, store: SharedDefaults.store)
    private var isEnabled = false

    @AppStorage(SettingsKey.learnsWords.rawValue, store: SharedDefaults.store)
    private var learnsWords = true

    @State private var isConfirmingClear = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $isEnabled) {
                    SettingsRow(
                        icon: "text.append", color: .blue,
                        title: "Word Suggestions",
                        subtitle: String(localized: "Complete the word you are typing")
                    )
                }
            } footer: {
                // swiftlint:disable:next line_length
                Text("Shows up to three completions above the keys. Tap one to finish the word and add a space, or swipe down on the space bar to take the first. Left out of password, URL, email and number fields.")
            }

            Section {
                Toggle(isOn: $learnsWords) {
                    SettingsRow(icon: "brain.head.profile", color: .purple, title: "Learn New Words")
                }
                .disabled(!isEnabled)

                Button(role: .destructive) {
                    isConfirmingClear = true
                } label: {
                    Text("Clear Learned Words")
                }
            } footer: {
                // swiftlint:disable:next line_length
                Text("Words the dictionary does not know, such as names, are remembered once you have typed them twice. They stay on this device, inside the keyboard, and are never learned in password or other sensitive fields.")
            }
        }
        .navigationTitle("Word Suggestions")
        .confirmationDialog("Clear all learned words?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("Clear Learned Words", role: .destructive, action: Self.clearLearnedWords)
        } message: {
            Text("The keyboard forgets every word it learned. This cannot be undone.")
        }
    }

    /// The keyboard keeps the list in its own container, out of the app's
    /// reach, so the request is a fresh token in the shared settings: the
    /// keyboard wipes its list the next time it sees a token it has not
    /// handled (`LearnedWordStore.applyClearToken`).
    static func clearLearnedWords() {
        SharedDefaults.store.set(UUID().uuidString, forKey: SettingsKey.learnedWordsClearToken.rawValue)
    }
}
