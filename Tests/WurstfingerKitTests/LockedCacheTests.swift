//
//  LockedCacheTests.swift
//  WurstfingerTests
//
//  The cache behind `KeyboardRegistry` and `GridLayoutSolver`: one build per
//  key under concurrent hammering, no stalls for unrelated keys, and the
//  registry's background prewarm.
//

import Dispatch
import Foundation
import os
import Testing
@testable import WurstfingerKit

struct LockedCacheTests {
    /// Burns roughly `microseconds` of CPU so concurrent callers genuinely
    /// overlap inside a build — a sleep would hand the thread back and let
    /// racers serialize by accident.
    private static func burn(microseconds: UInt64) {
        let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + microseconds * 1000
        while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < end {}
    }

    @Test func concurrentHammeringBuildsEachKeyExactlyOnce() async {
        let cache = LockedCache<String, Int>()
        let builds = OSAllocatedUnfairLock(initialState: [String: Int]())
        let keys = (0 ..< 8).map { "key-\($0)" }

        let results = await withTaskGroup(of: (String, Int).self, returning: [(String, Int)].self) { group in
            for round in 0 ..< 800 {
                let key = keys[round % keys.count]
                group.addTask {
                    let value = cache.value(for: key) {
                        builds.withLock { $0[key, default: 0] += 1 }
                        Self.burn(microseconds: 500)
                        return key.utf8.reduce(0) { $0 &+ Int($1) }
                    }
                    return (key, value)
                }
            }
            var collected = [(String, Int)]()
            for await result in group { collected.append(result) }
            return collected
        }

        let counts = builds.withLock { $0 }
        #expect(counts.count == keys.count)
        #expect(counts.values.allSatisfy { $0 == 1 }, "a key was built more than once: \(counts)")
        #expect(results.count == 800)
        for (key, value) in results {
            #expect(value == key.utf8.reduce(0) { $0 &+ Int($1) })
        }
    }

    @Test func aHitIsNotBlockedByABuildOfAnotherKey() {
        let cache = LockedCache<String, Int>()
        _ = cache.value(for: "warm") { 1 }

        let building = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = cache.value(for: "slow") {
                building.signal()
                release.wait()
                return 2
            }
            finished.signal()
        }
        building.wait()

        // The slow key is mid-build on another thread: the warm key must still
        // answer, and the slow one must read as "not cached yet" instead of
        // making the reader wait for it.
        #expect(cache.value(for: "warm") { Issue.record("built a cached key"); return -1 } == 1)
        #expect(cache.cachedValue(for: "slow") == nil)
        #expect(!cache.contains("slow"))

        release.signal()
        finished.wait()
        #expect(cache.cachedValue(for: "slow") == 2)
    }

    @Test func removeAndRemoveAllDropEntries() {
        let cache = LockedCache<String, Int>()
        _ = cache.value(for: "a") { 1 }
        _ = cache.value(for: "b") { 2 }
        _ = cache.value(for: "c") { 3 }

        cache.remove("a")
        #expect(!cache.contains("a"))
        #expect(cache.contains("b"))

        cache.removeAll(except: "c")
        #expect(!cache.contains("b"))
        #expect(cache.contains("c"))

        cache.removeAll()
        #expect(!cache.contains("c"))
        // A dropped key rebuilds on the next request.
        #expect(cache.value(for: "a") { 10 } == 10)
    }
}

struct KeyboardRegistryPrewarmTests {
    @Test func prewarmBuildsEveryRequestedLanguage() async {
        let ids = ["de_DE", "en_US", "fr_FR", "ru_RU"]
        await KeyboardRegistry.prewarm(ids)
        for id in ids {
            // Presence-only assertion: other suites load these ids too, and
            // none of them evicts (see `KeyboardRegistryTests`).
            #expect(KeyboardRegistry.isCached(id: id), "\(id) was not prewarmed")
        }
    }

    @Test func prewarmIgnoresUnknownIdsAndDuplicates() async {
        await KeyboardRegistry.prewarm(["de_DE", "de_DE", "no_such_language"])
        #expect(KeyboardRegistry.isCached(id: "de_DE"))
        #expect(!KeyboardRegistry.isCached(id: "no_such_language"))
    }

    @Test func prewarmedLoadReturnsTheSameDefinitionAsAColdBuild() async throws {
        await KeyboardRegistry.prewarm(["it_IT"])
        let warm = try #require(KeyboardRegistry.load(id: "it_IT"))
        let cold = try #require(LanguageDefinitions.all.first { $0.id == "it_IT" }).makeDefinition()
        #expect(warm == cold)
    }

    @Test func aLoadRacingAPrewarmStillReturnsOneCoherentDefinition() async throws {
        // Switching to a language while the prewarm is still building it must
        // wait for / share that build rather than return a second, divergent
        // copy.
        let id = "pl_PL"
        async let prewarm: Void = KeyboardRegistry.prewarm([id])
        let racing = await Task.detached { KeyboardRegistry.load(id: id) }.value
        await prewarm
        let settled = try #require(KeyboardRegistry.load(id: id))
        #expect(racing == settled)
    }
}
