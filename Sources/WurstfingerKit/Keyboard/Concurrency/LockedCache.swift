//
//  LockedCache.swift
//  Wurstfinger
//
//  The one memo table behind every process-wide cache (keyboard definitions,
//  solved grid layouts).
//

import os

/// A thread-safe, build-once memo table that stays cheap on the touch path.
///
/// **Why not one lock around everything.** The registry used to guard its
/// dictionary with an `NSLock` held *while building*. A definition build costs
/// milliseconds, so a prewarm building language B would have stalled a cache
/// hit for the active language A on the main thread. Here the dictionary lock
/// covers only the dictionary get/insert (tens of nanoseconds); the build runs
/// under a *per-key* cell lock, so nothing but a second request for the *same*
/// key ever waits on a build.
///
/// **Why a per-key lock rather than "build, then insert if absent".** It is
/// what makes concurrent callers observe exactly one build per key: the first
/// takes the cell lock and builds, the rest queue behind it and then read the
/// finished value. `OSAllocatedUnfairLock` donates the waiter's priority to the
/// lock owner, so a main-thread request that lands on a key a *background*
/// prewarm is still building boosts that build instead of inverting behind it.
/// That wait is bounded by one definition build (measured in
/// `docs/performance.md`), and it can only happen when a language switch races
/// the prewarm for the very language being switched to.
///
/// **Sendability.** The value type must be `Sendable` (the cached definitions
/// are plain value types), the build closure is `@Sendable`, and all mutable
/// state lives inside `OSAllocatedUnfairLock`s, so the class is a genuine
/// `Sendable` with no `@unchecked`.
final class LockedCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    /// One key's slot: empty until the first build completes.
    ///
    /// Two locks, so a reader never mistakes "someone else is reading" for
    /// "still building": `slot` is held only to copy the value in or out, and
    /// `build` is held for the whole build, by the one caller doing it.
    private final class Cell: Sendable {
        let slot = OSAllocatedUnfairLock<Value?>(initialState: nil)
        let build = OSAllocatedUnfairLock()
    }

    private let cells = OSAllocatedUnfairLock<[Key: Cell]>(initialState: [:])

    init() {}

    /// The cached value for `key`, building it with `build` on first use.
    /// A cache hit is two short uncontended lock acquisitions and no
    /// allocation; it never waits on a build of another key.
    func value(for key: Key, build: @Sendable () -> Value) -> Value {
        let cell = cells.withLock { cells -> Cell in
            if let existing = cells[key] { return existing }
            let created = Cell()
            cells[key] = created
            return created
        }
        if let built = cell.slot.withLock({ $0 }) { return built }
        // The dictionary lock is already released: only callers wanting this
        // same key serialize here, and only while it is being built. The slot
        // is re-checked under the build lock, so the callers that queued
        // behind the first one read its value instead of building again.
        return cell.build.withLock {
            if let built = cell.slot.withLock({ $0 }) { return built }
            let built = build()
            cell.slot.withLock { $0 = built }
            return built
        }
    }

    /// The value for `key` if it has been built, without building it.
    func cachedValue(for key: Key) -> Value? {
        let cell = cells.withLock { $0[key] }
        // A cell that exists but is still empty is mid-build; the slot lock is
        // never held across a build, so this reports it as absent at once.
        return cell?.slot.withLock { $0 }
    }

    /// Whether `key` has a finished value.
    func contains(_ key: Key) -> Bool {
        cachedValue(for: key) != nil
    }

    /// Drops `key`. A build already running for it completes and returns its
    /// value to its caller, but the result is not retained.
    func remove(_ key: Key) {
        cells.withLock { _ = $0.removeValue(forKey: key) }
    }

    /// Drops every entry.
    func removeAll() {
        cells.withLock { $0.removeAll() }
    }

    /// Drops every entry whose key is not `keep`.
    func removeAll(except keep: Key) {
        cells.withLock { cells in
            cells = cells.filter { $0.key == keep }
        }
    }
}
