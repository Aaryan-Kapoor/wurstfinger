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

/// The feel layer's shader library, compiled once per process off the main
/// thread and published when ready. Views read `library` and draw their
/// pure-SwiftUI fallback while it is nil — before the first compile finishes,
/// or for good if this device cannot produce one.
///
/// **Why at runtime.** SwiftUI's shader effects need a compiled Metal library
/// (`ShaderLibrary`). The package is built with SwiftPM and without Xcode's
/// Metal compiler, so no `.metallib` can be produced at build time; and a
/// library compiled from source at runtime (`MTLDevice.makeLibrary(source:)`)
/// is an `MTLLibrary` object, which SwiftUI has no initializer for. See
/// `FeelShaderCompiler` for how the compiled code is turned into the bytes
/// `ShaderLibrary(data:)` accepts.
///
/// Observed, so the views waiting on it re-render once when it arrives. Key
/// views read it only while pressed, so that one-time arrival re-renders at
/// most the keys under a finger.
@MainActor
@Observable
final class FeelShaders {
    static let shared = FeelShaders()

    /// The compiled library, or nil while compiling, when unavailable, or
    /// while suppressed.
    var library: ShaderLibrary? {
        isSuppressedForSnapshots ? nil : compiled
    }

    private var compiled: ShaderLibrary?

    /// Hides the library so every effect draws its pure-SwiftUI fallback, as
    /// on a device that cannot compile the shaders. For the snapshot tool's
    /// fallback pictures; never set in the app.
    var isSuppressedForSnapshots = false

    /// Whether a compile ran and failed (no Metal device, the compiler
    /// rejected the source, the library could not be extracted).
    @ObservationIgnored private(set) var didFail = false
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Starts the one compile this process does, at utility priority. Cheap
    /// and idempotent; call it when a keyboard appears.
    func prepare() {
        guard compiled == nil, task == nil, !didFail else { return }
        task = Task.detached(priority: .utility) {
            let result = Result { try FeelShaderCompiler.compileLibraryData(source: FeelShaderSource.metal) }
            await FeelShaders.shared.finish(result)
        }
    }

    /// Compiles on the calling thread. For hosts that render one still and
    /// need the shaders in it (the snapshot tool); never call it from the app.
    func prepareSynchronously() {
        guard compiled == nil, !didFail else { return }
        finish(Result { try FeelShaderCompiler.compileLibraryData(source: FeelShaderSource.metal) })
    }

    private func finish(_ result: Result<Data, any Error>) {
        task = nil
        switch result {
        case let .success(data):
            let library = ShaderLibrary(data: data)
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
            Task.detached(priority: .utility) {
                try? await sheen.compile(as: .shapeStyle)
                try? await ripple.compile(as: .distortionEffect)
                try? await ink.compile(as: .shapeStyle)
            }
        }
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

    private static func isUsable(_ data: Data, containing names: Set<String>, device: any MTLDevice) -> Bool {
        let dispatchData = data.withUnsafeBytes { DispatchData(bytes: $0) }
        guard let library = try? device.makeLibrary(data: dispatchData),
              library.type == .executable,
              names.isSubset(of: Set(library.functionNames))
        else { return false }
        return names.allSatisfy { library.makeFunction(name: $0)?.functionType == .visible }
    }
}
