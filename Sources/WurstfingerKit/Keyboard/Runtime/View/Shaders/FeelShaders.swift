//
//  FeelShaders.swift
//  Wurstfinger
//
//  Compiles the feel shaders at runtime and hands SwiftUI a ShaderLibrary.
//

import Foundation
import Metal
import Observation
import SwiftUI

/// The feel layer's shader library, loaded once per process off the main
/// thread and published when ready. Views read `library` and draw their
/// pure-SwiftUI fallback while it is nil — before the load finishes, on a GPU
/// the tier keeps them off, or for good if this device cannot produce one.
///
/// **Where the library comes from, cheapest first** (`FeelShaderStore`):
/// 1. `FeelShaders.metallib` in the bundle, compiled by Xcode's Metal
///    toolchain in `scripts/bundle-ios.sh` when it is available — every
///    iPhone, no compile time at all;
/// 2. a library a previous run compiled, from the persistent cache — the app
///    group's (the host app warms it at first launch, so a keyboard with Full
///    Access never compiles) or this process's own Caches directory;
/// 3. compiled from source at runtime (`FeelShaderCompiler`) and written to
///    both caches for next time.
/// Each is validated by Metal before use; a bad file falls through to the
/// next source.
///
/// **Tiers** (`FeelShaderTier`): older GPUs and Low Power Mode get fewer
/// effects, the oldest supported iPhones none.
///
/// Observed, so the views waiting on it re-render once when it arrives. Key
/// views read it only while pressed, so that one-time arrival re-renders at
/// most the keys under a finger.
@MainActor
@Observable
final class FeelShaders {
    static let shared = FeelShaders()

    /// The compiled library, or nil while loading, when unavailable, below
    /// the `essential` tier, or while suppressed.
    var library: ShaderLibrary? {
        isSuppressedForSnapshots || tier == .off ? nil : compiled
    }

    /// Whether the glass ripple (the one effect that needs an offscreen pass)
    /// may run.
    var allowsRipple: Bool { tier == .full }

    /// What this device may run, decided when the keyboard appears.
    private(set) var tier = FeelShaderTier.full

    private var compiled: ShaderLibrary?

    /// Where the library came from, for diagnostics and tests.
    @ObservationIgnored private(set) var origin: FeelShaderStore.Origin?

    /// Hides the library so every effect draws its pure-SwiftUI fallback, as
    /// on a device that cannot compile the shaders. For the snapshot tool's
    /// fallback pictures; never set in the app.
    var isSuppressedForSnapshots = false

    /// Whether a load ran and failed (no Metal device, the compiler rejected
    /// the source, the library could not be extracted).
    @ObservationIgnored private(set) var didFail = false
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Where to look for and keep compiled libraries.
    @ObservationIgnored var store = FeelShaderStore.standard

    /// Re-reads the tier (Low Power Mode may have changed) and starts the one
    /// load this process does, at utility priority. Cheap and idempotent; the
    /// keyboard calls it when it appears, the host app at launch.
    func prepare() {
        let newTier = FeelShaderTier.current
        if tier != newTier { tier = newTier }
        guard newTier != .off, compiled == nil, task == nil, !didFail else { return }
        let store = store
        task = Task.detached(priority: .utility) {
            let result = Result { try store.load(source: FeelShaderSource.metal) }
            await FeelShaders.shared.finish(result)
        }
    }

    /// Loads on the calling thread. For hosts that render one still and need
    /// the shaders in it (the snapshot tool); never call it from the app.
    func prepareSynchronously() {
        guard compiled == nil, !didFail else { return }
        finish(Result { try store.load(source: FeelShaderSource.metal) })
    }

    private func finish(_ result: Result<FeelShaderStore.Loaded, any Error>) {
        task = nil
        switch result {
        case let .success(loaded):
            let library = ShaderLibrary(data: loaded.data)
            origin = loaded.origin
            compiled = library
            precompile(library)
        case .failure:
            didFail = true
        }
    }

    /// Builds SwiftUI's pipelines for the effects ahead of the first press,
    /// where the OS offers it, so that press does not pay for it.
    private func precompile(_ library: ShaderLibrary) {
        if #available(iOS 18.0, macOS 15.0, *) {
            let sheen = library.feelKeySheen(.boundingRect, .float2(0.5, 0.5), .float(0), .color(.white))
            let ripple = library.feelRipple(.float2(0, 0), .float(0), .float(1), .float(0))
            let ink = library.feelTrailInk(.float2(0, 0), .float(1), .color(.white), .float(1), .float(0))
            let compilesRipple = allowsRipple
            Task.detached(priority: .utility) {
                try? await sheen.compile(as: .shapeStyle)
                if compilesRipple { try? await ripple.compile(as: .distortionEffect) }
                try? await ink.compile(as: .shapeStyle)
            }
        }
    }
}

