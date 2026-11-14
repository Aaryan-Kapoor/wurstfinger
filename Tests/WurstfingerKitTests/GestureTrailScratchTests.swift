//
//  GestureTrailScratchTests.swift
//  WurstfingerKitTests
//
//  The per-frame trail path built in reusable buffers must draw exactly what
//  the array-based functions draw.
//

import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import WurstfingerKit

struct GestureTrailScratchTests {
    private func samples(count: Int, seed: UInt64) -> [GestureTrailSample] {
        var state = seed
        func next() -> CGFloat {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(state >> 40) / CGFloat(1 << 24)
        }
        var point = CGPoint(x: 50, y: 50)
        var time: TimeInterval = 100
        return (0 ..< count).map { _ in
            point.x += (next() - 0.3) * 18
            point.y += (next() - 0.5) * 12
            time += 0.004 + Double(next()) * 0.012
            return GestureTrailSample(point: point, time: time)
        }
    }

    @Test(arguments: [1, 2, 3, 7, 24, 64])
    func theScratchPathEqualsTheArrayPath(count: Int) {
        let scratch = GestureTrailScratch()
        for seed in 1 ... 6 as ClosedRange<UInt64> {
            let trail = samples(count: count, seed: seed)
            let predicted = seed.isMultiple(of: 2) ? [CGPoint(x: trail.last!.point.x + 9, y: trail.last!.point.y - 3)] : []
            let plain = GestureTrailInk.shape(samples: trail, predicted: predicted, headWidth: 11)
            // The same scratch twice over: the second frame starts from
            // dirty buffers and must not carry anything over.
            _ = GestureTrailInk.shape(samples: trail[...], predicted: predicted, headWidth: 11, scratch: scratch)
            let reused = GestureTrailInk.shape(samples: trail[...], predicted: predicted, headWidth: 11, scratch: scratch)
            #expect(plain.description == reused.description, "count \(count), seed \(seed)")
        }
    }

    @Test func aSliceInTheMiddleOfTheBufferDrawsLikeItsCopy() {
        let scratch = GestureTrailScratch()
        let trail = samples(count: 40, seed: 9)
        let slice = trail[15 ..< 40]
        let copied = GestureTrailInk.shape(samples: Array(slice), predicted: [], headWidth: 9)
        let sliced = GestureTrailInk.shape(samples: slice, predicted: [], headWidth: 9, scratch: scratch)
        #expect(copied.description == sliced.description)
    }

    @Test func theVisibleRangeMatchesTheVisiblePoints() {
        var trail = GestureTrail()
        for (index, sample) in samples(count: 30, seed: 3).enumerated() {
            if index == 0 { trail.begin(at: sample.point, time: sample.time) } else {
                trail.extend(to: sample.point, time: sample.time, minimumSpacing: 0)
            }
        }
        for now in stride(from: 100.0, through: 101.5, by: 0.05) {
            let range = trail.visibleSampleRange(at: now)
            #expect(trail.samples[range].map(\.point) == trail.visiblePoints(at: now), "now \(now)")
        }
        trail.release(at: 100.4)
        let range = trail.visibleSampleRange(at: 200)
        #expect(trail.samples[range].map(\.point) == trail.visiblePoints(at: 200))
        #expect(GestureTrail().visibleSampleRange(at: 0).isEmpty)
    }
}
