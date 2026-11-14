//
//  KeyboardRegistry.swift
//  Wurstfinger
//
//  Registry for keyboard layouts with lazy loading and caching.
//

import Foundation

/// Registry for keyboard layouts.
/// Exposes lightweight metadata via `available` and loads full definitions on demand.
///
/// Two sources feed it: the layouts that ship with the app (`LanguageDefinitions`,
/// fixed at compile time) and the user's custom layouts (`CustomLayoutRegistry`,
/// replaced when the set changes). Both resolve through `load(id:)` into the same
/// cache, so a custom layout is built lazily, shared by concurrent callers,
/// prewarmed and evicted exactly like a shipped one.
enum KeyboardRegistry {
    /// The layouts that ship with the app (lightweight metadata only) — not the
    /// user's custom ones, see `allLanguages`.
    ///
    /// Reads descriptor metadata only — no `KeyboardDefinition` is built, so
    /// listing languages (and the extension's `primaryLanguage` lookup) stays
    /// cheap at launch.
    static let available: [LanguageMetadata] = LanguageDefinitions.all.map { LanguageMetadata(from: $0) }

    /// Precomputed index for O(1) descriptor lookup by id. Holds descriptors
    /// (metadata + lazy builders), not built definitions.
    private static let descriptorsByID: [String: LanguageDescriptor] =
        LanguageDefinitions.all.reduce(into: [:]) { dict, descriptor in
            dict[descriptor.id] = descriptor
        }

    /// Every selectable layout: the shipped ones, then the custom ones.
    /// Metadata only, like `available`. Computed on every access, because the
    /// custom set can change under it.
    static var allLanguages: [LanguageMetadata] {
        available + CustomLayoutRegistry.shared.languages
    }

    /// Metadata of any selectable layout, shipped or custom. What the keyboard
    /// controller reads to report the active locale to iOS.
    static func metadata(for id: String) -> LanguageMetadata? {
        available.first { $0.id == id }
            ?? CustomLayoutRegistry.shared.languages.first { $0.id == id }
    }

    /// Whether `id` belongs to a layout that ships with the app. A custom layout
    /// may not take such an id: the cache is keyed by it.
    static func isShippedID(_ id: String) -> Bool {
        descriptorsByID[id] != nil
    }

    /// Brings the custom layouts up to date with the host app's last write (see
    /// `CustomLayoutRegistry.sync`) and drops the cached definitions that went
    /// stale. Cheap when nothing changed: one defaults read.
    ///
    /// Called when settings reload — never on the typing path — in the keyboard
    /// extension, and by the host app after it writes.
    /// - Returns: The ids whose definition was replaced or removed.
    @discardableResult
    static func syncCustomLayouts(
        defaults: UserDefaults = SharedDefaults.store,
        store: CustomLayoutStore = .shared,
        registry: CustomLayoutRegistry? = nil
    ) -> Set<String> {
        // No revision, nothing to follow: the process-wide registry (whose first
        // use reads the store) is not even touched.
        guard defaults.string(forKey: SettingsKey.customLayoutsRevision.rawValue) != nil else { return [] }
        let stale = (registry ?? .shared).sync(defaults: defaults, store: store)
        for id in stale { cache.remove(id) }
        return stale
    }

    /// Makes `layouts` the custom set and drops the cached definitions that went
    /// stale: the host app's path after it saved or deleted one.
    /// - Returns: The ids whose definition was replaced or removed.
    @discardableResult
    static func replaceCustomLayouts(
        _ layouts: [CustomLayout],
        revision: String?,
        registry: CustomLayoutRegistry = .shared
    ) -> Set<String> {
        let stale = registry.replace(with: layouts, revision: revision)
        for id in stale { cache.remove(id) }
        return stale
    }

    /// The descriptor for `id`: a shipped layout's, or one made on the fly for a
    /// custom layout.
    private static func descriptor(for id: String) -> LanguageDescriptor? {
        if let shipped = descriptorsByID[id] { return shipped }
        guard let layout = CustomLayoutRegistry.shared.layout(withId: id) else { return nil }
        return LanguageDescriptor(
            id: layout.id, title: layout.title, localeIdentifier: layout.localeIdentifier, family: .custom
        ) { _ in
            // Only the base's settings are read; a base that no longer ships
            // simply leaves the defaults. A custom layout is never a base, so
            // this cannot recurse.
            layout.makeDefinition(basedOn: layout.basedOn.flatMap { descriptorsByID[$0] != nil ? load(id: $0) : nil })
        }
    }

    /// Cache for loaded definitions. Only languages actually loaded via
    /// `load(id:)` (or `prewarm`) are built and held here.
    ///
    /// A `LockedCache`, not a locked dictionary: the dictionary lock is held
    /// only for the lookup/insert, so a cache hit for the active language is
    /// never blocked behind a background prewarm that is building another one,
    /// and concurrent requests for the same id share one build. See
    /// `LockedCache` for the locking argument.
    private static let cache = LockedCache<String, KeyboardDefinition>()

    /// Loads the full definition for a keyboard ID, building it lazily on first
    /// use and caching the result.
    ///
    /// Synchronous on purpose: a cache hit costs two uncontended lock
    /// acquisitions (tens of nanoseconds), so the touch path can call it
    /// without ever suspending. A miss builds on the calling thread — the
    /// prewarm exists so that, in practice, a language switch never reaches
    /// that branch.
    static func load(id: String) -> KeyboardDefinition? {
        // A hit needs no descriptor, which for a custom layout would be built on
        // the fly.
        if let cached = cache.cachedValue(for: id) { return cached }
        guard let descriptor = descriptor(for: id) else {
            return nil
        }
        return cache.value(for: id) { descriptor.makeDefinition() }
    }

    /// Builds every listed language's definition concurrently, off the main
    /// thread, so that switching to any of them later is a cache hit.
    ///
    /// The view model starts this (detached, utility priority) with the
    /// *enabled* languages when it loads, because those are the only ones the
    /// globe key can reach. Each build runs as its own child of a
    /// `withDiscardingTaskGroup`: nothing is collected, a finished child leaves
    /// no residue, and the group returns when the last build lands. Children
    /// run at `.utility` rather than `.background` on purpose — `.background`
    /// threads are throttled hard on a phone, which would stretch the window in
    /// which a fast language switch finds the build still in flight, and a
    /// definition build is cheap CPU-bound work, not I/O.
    ///
    /// If a switch does race the prewarm, `load(id:)` finds the cache cell
    /// mid-build and waits on it (with priority donation to the building
    /// thread) instead of building a second copy. Unknown and duplicate ids
    /// are ignored. Never awaited from the input path.
    static func prewarm(_ ids: [String]) async {
        let unique = Set(ids).filter { descriptor(for: $0) != nil }
        await withDiscardingTaskGroup { group in
            for id in unique {
                group.addTask(priority: .utility) {
                    _ = load(id: id)
                }
            }
        }
    }

    /// Removes a cached definition (e.g. on memory warning).
    static func evict(id: String) {
        cache.remove(id)
    }

    /// Clears the entire cache. Active definitions are rebuilt lazily on next
    /// `load(id:)`.
    static func evictAll() {
        cache.removeAll()
    }

    /// Evicts every cached definition except the given id. Used on memory
    /// warnings to free inactive layouts while keeping the active one resident.
    static func evictAll(except keepID: String) {
        cache.removeAll(except: keepID)
    }

    /// Whether a definition is currently cached (for testing).
    static func isCached(id: String) -> Bool {
        cache.contains(id)
    }
}
