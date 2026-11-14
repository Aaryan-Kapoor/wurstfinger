//
//  KeyboardRegistry.swift
//  Wurstfinger
//
//  Registry for keyboard layouts with lazy loading and caching.
//

import Foundation

/// Registry for keyboard layouts.
/// Exposes lightweight metadata via `available` and loads full definitions on demand.
enum KeyboardRegistry {
    /// All available keyboard layouts (lightweight metadata only).
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
        guard let descriptor = descriptorsByID[id] else {
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
        let unique = Set(ids).filter { descriptorsByID[$0] != nil }
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
