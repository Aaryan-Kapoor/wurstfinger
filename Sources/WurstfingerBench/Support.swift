//
//  Support.swift
//  WurstfingerBench
//
//  Timing, statistics, allocation counting and the deterministic gesture corpus.
//

#if os(macOS)
import CoreGraphics
import Dispatch
import Foundation
import os
import SwiftUI
import WurstfingerBenchAllocCounter
@testable import WurstfingerKit

// MARK: - Statistics

struct Stats {
    let name: String
    let samples: [UInt64]

    var p50: UInt64 { percentile(0.50) }
    var p99: UInt64 { percentile(0.99) }
    var max: UInt64 { samples.max() ?? 0 }

    private func percentile(_ fraction: Double) -> UInt64 {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        return sorted[Swift.min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
    }

    func report() {
        let line = name.padding(toLength: 54, withPad: " ", startingAt: 0)
        print("\(line) n=\(String(samples.count).padding(toLength: 6, withPad: " ", startingAt: 0))"
            + " p50=\(String(p50).leftPad(10)) p99=\(String(p99).leftPad(10)) max=\(String(max).leftPad(11)) ns")
    }
}

extension String {
    func leftPad(_ width: Int) -> String {
        String(repeating: " ", count: Swift.max(0, width - count)) + self
    }
}

@inline(__always) func nanos() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

/// Keeps the optimizer from deleting the measured work: each body returns a
/// value derived from its result, `measure` folds them into a local, and the
/// total lands here once at the end, outside any timed region.
let sink = OSAllocatedUnfairLock(initialState: 0)

/// Times `body` once per input and returns the per-call nanoseconds.
func measure<Input>(_ name: String, inputs: [Input], warmup: Int = 200, _ body: (Input) -> Int) -> Stats {
    var accumulator = 0
    for input in inputs.prefix(warmup) { accumulator &+= body(input) }
    var samples = [UInt64]()
    samples.reserveCapacity(inputs.count)
    for input in inputs {
        let start = nanos()
        accumulator &+= body(input)
        samples.append(nanos() &- start)
    }
    let total = accumulator
    sink.withLock { $0 &+= total }
    return Stats(name: name, samples: samples)
}

// MARK: - Allocation counting

/// Accumulates the allocations that happen between `start()` and `stop()`
/// pairs, so a measurement can exclude its own setup (a finger landing, a
/// finger lifting) while still summing many short regions.
///
/// The hook counts the whole process, not one thread: run it on the main actor
/// with nothing else in flight (no prewarm, no timers firing), or the numbers
/// include someone else's allocations.
@MainActor
struct AllocationMeter {
    private(set) var allocations: UInt64 = 0
    private(set) var bytes: UInt64 = 0
    private var startCount: UInt64 = 0
    private var startBytes: UInt64 = 0

    init() { bench_alloc_counter_install() }

    mutating func start() {
        startCount = bench_alloc_count()
        startBytes = bench_alloc_bytes()
    }