/// How much shading a device gets.
///
/// iOS 17 runs on A12 (GPU family Apple5) and later. The ripple is the one
/// effect with a real cost — a distortion renders the key into an offscreen
/// layer for its half-second — so it is kept for A14 and later (Apple7, the
/// iPhone 12 generation on). The sheen and the trail ink are a few ALU
/// operations on a handful of pixels: A13 (Apple6) keeps them. A12 gets the
/// gradient fallbacks, which look nearly the same and compile nothing. Low
/// Power Mode drops one tier: the user asked the phone to do less.
enum FeelShaderTier: Int, Comparable, Sendable {
    /// No shaders: gradients only.
    case off
    /// The sheen and the trail ink, no ripple.
    case essential
    /// Everything.
    case full

    static func < (lhs: FeelShaderTier, rhs: FeelShaderTier) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The tier for a GPU (`supportsApple7` / `supportsApple6`: its Metal GPU
    /// family; a Mac GPU counts as Apple7) and the power state.
    static func tier(supportsApple7: Bool, supportsApple6: Bool, isLowPowerMode: Bool) -> FeelShaderTier {
        let device: FeelShaderTier = supportsApple7 ? .full : (supportsApple6 ? .essential : .off)
        guard isLowPowerMode else { return device }
        return FeelShaderTier(rawValue: max(device.rawValue - 1, 0)) ?? .off
    }

    /// This device, now.
    static var current: FeelShaderTier {
        guard let device = MTLCreateSystemDefaultDevice() else { return .off }
        #if os(macOS)
        let apple7 = device.supportsFamily(.apple7) || device.supportsFamily(.mac2)
        #else
        let apple7 = device.supportsFamily(.apple7)
        #endif
        return tier(
            supportsApple7: apple7,
            supportsApple6: device.supportsFamily(.apple6),
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }
}

/// Finds a usable feel shader library: bundled, cached or compiled.
///
/// A value of where to look, so tests can point it at a temporary directory
/// and a fake bundle; `standard` is the app's.
struct FeelShaderStore: Sendable {
    enum Origin: Equatable, Sendable {
        /// `FeelShaders.metallib`, built by Xcode's Metal toolchain.
        case bundled
        /// A previous run's runtime compile, from one of the caches.
        case cached
        /// Compiled from source in this run.
        case compiled
    }

    struct Loaded: Sendable {
        var data: Data
        var origin: Origin
    }

    /// The precompiled library, if the build put one in the bundle.
    var bundledLibrary: URL?
    /// Cache directories, searched in order and all written after a compile:
    /// the app group's first (shared with the host app), then this process's.
    var cacheDirectories: [URL]

    static let resourceName = "FeelShaders"

    /// The app's: the main bundle's library, the app group's caches and this
    /// process's own. Nothing at all in the unit-test runner, which must not
    /// read or write outside the temporary directories its tests make.
    static var standard: FeelShaderStore {
        guard !UnitTestHost.isActive else { return FeelShaderStore(bundledLibrary: nil, cacheDirectories: []) }
        var directories: [URL] = []
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedDefaults.suiteName) {
            directories.append(group.appendingPathComponent("Library/Caches/FeelShaders", isDirectory: true))
        }
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            directories.append(caches.appendingPathComponent("FeelShaders", isDirectory: true))
        }
        return FeelShaderStore(
            bundledLibrary: Bundle.main.url(forResource: resourceName, withExtension: "metallib"),
            cacheDirectories: directories
        )
    }

    /// The cache file for `source` on this OS: runtime-compiled AIR is tied
    /// to the Metal version that produced it, so an OS update starts over.
    static func cacheFileName(source: String, system: String) -> String {
        // FNV-1a, 64 bit: a stable name, not a security boundary.
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in (source + "|" + system).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return "FeelShaders-\(String(hash, radix: 16)).metallib"
    }

