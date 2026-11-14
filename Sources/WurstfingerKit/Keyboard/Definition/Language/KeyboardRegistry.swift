//
//  KeyboardRegistry.swift
//  Wurstfinger
//
//  Registry for keyboard layouts with lazy loading and caching.
//

import Foundation
import os

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
        // `evict`, not just the definition: the compiled resolution tables
        // of an edited layout would otherwise keep typing the old bindings.
        for id in stale { evict(id: id) }
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
        for id in stale { evict(id: id) }
        return stale
    }

    /// The descriptor for `id`: a shipped layout's, or one made on the fly for a
    /// custom layout.
    ///
    /// `internal` so a test can hold a descriptor across an edit.
    static func descriptor(for id: String) -> LanguageDescriptor? {
        if let shipped = descriptorsByID[id] { return shipped }
        guard let layout = CustomLayoutRegistry.shared.layout(withId: id) else { return nil }
        return LanguageDescriptor(
            id: layout.id, title: layout.title, localeIdentifier: layout.localeIdentifier, family: .custom
        ) { _ in
            // The layout is read again *here*, under the cache cell's build
            // lock, not taken from the lookup above. `replaceCustomLayouts`
            // replaces the set and only then evicts: a build that began with
            // the old layout but inserted its cell after the eviction would
            // park the stale definition in the cache for good. Read at build
            // time, a cell created after the eviction always sees the new set,
            // and a cell created before it is dropped by the eviction.
            let current = CustomLayoutRegistry.shared.layout(withId: id) ?? layout
            // Only the base's settings are read; a base that no longer ships
            // simply leaves the defaults. A custom layout is never a base, so
            // this cannot recurse.
            return current.makeDefinition(basedOn: current.basedOn.flatMap { descriptorsByID[$0] != nil ? load(id: $0) : nil })
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

    /// Cache for the gesture-resolution tables compiled from a definition
    /// (`CompiledDefinition`), keyed by `compiledSignature(languageId:numpadType:)`.
    ///
    /// Keyed by signature rather than by language id because the numeric mode
    /// differs per numpad style, and the tables embed the numeric mode (the
    /// ghost keys' fallback). Same `LockedCache` discipline as `cache`.
    private static let compiledCache = LockedCache<String, CompiledDefinition>()

    /// The key under which a language's compiled tables are cached:
    /// `"<language id>|<phone|classic>"`.
    ///
    /// The numpad type is normalised the way `applyNumpadType` reads it: `nil`
    /// and unrecognised values mean the phone layout. The id is the prefix, so
    /// eviction by language is a prefix match. Shared by the registry and the
    /// view model so the two can never disagree about a key.
    static func compiledSignature(languageId: String, numpadType: String?) -> String {
        let style = numpadType.flatMap(NumpadType.init(rawValue:)) ?? .phone
        return "\(languageId)|\(style.rawValue)"
    }

    /// The compiled tables for `definition`, built on first use and cached
    /// under `signature`.
    ///
    /// `definition` must be the one `signature` names (the registry's canonical
    /// definition for the language, with the numpad style's numeric mode
    /// applied); the signature, not the definition, is the cache key, so the
    /// hot path does not hash a whole definition. Compiling a language (four
    /// modes of about fourteen keys) took about 2 ms in a debug build, which is
    /// why `prewarm(_:)` does it off the main thread for the phone numpad. A
    /// user on the classic numpad compiles on the first switch to each language
    /// in a session instead, once; that cost is small beside the grid rebuild a
    /// language switch already pays.
    static func compiled(for definition: KeyboardDefinition, signature: String) -> CompiledDefinition {
        compiledCache.value(for: signature) { CompiledDefinition(definition) }
    }

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
    ///
    /// Each child also compiles the definition's gesture tables for the phone
    /// numpad (the registry's canonical definition), so a switch finds both the
    /// definition and its tables warm. The compile rides in the same child
    /// rather than a second pass: it needs the definition the child just built.
    static func prewarm(_ ids: [String]) async {
        let unique = Set(ids).filter { descriptor(for: $0) != nil }
        await withDiscardingTaskGroup { group in
            for id in unique {
                group.addTask(priority: .utility) {
                    let generation = evictions.withLock { $0 }
                    guard let definition = load(id: id) else { return }
                    let signature = compiledSignature(languageId: id, numpadType: nil)
                    _ = compiled(for: definition, signature: signature)
                    // An edit evicted this layout while the tables were being
                    // compiled from its old definition: the insert above landed
                    // after the eviction and would outlive it. Drop it again;
                    // the next switch compiles from the new definition.
                    if evictions.withLock({ $0 }) != generation { compiledCache.remove(signature) }
                }
            }
        }
    }

    /// How many times `evict(id:)` has run, so a background compile can tell
    /// that an eviction overtook it (see `prewarm`).
    private static let evictions = OSAllocatedUnfairLock(initialState: 0)

    /// Removes a cached definition (e.g. on memory warning).
    static func evict(id: String) {
        evictions.withLock { $0 &+= 1 }
        cache.remove(id)
        compiledCache.removeAll { $0.hasPrefix(signaturePrefix(of: id)) }
    }

    /// Clears the entire cache. Active definitions are rebuilt lazily on next
    /// `load(id:)`.
    static func evictAll() {
        cache.removeAll()
        compiledCache.removeAll()
    }

    /// Evicts every cached definition except the given id. Used on memory
    /// warnings to free inactive layouts while keeping the active one resident.
    static func evictAll(except keepID: String) {
        cache.removeAll(except: keepID)
        compiledCache.removeAll { !$0.hasPrefix(signaturePrefix(of: keepID)) }
    }

    /// The prefix every compiled signature of language `id` starts with. The
    /// separator is part of it so "de" never matches "de_DE|phone".
    private static func signaturePrefix(of id: String) -> String {
        "\(id)|"
    }

    /// Whether a definition is currently cached (for testing).
    static func isCached(id: String) -> Bool {
        cache.contains(id)
    }

    /// Whether compiled tables are currently cached under `signature` (for testing).
    static func isCompiledCached(signature: String) -> Bool {
        compiledCache.contains(signature)
    }
}
