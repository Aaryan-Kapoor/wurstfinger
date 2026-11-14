//
//  FeelVisualsTests.swift
//  WurstfingerKitTests
//
//  The feel layer's drawing: the runtime-compiled shaders (that the shipped
//  source compiles through the archive path, and that SwiftUI renders it),
//  the trail's ink, and the overlays' geometry.
//

import AppKit
import CoreGraphics
import Foundation
import Metal
import SwiftUI
import Testing
@testable import WurstfingerKit

// MARK: - Shaders

/// Whether this machine has a Metal device (CI runners may not).
private let hasGPU = MTLCreateSystemDefaultDevice() != nil

/// Not main-actor: a cold Metal compile can take a while, and running it on
/// the main actor would starve the suites that wait on it (the settings
/// debounce tests). Only the SwiftUI render hops to the main actor.
struct FeelShaderTests {
    @Test(.enabled(if: hasGPU)) func theShippedSourceCompilesToAnExecutableLibrary() throws {
        let data = try FeelShaderCompiler.compileLibraryData(source: FeelShaderSource.metal)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(data: data.withUnsafeBytes { DispatchData(bytes: $0) })
        #expect(library.type == .executable)
        #expect(Set(library.functionNames) == FeelShaderSource.functionNames)
        for name in FeelShaderSource.functionNames {
            #expect(library.makeFunction(name: name)?.functionType == .visible, "\(name) must be stitchable")
        }
    }

    @Test(.enabled(if: hasGPU)) func aSourceErrorThrowsInsteadOfCrashing() {
        #expect(throws: (any Error).self) {
            try FeelShaderCompiler.compileLibraryData(source: "this is not metal")
        }
    }

    @Test(.enabled(if: hasGPU)) func garbageHoldsNoLibrary() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var junk = Data(repeating: 0xAB, count: 256)
        junk.replaceSubrange(40 ..< 44, with: Data("MTLB".utf8)) // a magic with a nonsense length
        #expect(throws: FeelShaderCompiler.Failure.noLibraryInArchive) {
            try FeelShaderCompiler.extractLibrary(from: junk, containing: ["feelRipple"], device: device)
        }
        #expect(throws: FeelShaderCompiler.Failure.noLibraryInArchive) {
            try FeelShaderCompiler.extractLibrary(from: Data("MTLB".utf8), containing: [], device: device)
        }
    }

    /// The proof that matters: SwiftUI draws with the extracted library. A
    /// white sheen at full strength over black must light the touch point
    /// and leave a far corner dark.
    @Test(.enabled(if: hasGPU)) @MainActor func swiftUIRendersTheSheen() async throws {
        let data = try await Task.detached {
            try FeelShaderCompiler.compileLibraryData(source: FeelShaderSource.metal)
        }.value
        _ = NSApplication.shared
        let library = ShaderLibrary(data: data)
        let view = ZStack {
            Color.black
            Rectangle().fill(library.feelKeySheen(.boundingRect, .float2(0.25, 0.75), .float(1), .color(.white)))
        }
        .frame(width: 100, height: 100)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let lit = Self.luminance(of: image, x: 25, y: 75)
        let dark = Self.luminance(of: image, x: 95, y: 95)
        #expect(lit > 0.6, "the touch point is lit (\(lit))")
        #expect(dark < lit / 2, "light falls off away from the touch (\(dark))")
    }

    private static func luminance(of image: CGImage, x: Int, y: Int) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / (3 * 255)
    }
}

// MARK: - Trail ink

@MainActor
struct GestureTrailInkTests {
    private func samples(speed: CGFloat, count: Int = 8) -> [GestureTrailSample] {
        (0 ..< count).map { index in
            let time = Double(index) / 120
            return GestureTrailSample(point: CGPoint(x: CGFloat(time) * speed, y: 50), time: time)
        }
    }

    @Test func widthFollowsSpeedFromFullToThinnest() {
        #expect(GestureTrailInk.widthScale(forSpeed: 0) == 1)
        #expect(GestureTrailInk.widthScale(forSpeed: GestureTrailInk.slowSpeed) == 1)
        #expect(GestureTrailInk.widthScale(forSpeed: GestureTrailInk.fastSpeed) == GestureTrailInk.thinnest)
        #expect(GestureTrailInk.widthScale(forSpeed: 10_000) == GestureTrailInk.thinnest)
        let speeds = stride(from: 0.0, through: 2000, by: 100).map { GestureTrailInk.widthScale(forSpeed: CGFloat($0)) }
        #expect(speeds == speeds.sorted(by: >))
    }

    @Test func fastSamplesInkThinner() {
        let slow = GestureTrailInk.widthScales(for: samples(speed: 150))
        let fast = GestureTrailInk.widthScales(for: samples(speed: 2000))
        #expect(slow.allSatisfy { $0 == 1 })
        #expect(fast.last! < 0.7)
        #expect(fast.first == 1, "the touch-down sample has no speed yet")
    }

    @Test func coincidentTimestampsDoNotBlowUp() {
        let samples = [
            GestureTrailSample(point: .zero, time: 1),
            GestureTrailSample(point: CGPoint(x: 10, y: 0), time: 1),
        ]
        let scales = GestureTrailInk.widthScales(for: samples)
        #expect(scales.allSatisfy { $0.isFinite && $0 >= GestureTrailInk.thinnest })
    }

