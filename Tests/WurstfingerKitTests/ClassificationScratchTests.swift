//
//  ClassificationScratchTests.swift
//  WurstfingerTests
//
//  The allocation-free classification core (`ClassificationScratch`, the
//  buffer pipeline, `RingBuffer.copyOrdered`) must agree bit for bit with the
//  array entry points on every kind of path the engine can see.
//

import CoreGraphics
import Foundation
import Testing
@testable import WurstfingerKit

/// SplitMix64: a tiny deterministic generator, so a failing path reproduces
/// from its seed alone.
struct FuzzGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `range`.
    mutating func double(in range: ClosedRange<Double>) -> Double {
        Double.random(in: range, using: &self)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &self)
    }
}

/// Origin-anchored touch paths of every shape the classifier is asked about.
enum FuzzPaths {
    enum Kind: CaseIterable {
        case tap, flick, returnSwipe, circleClockwise, circleCounterclockwise
        case outlierJumps, long, degenerate
    }

    static func generate(_ kind: Kind, using rng: inout FuzzGenerator) -> [CGPoint] {
        switch kind {
        case .tap:
            return [.zero] + (0 ..< rng.int(in: 0 ... 5)).map { _ in noisy(.zero, 2.5, &rng) }
        case .flick:
            return flick(&rng)
        case .returnSwipe:
            let out = flick(&rng)
            guard let tip = out.last else { return out }
            let back = (1 ... rng.int(in: 3 ... 8)).map { i in
                noisy(
                    CGPoint(x: tip.x * (1 - Double(i) / 8), y: tip.y * (1 - Double(i) / 8)), 1.5, &rng
                )
            }
            return out + back
        case .circleClockwise:
            return circle(clockwise: true, &rng)
        case .circleCounterclockwise:
            return circle(clockwise: false, &rng)
        case .outlierJumps:
            var path = flick(&rng)
            for _ in 0 ..< rng.int(in: 1 ... 2) where path.count > 2 {
                let at = rng.int(in: 1 ... path.count - 1)
                let angle = rng.double(in: 0 ... 2 * .pi)
                let distance = rng.double(in: 60 ... 200)
                path[at] = CGPoint(x: path[at].x + cos(angle) * distance, y: path[at].y + sin(angle) * distance)
            }
            return path
        case .long:
            // More samples than the position ring holds, so the origin is
            // evicted when this is fed through a sequence.
            let count = rng.int(in: 121 ... 300)
            var point = CGPoint.zero
            let heading = rng.double(in: 0 ... 2 * .pi)
            var path = [point]
            for i in 1 ..< count {
                let wobble = rng.double(in: -0.4 ... 0.4) + (i.isMultiple(of: 40) ? .pi / 2 : 0)
                point = CGPoint(
                    x: point.x + cos(heading + wobble) * rng.double(in: 0.5 ... 4),
                    y: point.y + sin(heading + wobble) * rng.double(in: 0.5 ... 4)
                )
                path.append(point)
            }
            return path
        case .degenerate:
            switch rng.int(in: 0 ... 5) {
            case 0: return []
            case 1: return [.zero]
            case 2: return [CGPoint(x: 5, y: 5)]
            case 3: return [CGPoint(x: 7, y: -3), CGPoint(x: 7, y: -3)]
            case 4: return Array(repeating: .zero, count: rng.int(in: 2 ... 20))
            default: return [.zero, CGPoint(x: 0.05, y: 0)]
            }
        }
    }

    private static func noisy(_ point: CGPoint, _ amount: Double, _ rng: inout FuzzGenerator) -> CGPoint {
        CGPoint(x: point.x + rng.double(in: -amount ... amount), y: point.y + rng.double(in: -amount ... amount))
    }

    private static func flick(_ rng: inout FuzzGenerator) -> [CGPoint] {
        let angle = Double(rng.int(in: 0 ... 7)) * .pi / 4 + rng.double(in: -0.2 ... 0.2)
        let length = rng.double(in: 8 ... 110)
        let samples = rng.int(in: 3 ... 14)
        return [.zero] + (1 ... samples).map { i in
            let t = Double(i) / Double(samples)
            return noisy(CGPoint(x: cos(angle) * length * t, y: sin(angle) * length * t), 2, &rng)
        }
    }

    private static func circle(clockwise: Bool, _ rng: inout FuzzGenerator) -> [CGPoint] {
        let radius = rng.double(in: 14 ... 45)
        let samples = rng.int(in: 12 ... 40)
        let sweep = rng.double(in: 4.5 ... 7.2)
        let start = rng.double(in: 0 ... 2 * .pi)
        return (0 ... samples).map { i in
            let angle = start + (clockwise ? 1 : -1) * sweep * Double(i) / Double(samples)
            // Orbit through the origin: the circle's first point is touch-down.
            return noisy(
                CGPoint(x: radius * (cos(angle) - cos(start)), y: radius * (sin(angle) - sin(start))), 1, &rng
            )
        }
    }

