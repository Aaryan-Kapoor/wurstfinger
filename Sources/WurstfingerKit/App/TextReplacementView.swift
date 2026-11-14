//
//  TextReplacementView.swift
//  wurstfinger
//
//  The list of text-replacement shortcuts: add, edit, delete, search. The
//  keyboard expands them while typing (issue #259, `TextReplacementMiddleware`).
//

import SwiftUI

struct TextReplacementView: View {
    /// The shortcuts as stored (JSON, see `TextReplacementTable`). The keyboard
    /// reads the same key; the settings change signal carries edits across.
    @AppStorage(SettingsKey.textReplacements.rawValue, store: SharedDefaults.store)
    private var storedJSON = ""

    @State private var searchText = ""
    @State private var editor: Editor?

    /// What the edit sheet is for. `Identifiable` so `.sheet(item:)` can drive it.
    private enum Editor: Identifiable {
        case new
        case existing(TextReplacementEntry)

        var id: String {
            switch self {
            case .new: "new"
            case let .existing(entry): "entry-\(entry.shortcut)"
            }
        }

        /// The entry being edited, or nil when adding.
        var entry: TextReplacementEntry? {
            if case let .existing(entry) = self { entry } else { nil }
        }
    }

    private var entries: [TextReplacementEntry] {
        TextReplacementTable.decode(storedJSON).entries
    }

    private var visibleEntries: [TextReplacementEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.shortcut.localizedCaseInsensitiveContains(query)
                || $0.phrase.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Form {
            Section {
                if entries.isEmpty {
                    emptyState
                } else {
                    ForEach(visibleEntries) { entry in
                        Button {
                            editor = .existing(entry)
                        } label: {
                            row(for: entry)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: delete)
                }
            } footer: {
                Text("iOS text replacements can't be imported into a third-party keyboard, so add the shortcuts you want here. They work without Full Access. Press Delete right after an expansion to undo it.")
            }
        }
        .searchable(text: $searchText)
        .navigationTitle("Text Replacement")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    editor = .new
                } label: {
                    Label("Add Replacement", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editor) { editor in
            TextReplacementEditor(
                original: editor.entry,
                entries: entries,
                onSave: save
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.badge.plus")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("No Replacements")
                .font(.headline)
            Text("Add a shortcut and the phrase it should turn into.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func row(for entry: TextReplacementEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: entry.shortcut)
                .font(.body.weight(.semibold))
            Text(verbatim: entry.phrase)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: - Editing

    private func delete(at offsets: IndexSet) {
        let doomed = Set(offsets.map { visibleEntries[$0].shortcut })
        write(entries.filter { !doomed.contains($0.shortcut) })
    }

    /// Saves `entry`, replacing `original` when editing. The sheet validated it.
    private func save(_ entry: TextReplacementEntry, replacing original: TextReplacementEntry?) {
        var updated = entries
        if let original, let index = updated.firstIndex(where: { $0.shortcut == original.shortcut }) {
            updated[index] = entry
        } else {
            updated.append(entry)
        }
        write(updated)
    }

    private func write(_ entries: [TextReplacementEntry]) {
        storedJSON = TextReplacementTable.encode(entries)
    }
}

/// The sheet that adds or edits one replacement.
private struct TextReplacementEditor: View {
    let original: TextReplacementEntry?
    let entries: [TextReplacementEntry]
    let onSave: (TextReplacementEntry, TextReplacementEntry?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var shortcut: String
    @State private var phrase: String

    init(
        original: TextReplacementEntry?,
        entries: [TextReplacementEntry],
        onSave: @escaping (TextReplacementEntry, TextReplacementEntry?) -> Void
    ) {
        self.original = original
        self.entries = entries
        self.onSave = onSave
        _shortcut = State(initialValue: original?.shortcut ?? "")
        _phrase = State(initialValue: original?.phrase ?? "")
    }

    /// What is wrong with the current input, or nil when it can be saved.
    /// Empty fields are not an error to show — Save is just disabled.
    private var problem: TextReplacementError? {
        do {
            try TextReplacementTable.validate(
                shortcut: shortcut, phrase: phrase, existing: entries, replacing: original?.shortcut
            )
            return nil
        } catch {
            return error
        }
    }

    private var message: LocalizedStringKey? {
        switch problem {
        case .shortcutContainsWhitespace: "A shortcut can't contain spaces."
        case .shortcutTooLong: "A shortcut can have up to 32 characters."
        case .phraseTooLong: "A phrase can have up to 1000 characters."
        case .duplicateShortcut: "This shortcut already exists."
        case .tableFull: "You can keep up to 500 replacements."
        case .emptyShortcut, .emptyPhrase, nil: nil
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Shortcut", text: $shortcut)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Phrase", text: $phrase, axis: .vertical)
                        .lineLimit(1 ... 6)
                } footer: {
                    if let message {
                        Text(message).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle(original == nil ? "New Replacement" : "Edit Replacement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(TextReplacementEntry(shortcut: shortcut, phrase: phrase), original)
                        dismiss()
                    }
                    .disabled(problem != nil)
                }
            }
        }
    }
}

#if !WURSTFINGER_NO_PREVIEWS
#Preview {
    NavigationStack {
        TextReplacementView()
    }
}
#endif