    static var systemVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    /// The first usable library, compiling (and caching) only when neither
    /// the bundle nor a cache has one.
    func load(source: String, system: String = FeelShaderStore.systemVersion) throws -> Loaded {
        guard let device = MTLCreateSystemDefaultDevice() else { throw FeelShaderCompiler.Failure.noDevice }
        let names = FeelShaderSource.functionNames
        if let bundledLibrary, let data = try? Data(contentsOf: bundledLibrary),
           FeelShaderCompiler.isUsable(data, containing: names, device: device) {
            return Loaded(data: data, origin: .bundled)
        }
        let fileName = Self.cacheFileName(source: source, system: system)
        for directory in cacheDirectories {
            let url = directory.appendingPathComponent(fileName)
            if let data = try? Data(contentsOf: url) {
                if FeelShaderCompiler.isUsable(data, containing: names, device: device) {
                    return Loaded(data: data, origin: .cached)
                }
                // Corrupt or from another OS build: drop it, compile anew.
                try? FileManager.default.removeItem(at: url)
            }
        }
        let data = try FeelShaderCompiler.compileLibraryData(source: source)
        for directory in cacheDirectories {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
            } catch {
                // A read-only container (a keyboard without Full Access
                // cannot write the app group's): the next directory will do.
                continue
            }
        }
        return Loaded(data: data, origin: .compiled)
    }
}

/// Turns Metal source into the bytes of an executable Metal library.
///
/// The documented building blocks: compile the source (`makeLibrary(source:)`),
/// add each `[[stitchable]]` (visible) function to a binary archive compiled
/// to binary (`MTLFunctionOptions.compileToBinary`), and serialize the archive.
/// The serialized archive embeds, next to the GPU binaries, the functions' AIR
/// as an ordinary executable metallib container (magic `MTLB`, its byte length
/// at offset 16). That container is located and *validated by Metal itself*
/// before anyone uses it: it must load with `makeLibrary(data:)`, be an
/// executable library, and contain every expected function as a visible
/// function — exactly what a `.metallib` built by Xcode for SwiftUI contains.
/// Nothing is patched. If any step fails the caller gets an error and the
/// views keep their fallbacks; the archive layout is the one undocumented
/// step, which is why it is checked rather than trusted.
///
/// Proven on this repo's development Mac (M3 Pro, macOS 15): SwiftUI renders
/// `colorEffect`, `distortionEffect` and shape-style shaders from the result
/// through `ImageRenderer`, and the tests compile the shipped source through
/// the same path. On iOS it needs a GPU that supports binary archives of
/// visible functions; elsewhere it throws and the fallbacks draw.
enum FeelShaderCompiler {
    enum Failure: Error, Equatable {
        case noDevice
        case noLibraryInArchive
        case missingFunctions(Set<String>)
    }

    static func compileLibraryData(source: String) throws -> Data {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure.noDevice }
        // Default options: fast math is already the default, and nothing here
        // needs a newer language version than the OS's default.
        let options = MTLCompileOptions()
        let library = try device.makeLibrary(source: source, options: options)
        let names = Set(library.functionNames)

        let archive = try device.makeBinaryArchive(descriptor: MTLBinaryArchiveDescriptor())
        for name in names.sorted() {
            let descriptor = MTLFunctionDescriptor()
            descriptor.name = name
            descriptor.options = .compileToBinary
            try archive.addFunction(descriptor: descriptor, library: library)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wurstfinger-feel-\(UUID().uuidString).metalar")
        defer { try? FileManager.default.removeItem(at: url) }
        try archive.serialize(to: url)
        let blob = try Data(contentsOf: url)
        return try extractLibrary(from: blob, containing: names, device: device)
    }

    /// The first embedded metallib in `blob` that Metal loads as an
    /// executable library holding every function in `names` as a visible
    /// function.
    static func extractLibrary(from blob: Data, containing names: Set<String>, device: any MTLDevice) throws -> Data {
        let magic = Data("MTLB".utf8)
        var searchStart = blob.startIndex
        while let range = blob.range(of: magic, in: searchStart ..< blob.endIndex) {
            searchStart = range.upperBound
            let start = range.lowerBound
            guard start + 24 <= blob.endIndex else { break }
            let length = UInt64(littleEndian: blob[(start + 16) ..< (start + 24)].withUnsafeBytes {
                $0.loadUnaligned(as: UInt64.self)
            })
            // A magic inside other data can be followed by any length: check
            // it against what is left before converting, never trap on it.
            guard length > 24, length <= UInt64(blob.endIndex - start) else { continue }
            let size = Int(length)
            let candidate = Data(blob[start ..< start + size])
            if isUsable(candidate, containing: names, device: device) { return candidate }
        }
        throw Failure.noLibraryInArchive
    }

    static func isUsable(_ data: Data, containing names: Set<String>, device: any MTLDevice) -> Bool {
        let dispatchData = data.withUnsafeBytes { DispatchData(bytes: $0) }
        guard let library = try? device.makeLibrary(data: dispatchData),
              library.type == .executable,
              names.isSubset(of: Set(library.functionNames))
        else { return false }
        return names.allSatisfy { library.makeFunction(name: $0)?.functionType == .visible }
    }
}