    /// Preprocessor configurations worth covering: the defaults, the Expert
    /// extremes, windows without a pre-computed kernel, and a non-square key.
    static func configuration(_ index: Int) -> GesturePreprocessorConfiguration {
        let windows = [5, 5, 3, 7, 9, 11, 4, 13]
        let orders = [2, 2, 2, 2, 2, 2, 2, 5]
        let i = index % windows.count
        return GesturePreprocessorConfiguration(
            jitterThreshold: [3, 1, 10, 3, 2, 3, 3, 3][i],
            maxJumpDistance: [50, 20, 100, 50, 50, 35, 50, 50][i],
            smoothingWindow: windows[i],
            smoothingOrder: orders[i],
            aspectRatio: 1.0
        ).with(aspectRatio: [1, 1.06, 1.3, 0.8, 2, 1, 1.06, 1][i])
    }
}

struct ClassificationScratchTests {
    private static let pathsPerKind = 300 // 8 kinds, 2,400 paths

    private let thresholds = GestureClassificationThresholds.default
    private let keySize = CGSize(width: 60, height: 56)

    private func bits(_ value: CGFloat) -> UInt64 {
        Double(value).bitPattern
    }

    private func expectIdentical(
        _ array: GestureClassification, _ buffer: GestureClassification, _ context: @autoclosure () -> String
    ) {
        #expect(array.gesture == buffer.gesture, "gesture: \(context())")
        #expect(array.isReturn == buffer.isReturn, "isReturn: \(context())")
        #expect(bits(array.displacementInKeys.dx) == bits(buffer.displacementInKeys.dx), "dx: \(context())")
        #expect(bits(array.displacementInKeys.dy) == bits(buffer.displacementInKeys.dy), "dy: \(context())")
    }

    // MARK: - Buffer pipeline vs array entry point

    @Test func bufferPipelineMatchesArrayEntryPointOverSeededPaths() {
        var rng = FuzzGenerator(seed: 0x57_5552_5354)
        // One scratch for every path: reuse must not leak state between calls.
        let scratch = ClassificationScratch(capacity: 300)
        var checked = 0

        for kind in FuzzPaths.Kind.allCases {
            for n in 0 ..< Self.pathsPerKind {
                let path = FuzzPaths.generate(kind, using: &rng)
                let config = FuzzPaths.configuration(n)

                let fromArray = KeyGestureRecognizer.classify(
                    positions: path, config: config, thresholds: thresholds, keySize: keySize
                )
                let fromBuffer = path.withUnsafeBufferPointer {
                    KeyGestureRecognizer.classify(
                        path: $0, config: config, thresholds: thresholds, keySize: keySize, scratch: scratch
                    )
                }
                expectIdentical(fromArray, fromBuffer, "\(kind) #\(n) \(path)")
                checked += 1
            }
        }
        #expect(checked >= 2000)
    }

    @Test func classificationNeverAllocatesPastTheScratch() {
        // A path exactly as long as the scratch holds still classifies.
        let scratch = ClassificationScratch(capacity: 50)
        let path = (0 ..< scratch.pathCapacity).map { CGPoint(x: Double($0) * 5, y: 0) }
        let result = path.withUnsafeBufferPointer {
            KeyGestureRecognizer.classify(
                path: $0, config: .default, thresholds: thresholds, keySize: keySize, scratch: scratch
            )
        }
        #expect(result.gesture == .swipeRight)
    }

    @Test func scratchSlicesAreEqualAndDisjoint() {
        let scratch = ClassificationScratch(capacity: 7)
        #expect(scratch.pathCapacity == 8)
        #expect(scratch.path.count == 8 && scratch.a.count == 8 && scratch.b.count == 8)
        let starts = [scratch.path, scratch.a, scratch.b].map { $0.baseAddress! }
        #expect(starts[1] - starts[0] == 8)
        #expect(starts[2] - starts[1] == 8)
    }

    // MARK: - Sequence: buffer handleEnded vs array handleEnded