    @Test func resamplingMatchesTheSmoothedPath() {
        let points = samples(speed: 500).map(\.point)
        let smoothed = GestureTrailGeometry.smoothed(points, subdivisions: 6)
        let values: [CGFloat] = (0 ..< points.count).map { CGFloat($0) }
        let resampled = GestureTrailInk.resample(values, toMatch: smoothed.count, subdivisions: 6)
        #expect(resampled.count == smoothed.count)
        #expect(resampled.first == 0)
        #expect(resampled.last == CGFloat(points.count - 1))
        #expect(resampled == resampled.sorted())
    }

    @Test func aFastRibbonIsNarrowerThanASlowOne() {
        let slow = GestureTrailInk.shape(samples: samples(speed: 150, count: 30), predicted: [], headWidth: 12)
        let fast = GestureTrailInk.shape(samples: samples(speed: 2400, count: 30), predicted: [], headWidth: 12)
        #expect(fast.boundingRect.height < slow.boundingRect.height)
        #expect(slow.boundingRect.height <= 12.5)
    }

    @Test func aLoneSampleIsStillThePressDot() {
        let sample = GestureTrailSample(point: CGPoint(x: 20, y: 20), time: 0)
        let ink = GestureTrailInk.shape(samples: [sample], predicted: [], headWidth: 10)
        let dot = GestureTrailGeometry.shape(through: [sample.point], headWidth: 10)
        #expect(ink.boundingRect == dot.boundingRect)
    }

    @Test func predictedPointsExtendTheRibbon() {
        let base = samples(speed: 500)
        let last = base.last!.point
        let without = GestureTrailInk.shape(samples: base, predicted: [], headWidth: 10)
        let with = GestureTrailInk.shape(samples: base, predicted: [CGPoint(x: last.x + 30, y: last.y)], headWidth: 10)
        #expect(with.boundingRect.maxX > without.boundingRect.maxX + 20)
    }

    @Test func visibleSamplesMatchVisiblePoints() {
        var trail = GestureTrail()
        trail.begin(at: .zero, time: 0)
        for index in 1 ... 10 {
            trail.extend(to: CGPoint(x: CGFloat(index) * 10, y: 0), time: Double(index) * 0.1)
        }
        for now in [0.5, 1.0, 2.0] {
            #expect(trail.visibleSamples(at: now).map(\.point) == trail.visiblePoints(at: now))
        }
        #expect(GestureTrail().visibleSamples(at: 0).isEmpty)
    }
}

// MARK: - Geometry

@MainActor
struct FeelGeometryTests {
    @Test func theVisibleKeyDropsTheInnerHalfGaps() {
        let bounds = CGSize(width: 300, height: 240)
        let inner = FeelGeometry.visibleKeyRect(touchFrame: CGRect(x: 100, y: 60, width: 100, height: 60), in: bounds)
        let halfH = KeyboardConstants.Layout.gridHorizontalSpacing / 2
        let halfV = KeyboardConstants.Layout.gridVerticalSpacing / 2
        #expect(inner == CGRect(x: 100 + halfH, y: 60 + halfV, width: 100 - 2 * halfH, height: 60 - 2 * halfV))
        let corner = FeelGeometry.visibleKeyRect(touchFrame: CGRect(x: 0, y: 0, width: 100, height: 60), in: bounds)
        #expect(corner == CGRect(x: 0, y: 0, width: 100 - halfH, height: 60 - halfV))
    }

    @Test func mapOffsetsMatchTheGuideCardLayout() {
        for (row, cells) in TouchGuideCard.layout.enumerated() {
            for (column, gesture) in cells.enumerated() {
                #expect(FeelGeometry.mapOffset(of: gesture) == CGVector(dx: column - 1, dy: row - 1))
            }
        }
    }

    @Test func aPopRisesOnlyAsFarAsTheKeyboardAllows() {
        let free = CommitPopView.rise(progress: 1, center: CGPoint(x: 50, y: 200), cell: 20)
        #expect(free == FeelMotion.popRise * 20)
        let cramped = CommitPopView.rise(progress: 1, center: CGPoint(x: 50, y: 12), cell: 20)
        #expect(cramped == max(12 - 20 * FeelMotion.popScale / 2, 0))
        #expect(CommitPopView.rise(progress: 0, center: CGPoint(x: 50, y: 200), cell: 20) == 0)
    }

    @Test func theRingOutlineStartsAtTheTopCentre() {
        let path = KeyOutline(cornerRadius: 8).path(in: CGRect(x: 0, y: 0, width: 100, height: 60))
        var first: CGPoint?
        path.forEach { element in
            if first == nil, case let .move(to: point) = element { first = point }
        }
        #expect(first == CGPoint(x: 50, y: 0))
        #expect(path.boundingRect.insetBy(dx: -0.01, dy: -0.01).contains(CGRect(x: 0, y: 0, width: 100, height: 60)))
    }

    @Test func theLitCellGrowsFromTheKeysSide() {
        let key = CGRect(x: 100, y: 100, width: 60, height: 50)
        #expect(TouchGuideCard.anchorTowardKey(cardCenter: CGPoint(x: 130, y: 60), keyFrame: key) == .bottom)
        #expect(TouchGuideCard.anchorTowardKey(cardCenter: CGPoint(x: 220, y: 125), keyFrame: key) == .leading)
        #expect(TouchGuideCard.anchorTowardKey(cardCenter: CGPoint(x: 40, y: 125), keyFrame: key) == .trailing)
    }

    @Test func glassCatchesMoreLightThanTheClassicCap() {
        for scheme in [ColorScheme.light, .dark] {
            #expect(KeyLight.strength(for: .liquidGlass, scheme: scheme) > KeyLight.strength(for: .classic, scheme: scheme))
        }
    }
}
