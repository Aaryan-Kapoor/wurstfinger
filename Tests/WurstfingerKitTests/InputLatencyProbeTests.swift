//
//  InputLatencyProbeTests.swift
//  WurstfingerKitTests
//

import Foundation
import Testing
@testable import WurstfingerKit

struct LatencyHistogramTests {
    @Test func percentilesReadBucketUpperEdges() {
        var histogram = LatencyHistogram()
        for _ in 0 ..< 90 { histogram.record(0.0012) } // bucket 2 → 1.5 ms
        for _ in 0 ..< 10 { histogram.record(0.0071) } // bucket 14 → 7.5 ms
        #expect(histogram.total == 100)
        #expect(abs(histogram.percentile(0.5)! - 0.0015) < 1e-9)
        #expect(abs(histogram.percentile(0.95)! - 0.0075) < 1e-9)
        #expect(histogram.worst == 0.0071)
    }

    @Test func overflowReportsTheWorstSample() {
        var histogram = LatencyHistogram()
        histogram.record(0.5)
        #expect(histogram.percentile(0.99) == 0.5)
    }

    @Test func rejectsNonsense() {
        var histogram = LatencyHistogram()
        histogram.record(-1)
        histogram.record(.nan)
        histogram.record(.infinity)
        #expect(histogram.total == 0)
        #expect(histogram.summary == nil)
    }

    @Test func summaryNamesEveryFigure() {
        var histogram = LatencyHistogram()
        histogram.record(0.002)
        #expect(histogram.summary == "p50 2.5 p95 2.5 p99 2.5 max 2.0 ms n=1")
    }
}

@MainActor
struct InputLatencyProbeTests {
    private final class Clock {
        var now: TimeInterval = 100
    }

    @Test func longIterationsAreLoggedAsHitches() {
        let clock = Clock()
        var logged: [String] = []
        let probe = InputLatencyProbe(log: { logged.append($0) }, now: { clock.now })

        probe.iterationBegan()
        clock.now += 0.010
        probe.iterationEnded()
        #expect(logged.isEmpty, "A 10 ms iteration is not a hitch")

        probe.iterationBegan()
        clock.now += 0.080
        probe.iterationEnded()
        #expect(logged == ["hitch 80ms"])
        #expect(probe.hitchCount == 1)
    }

    @Test func anEndWithoutABeginIsIgnored() {
        var logged: [String] = []
        let probe = InputLatencyProbe(log: { logged.append($0) }, now: { 0 })
        probe.iterationEnded()
        #expect(logged.isEmpty)
    }

    @Test func flushSummarizesAndResets() {
        let clock = Clock()
        var logged: [String] = []
        let probe = InputLatencyProbe(log: { logged.append($0) }, now: { clock.now })
        probe.touchHandled(eventTime: clock.now - 0.003)
        probe.iterationBegan()
        clock.now += 0.050
        probe.iterationEnded()
        logged.removeAll()

        probe.flush()
        #expect(logged.count == 2)
        #expect(logged[0].hasPrefix("touchLatency p50 3.5"))
        #expect(logged[1] == "hitches 1 worst 50ms")

        logged.removeAll()
        probe.flush()
        #expect(logged.isEmpty, "A new period starts empty")
    }
}
