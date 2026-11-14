//
//  CustomLayoutRegistry.swift
//  Wurstfinger
//
//  The custom layouts the process knows about, ready for `KeyboardRegistry`.
//

import Foundation
import os

/// The set of custom layouts in memory: decoded, validated, and waiting for the
/// registry to build the ones that are enabled.
///
/// **When it changes, not per keystroke.** The set is replaced wholesale when a
/// layout is added, edited or removed (host app), or when the shared revision
/// counter says the host app did (keyboard extension, on a settings reload).
/// Lookups on the typing path are a lock acquisition and a dictionary read. What
/// it holds is the small authoring document — a few hundred bytes of text per
/// layout; the `KeyboardDefinition` is built only for a layout somebody
/// selects, through `KeyboardRegistry`'s cache, and evicted with the others.
///
/// A `Sendable` class whose only state is an `OSAllocatedUnfairLock`.
final class CustomLayoutRegistry: Sendable {
    private struct State {
        var layouts: [String: CustomLayout] = [:]
        /// The `customLayoutsRevision` this set was loaded for.
        var revision: String?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(layouts: [CustomLayout] = [], revision: String? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(
            layouts: Dictionary(layouts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            revision: revision
        ))
    }

    /// The process-wide registry. Created on first use from the shared store, so
    /// the keyboard extension sees the host app's layouts without anyone having
    /// to ask: the revision is read *before* the files, so a layout saved in
    /// between is picked up by the next `sync` instead of being missed.
    static let shared: CustomLayoutRegistry = {
        let revision = SharedDefaults.store.string(forKey: SettingsKey.customLayoutsRevision.rawValue)
        return CustomLayoutRegistry(layouts: CustomLayoutStore.shared.load().layouts, revision: revision)
    }()

    /// Lightweight metadata of the layouts, in no particular order.
    var languages: [LanguageMetadata] {
        state.withLock { state in
            state.layouts.values.map {
                LanguageMetadata(id: $0.id, title: $0.title, localeIdentifier: $0.localeIdentifier, family: .custom)
            }
        }
    }

    /// The layout with `id`, if registered.
    func layout(withId id: String) -> CustomLayout? {
        state.withLock { $0.layouts[id] }
    }

    /// Replaces the set with `layouts`, remembering the revision it belongs to.
    /// - Returns: The ids whose cached definition is stale: layouts that
    ///   changed and layouts that went away.
    @discardableResult
    func replace(with layouts: [CustomLayout], revision: String?) -> Set<String> {
        let incoming = Dictionary(layouts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return state.withLock { state in
            var stale = Set<String>()
            for (id, old) in state.layouts where incoming[id] != old { stale.insert(id) }
            state.layouts = incoming
            state.revision = revision
            return stale
        }
    }

    /// Reloads from `store` when the shared revision counter differs from the
    /// one this set was loaded for.
    ///
    /// A store without a counter (never written by the host app) is left alone,
    /// so a process that has nothing to do with custom layouts — and every unit
    /// test that constructs a view model — never touches the files.
    /// - Returns: The ids whose cached definition is stale (empty if nothing changed).
    @discardableResult
    func sync(defaults: UserDefaults, store: CustomLayoutStore) -> Set<String> {
        guard let revision = defaults.string(forKey: SettingsKey.customLayoutsRevision.rawValue),
              revision != state.withLock({ $0.revision })
        else { return [] }
        return replace(with: store.load().layouts, revision: revision)
    }
}