    mutating func stop() {
        allocations &+= bench_alloc_count() &- startCount
        bytes &+= bench_alloc_bytes() &- startBytes
    }
}

/// Heap allocations (events and requested bytes) per call of `body`: installs
/// the counter, runs `warmup` calls so lazy statics and caches are not
/// charged, then counts `iterations` calls and divides.
///
/// The body is main-actor isolated on purpose; see `AllocationMeter`.
@MainActor
func countAllocations(
    iterations: Int, warmup: Int = 50, _ body: @MainActor () -> Void
) -> (perIteration: Double, bytesPerIteration: Double) {
    var meter = AllocationMeter()
    for _ in 0 ..< warmup { body() }
    meter.start()
    for _ in 0 ..< iterations { body() }
    meter.stop()
    let count = Double(Swift.max(iterations, 1))
    return (Double(meter.allocations) / count, Double(meter.bytes) / count)
}

/// Prints one allocation row: allocations and requested bytes per iteration.
func reportAllocations(_ name: String, _ result: (perIteration: Double, bytesPerIteration: Double)) {
    reportAllocations(name, allocations: result.perIteration, bytes: result.bytesPerIteration)
}

func reportAllocations(_ name: String, allocations: Double, bytes: Double) {
    let line = name.padding(toLength: 62, withPad: " ", startingAt: 0)
    print("\(line) \(format(allocations, 1).leftPad(9)) allocs/iter \(format(bytes, 0).leftPad(10)) bytes/iter")
}

/// Fixed-point formatting without `String(format:)`'s varargs.
func format(_ value: Double, _ decimals: Int) -> String {
    String(format: "%.\(decimals)f", value)
}

/// Prints one aligned measurement line with a number and a unit.
func reportValue(_ name: String, _ value: Double, unit: String, decimals: Int = 0) {
    let line = name.padding(toLength: 62, withPad: " ", startingAt: 0)
    print("\(line) \(format(value, decimals).leftPad(12)) \(unit)")
}

// MARK: - Corpus

/// Deterministic generator (SplitMix64) so every run classifies the same gestures.
struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ lower: Double, _ upper: Double) -> Double { lower + (upper - lower) * unit() }
}

struct SyntheticGesture {
    let positions: [CGPoint]
}

func makeCorpus(count: Int) -> [SyntheticGesture] {
    var rng = SplitMix64(state: 0x57_75_72_73_74)
    var corpus = [SyntheticGesture]()
    corpus.reserveCapacity(count)

    func jitter(_ rng: inout SplitMix64, _ amount: Double) -> CGPoint {
        CGPoint(x: rng.range(-amount, amount), y: rng.range(-amount, amount))
    }

    for index in 0 ..< count {
        var points: [CGPoint] = [.zero]
        switch index % 4 {
        case 0: // tap: a handful of samples that barely move
            for _ in 0 ..< Int(rng.range(2, 6)) {
                let j = jitter(&rng, 2.0)
                points.append(j)
            }
        case 1: // eight-way flick
            let angle = Double(Int(rng.range(0, 8))) * .pi / 4
            let length = rng.range(28, 70)
            let steps = Int(rng.range(6, 18))
            for step in 1 ... steps {
                let t = Double(step) / Double(steps)
                let j = jitter(&rng, 1.5)
                points.append(CGPoint(x: cos(angle) * length * t + j.x, y: sin(angle) * length * t + j.y))
            }
        case 2: // return swipe: out and back to near the origin
            let angle = Double(Int(rng.range(0, 8))) * .pi / 4
            let length = rng.range(30, 60)
            let steps = Int(rng.range(8, 14))
            for step in 1 ... steps {
                let t = Double(step) / Double(steps)
                let along = t < 0.5 ? t * 2 : (1 - t) * 2 * 0.9
                let j = jitter(&rng, 1.5)
                points.append(CGPoint(x: cos(angle) * length * along + j.x, y: sin(angle) * length * along + j.y))
            }
        default: // circle, either direction
            let radius = rng.range(18, 34)
            let direction: Double = rng.unit() < 0.5 ? 1 : -1
            let steps = Int(rng.range(24, 44))
            let start = rng.range(0, 2 * .pi)
            for step in 1 ... steps {
                let theta = start + direction * 2 * .pi * 1.05 * Double(step) / Double(steps)
                let j = jitter(&rng, 1.0)
                points.append(CGPoint(
                    x: radius * (cos(theta) - cos(start)) + j.x,
                    y: radius * (sin(theta) - sin(start)) + j.y
                ))
            }
        }
        corpus.append(SyntheticGesture(positions: points))
    }
    return corpus
}

// MARK: - Mock target

@MainActor
final class BenchTextTarget: TextInputTarget {
    var inserted = 0
    var documentContextBeforeInput: String? = "Hello wor"
    var documentContextAfterInput: String?
    var selectedText: String?
    var hasFullAccess = false

    func insertText(_ text: String) { inserted &+= text.utf8.count }
    func deleteBackward() { inserted &+= 1 }
    func adjustTextPosition(byCharacterOffset offset: Int) { inserted &+= offset }
}

#endif