    @Test func sequenceHandleEndedWithScratchMatchesArrayVersion() {
        var rng = FuzzGenerator(seed: 0x5E_0000_0001)
        let scratch = ClassificationScratch()
        let tuning = GestureTuning.default
        var checked = 0

        for kind in FuzzPaths.Kind.allCases {
            for n in 0 ..< Self.pathsPerKind {
                // Drop the leading origin: the sequence supplies its own.
                let samples = FuzzPaths.generate(kind, using: &rng).dropFirst().map { $0 }
                let aspectRatio = [1.0, 1.06, 1.3, 2.0][n % 4]
                let size = CGSize(width: 60, height: 56)

                var viaArray = KeyGestureSequence()
                var viaScratch = KeyGestureSequence()
                for sample in samples.dropLast() {
                    let translation = CGSize(width: sample.x, height: sample.y)
                    #expect(viaArray.handleChanged(translation: translation)
                        == viaScratch.handleChanged(translation: translation))
                    // The path the engine classifies speculatively, both ways.
                    viaScratch.withOriginAnchoredPath(scratch: scratch) { anchored in
                        #expect(Array(anchored) == viaArray.path, "\(kind) #\(n)")
                    }
                }
                #expect(viaArray.maxDisplacement == viaScratch.maxDisplacement)
                #expect(viaArray.isTracking == viaScratch.isTracking)

                let last = samples.last ?? .zero
                let finalTranslation = CGSize(width: last.x, height: last.y)
                let expected = viaArray.handleEnded(
                    translation: finalTranslation, aspectRatio: aspectRatio, tuning: tuning, keySize: size
                )
                let actual = viaScratch.handleEnded(
                    translation: finalTranslation, aspectRatio: aspectRatio, tuning: tuning, keySize: size,
                    scratch: scratch
                )
                expectIdentical(expected, actual, "\(kind) #\(n)")
                #expect(!viaScratch.isTracking)
                #expect(viaScratch.isTracking == viaArray.isTracking)
                #expect(viaScratch.maxDisplacement == 0 && viaArray.maxDisplacement == 0)
                checked += 1
            }
        }
        #expect(checked >= 2000)
    }

    @Test func sequenceReusableAfterBufferHandleEnded() {
        let scratch = ClassificationScratch()
        var sequence = KeyGestureSequence()
        for x in stride(from: 10, through: 60, by: 10) {
            _ = sequence.handleChanged(translation: CGSize(width: CGFloat(x), height: 0))
        }
        let swipe = sequence.handleEnded(
            translation: CGSize(width: 70, height: 0), aspectRatio: 1, tuning: .default, scratch: scratch
        )
        #expect(swipe.gesture == .swipeRight)
        #expect(!sequence.isTracking)

        // A tap straight after: no residue of the swipe.
        let tap = sequence.handleEnded(
            translation: CGSize(width: 1, height: 1), aspectRatio: 1, tuning: .default, scratch: scratch
        )
        #expect(tap.gesture == .tap)
    }

    @Test func evictedOriginIsReanchoredIntoTheScratch() {
        let scratch = ClassificationScratch(capacity: 4)
        var sequence = KeyGestureSequence(capacity: 4)
        for x in 1 ... 9 {
            _ = sequence.handleChanged(translation: CGSize(width: CGFloat(x) * 10, height: 0))
        }
        sequence.withOriginAnchoredPath(scratch: scratch) { path in
            #expect(path.count == 5)
            #expect(path.first == .zero)
            #expect(Array(path.dropFirst()) == [60, 70, 80, 90].map { CGPoint(x: $0, y: 0) })
        }
        // Not yet evicted: no extra origin.
        var young = KeyGestureSequence(capacity: 4)
        _ = young.handleChanged(translation: CGSize(width: 10, height: 0))
        young.withOriginAnchoredPath(scratch: scratch) { path in
            #expect(Array(path) == [.zero, CGPoint(x: 10, y: 0)])
        }
        // Empty.
        KeyGestureSequence(capacity: 4).withOriginAnchoredPath(scratch: scratch) { path in
            #expect(path.isEmpty)
        }
    }

    // MARK: - RingBuffer.copyOrdered

    @Test(arguments: [1, 2, 3, 5, 8])
    func copyOrderedEqualsElementsAtEveryFillLevelAndWrapState(capacity: Int) {
        var buffer = RingBuffer<Int>(capacity: capacity)
        var destination = [Int](repeating: -1, count: capacity)
        for appended in 0 ... 3 * capacity {
            let written = destination.withUnsafeMutableBufferPointer { buffer.copyOrdered(into: $0) }
            #expect(written == buffer.count)
            #expect(Array(destination.prefix(written)) == buffer.elements, "capacity \(capacity), \(appended) appends")
            #expect(buffer.count == min(appended, capacity))
            buffer.append(appended + 1)
        }
        // After removeAll the stale slots must not show through.
        buffer.removeAll()
        buffer.append(99)
        let written = destination.withUnsafeMutableBufferPointer { buffer.copyOrdered(into: $0) }
        #expect(written == 1 && destination[0] == 99 && buffer.elements == [99])
    }
}
