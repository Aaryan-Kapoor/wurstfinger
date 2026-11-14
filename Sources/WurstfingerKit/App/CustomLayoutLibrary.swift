//
//  CustomLayoutLibrary.swift
//  Wurstfinger
//
//  The host app's handle on the user's custom layouts: list, edit, import,
//  export, and tell the keyboard.
//

import Foundation
import Observation

/// The user's custom layouts, as the host app edits them.
///
/// Every change goes through the same three steps — validate and write the
/// layout's file, publish the new set to this process's `KeyboardRegistry`
/// (which drops the stale cached definitions), and rewrite the shared
/// revision counter so the keyboard extension re-reads the files on its next
/// settings reload — so the app's keyboard preview, the Languages list and the
/// extension can never disagree about what exists.
///
/// `@MainActor @Observable` like the other settings objects: the screens read
/// `layouts` and are invalidated only when it changes.
@MainActor
@Observable
final class CustomLayoutLibrary {
    static let shared = CustomLayoutLibrary()

    /// The stored layouts, sorted by title.
    private(set) var layouts: [CustomLayout]

    /// How many files in the store were refused when last read (corrupt, too
    /// large, from a newer app). They stay on disk; the list screen mentions them.
    private(set) var unreadableCount: Int

    @ObservationIgnored private let store: CustomLayoutStore
    @ObservationIgnored private let defaults: UserDefaults
    /// Told after every change, so the language settings drop an id that no
    /// longer exists. The shared instance by default; tests pass their own.
    @ObservationIgnored private let didChange: @MainActor () -> Void

    init(
        store: CustomLayoutStore = .shared,
        defaults: UserDefaults? = nil,
        didChange: (@MainActor () -> Void)? = nil
    ) {
        self.store = store
        self.defaults = defaults ?? SharedDefaults.store
        self.didChange = didChange ?? { LanguageSettings.shared.reloadFromStore() }
        let contents = store.load()
        layouts = contents.layouts
        unreadableCount = contents.rejected.count
    }

    /// Re-reads the store and publishes what it holds, the way a change does.
    func reload() {
        publish()
    }

    /// The layout with `id`.
    func layout(withId id: String) -> CustomLayout? {
        layouts.first { $0.id == id }
    }

    /// Everything selectable — shipped and custom — in display order. Reading
    /// it from a view subscribes the view to changes of the custom set.
    var allLanguages: [LanguageMetadata] {
        _ = layouts
        return LanguageMetadata.allLanguages
    }

    // MARK: - Changes

    /// Saves `layout` (a new one, or an edit of an existing one).
    func save(_ layout: CustomLayout) throws {
        try store.save(layout)
        publish()
    }

    /// Removes the layout with `id`.
    func delete(id: String) throws {
        try store.delete(id: id)
        publish()
    }

    /// Starts a new layout as a copy of an existing one — shipped or custom —
    /// stores it, and returns it for editing.
    @discardableResult
    func duplicate(languageId: String, title: String) throws -> CustomLayout {
        let copy: CustomLayout
        if let custom = layout(withId: languageId) {
            var layout = custom
            layout.id = CustomLayout.makeID()
            layout.title = title
            copy = layout
        } else if let definition = KeyboardRegistry.load(id: languageId) {
            copy = CustomLayout(duplicating: definition, id: CustomLayout.makeID(), title: title)
        } else {
            throw CustomLayoutError.notALayout
        }
        try store.add(copy)
        publish()
        return copy
    }

    /// Adds the layout in `data` (a file the user picked or text they pasted).
    /// - Throws: the reason it was refused, including a duplicate id.
    @discardableResult
    func importDocument(_ data: Data) throws -> CustomLayout {
        let layout = try CustomLayoutCodec.decode(data)
        try store.add(layout)
        publish()
        return layout
    }

    /// The JSON to export for `layout`.
    func exportData(for layout: CustomLayout) throws -> Data {
        do {
            return try CustomLayoutCodec.encode(layout)
        } catch {
            throw CustomLayoutError.storageFailure
        }
    }

    // MARK: - Publishing

    private func publish() {
        let contents = store.load()
        layouts = contents.layouts
        unreadableCount = contents.rejected.count
        let revision = UUID().uuidString
        KeyboardRegistry.replaceCustomLayouts(contents.layouts, revision: revision)
        // After the registry, so the language settings already know the new set.
        // The revision last: it is the signal the extension reloads on.
        defaults.set(revision, forKey: SettingsKey.customLayoutsRevision.rawValue)
        didChange()
    }
}
