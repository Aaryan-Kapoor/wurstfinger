//
//  FeelShaderStoreTests.swift
//  WurstfingerKitTests
//
//  Where the feel shaders come from (bundle, cache, compile), the persistent
//  cache's behaviour, the GPU tiers, and the source the bundle script
//  extracts. Everything on disk lives in a temporary directory.
//

import Foundation
import Metal
import Testing
@testable import WurstfingerKit

private let hasGPU = MTLCreateSystemDefaultDevice() != nil

/// A fresh temporary directory, removed by `cleanUp`.
private struct Scratch {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wurstfinger-shader-store-\(UUID().uuidString)", isDirectory: true)

    var group: URL { root.appendingPathComponent("group", isDirectory: true) }
    var own: URL { root.appendingPathComponent("own", isDirectory: true) }

    func store(bundled: URL? = nil) -> FeelShaderStore {
        FeelShaderStore(bundledLibrary: bundled, cacheDirectories: [group, own])
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Not main-actor: the compiles run off the main actor so they never starve
/// the suites that wait on it.
struct FeelShaderStoreTests {
    @Test(.enabled(if: hasGPU)) func aColdStoreCompilesOnceAndCachesEverywhere() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let store = scratch.store()
        let first = try store.load(source: FeelShaderSource.metal, system: "test-os")
        #expect(first.origin == .compiled)
        let name = FeelShaderStore.cacheFileName(source: FeelShaderSource.metal, system: "test-os")
        #expect(FileManager.default.fileExists(atPath: scratch.group.appendingPathComponent(name).path))
        #expect(FileManager.default.fileExists(atPath: scratch.own.appendingPathComponent(name).path))

        let second = try store.load(source: FeelShaderSource.metal, system: "test-os")
        #expect(second.origin == .cached)
        #expect(second.data == first.data)
    }

    @Test(.enabled(if: hasGPU)) func theKeyboardFindsWhatTheHostAppWarmed() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        // The host app writes the shared (group) cache…
        _ = try FeelShaderStore(bundledLibrary: nil, cacheDirectories: [scratch.group])
            .load(source: FeelShaderSource.metal, system: "test-os")
        // …and the keyboard, whose own cache is empty, reads it from there.
        let keyboard = try scratch.store().load(source: FeelShaderSource.metal, system: "test-os")
        #expect(keyboard.origin == .cached)
    }

    @Test(.enabled(if: hasGPU)) func aCorruptCacheIsDroppedAndRebuilt() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let name = FeelShaderStore.cacheFileName(source: FeelShaderSource.metal, system: "test-os")
        try FileManager.default.createDirectory(at: scratch.group, withIntermediateDirectories: true)
        let garbage = scratch.group.appendingPathComponent(name)
        try Data(repeating: 0x42, count: 512).write(to: garbage)
        let loaded = try scratch.store().load(source: FeelShaderSource.metal, system: "test-os")
        #expect(loaded.origin == .compiled)
        #expect(try Data(contentsOf: garbage) == loaded.data, "replaced by the good library")
    }

    @Test(.enabled(if: hasGPU)) func aBundledLibraryWinsAndABadOneIsSkipped() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        // A valid library standing in for the one Xcode would build.
        let good = try FeelShaderCompiler.compileLibraryData(source: FeelShaderSource.metal)
        try FileManager.default.createDirectory(at: scratch.root, withIntermediateDirectories: true)
        let bundled = scratch.root.appendingPathComponent("FeelShaders.metallib")
        try good.write(to: bundled)
        #expect(try scratch.store(bundled: bundled).load(source: FeelShaderSource.metal, system: "x").origin == .bundled)

        try Data("not a library".utf8).write(to: bundled)
        #expect(try scratch.store(bundled: bundled).load(source: FeelShaderSource.metal, system: "x").origin == .compiled)
    }

    @Test func theCacheNameFollowsTheSourceAndTheSystem() {
        let a = FeelShaderStore.cacheFileName(source: "x", system: "17.0")
        #expect(a == FeelShaderStore.cacheFileName(source: "x", system: "17.0"))
        #expect(a != FeelShaderStore.cacheFileName(source: "y", system: "17.0"))
        #expect(a != FeelShaderStore.cacheFileName(source: "x", system: "17.1"))
        #expect(a.hasPrefix("FeelShaders-") && a.hasSuffix(".metallib"))
    }

    @Test func theTestRunnerHasNoCacheOnDisk() {
        #expect(FeelShaderStore.standard.cacheDirectories.isEmpty)
        #expect(FeelShaderStore.standard.bundledLibrary == nil)
    }
}

struct FeelShaderTierTests {
    @Test func olderGPUsGetFewerEffects() {
        #expect(FeelShaderTier.tier(supportsApple7: true, supportsApple6: true, isLowPowerMode: false) == .full)
        #expect(FeelShaderTier.tier(supportsApple7: false, supportsApple6: true, isLowPowerMode: false) == .essential)
        #expect(FeelShaderTier.tier(supportsApple7: false, supportsApple6: false, isLowPowerMode: false) == .off)
    }

    @Test func lowPowerModeDropsOneTier() {
        #expect(FeelShaderTier.tier(supportsApple7: true, supportsApple6: true, isLowPowerMode: true) == .essential)
        #expect(FeelShaderTier.tier(supportsApple7: false, supportsApple6: true, isLowPowerMode: true) == .off)
        #expect(FeelShaderTier.tier(supportsApple7: false, supportsApple6: false, isLowPowerMode: true) == .off)
    }

    @Test(.enabled(if: hasGPU)) func thisMacRunsEverything() {
        // Apple silicon (or a desktop GPU) and, under the test runner, no Low
        // Power Mode expected.
        if !ProcessInfo.processInfo.isLowPowerModeEnabled {
            #expect(FeelShaderTier.current == .full)
        }
    }
}

struct FeelShaderSourceMarkerTests {
    @Test func theBundleScriptFindsTheSourceBetweenItsMarkers() {
        let source = FeelShaderSource.metal
        #expect(source.components(separatedBy: "wurstfinger-feel-shaders: begin").count == 2)
        #expect(source.components(separatedBy: "wurstfinger-feel-shaders: end").count == 2)
        #expect(!source.contains("\\"), "the script copies the text verbatim: no Swift escapes")
        for name in FeelShaderSource.functionNames {
            #expect(source.contains(name))
        }
    }
}
