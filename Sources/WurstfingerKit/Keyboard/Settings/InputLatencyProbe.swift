//
//  InputLatencyProbe.swift
//  Wurstfinger
//
//  On-device evidence for "instant": how long touches wait before the
//  keyboard handles them, and how long the main thread ever stalls.
//

import CoreFoundation
import Foundation

/// A fixed-bucket latency histogram: recording is a bucket increment, with no
/// allocation and no lock (main-actor only), so it can sit on the touch path.
///
/// Buckets are 0.5 ms wide up to 32 ms, plus one overflow bucket — fine enough
/// to tell a 2 ms delivery from an 8 ms one, coarse enough to stay 65 counters.
struct LatencyHistogram: Sendable, Equatable {
    static let bucketWidth: TimeInterval = 0.0005
    static let bucketCount = 64

    private(set) var counts = [UInt32](repeating: 0, count: bucketCount + 1)
    private(set) var total = 0
    private(set) var worst: TimeInterval = 0

    mutating func record(_ latency: TimeInterval) {
        guard latency.isFinite, latency >= 0 else { return }
        let bucket = min(Int(latency / Self.bucketWidth), Self.bucketCount)
        counts[bucket] &+= 1
        total += 1
        worst = max(worst, latency)
    }

    /// The latency at or below which `fraction` of the samples fall (bucket
    /// upper edge), or nil with no samples.
    func percentile(_ fraction: Double) -> TimeInterval? {
        guard total > 0 else { return nil }
        let target = max(Int((Double(total) * fraction).rounded(.up)), 1)
        var seen = 0
        for (bucket, count) in counts.enumerated() {
            seen += Int(count)
            if seen >= target {
                return bucket == Self.bucketCount ? worst : Double(bucket + 1) * Self.bucketWidth
            }
        }
        return worst
    }

    mutating func reset() {
        self = LatencyHistogram()
    }

    /// One line for the health log, e.g. `p50 1.5 p95 3.0 p99 4.5 max 6.2 ms n=412`.
    var summary: String? {
        guard total > 0,
              let p50 = percentile(0.5), let p95 = percentile(0.95), let p99 = percentile(0.99)
        else { return nil }
        func ms(_ value: TimeInterval) -> String { String(format: "%.1f", value * 1000) }
        return "p50 \(ms(p50)) p95 \(ms(p95)) p99 \(ms(p99)) max \(ms(worst)) ms n=\(total)"
    }
}

/// Measures the keyboard's responsiveness where it actually runs.
///
/// - **Touch latency.** For every touch event the surface hands the engine, the
///   time from the hardware timestamp (`UITouch.timestamp`, on the same clock
///   as `systemUptime`) to the engine having finished with it — delivery delay
///   (system gesture gates, a busy main thread) plus our own handling, which
///   includes classification, dispatch and `insertText` on release.
/// - **Main-thread hitches.** A run-loop observer timestamps each iteration's
///   wake-up and the moment it goes back to sleep; an iteration busy longer
///   than `hitchThreshold` (two frames at 60 Hz) is a hitch the user could see
///   or feel, and is written to the health log with its duration. No extra
///   thread, no pings: two clock reads per run-loop iteration.
///
/// Summaries go to `KeyboardHealthLog` when the keyboard is about to be
/// suspended (`flush`), so the expert settings' health screen shows how
/// instant the keyboard really was, on the device, without a Mac.
@MainActor
final class InputLatencyProbe {
    static let shared = InputLatencyProbe()

    /// Longer than this, a main-thread stall is logged as a hitch.
    static let hitchThreshold: TimeInterval = 0.034

    private(set) var touchLatency = LatencyHistogram()
    private(set) var hitchCount = 0
    private(set) var worstHitch: TimeInterval = 0

    private var iterationStart: TimeInterval?
    private var observer: CFRunLoopObserver?
    private let log: (String) -> Void
    private let now: () -> TimeInterval

    init(
        log: @escaping (String) -> Void = { KeyboardHealthLog.shared.record($0) },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.log = log
        self.now = now
    }

    // MARK: - Touch latency

    /// A touch event stamped `eventTime` has been fully handled.
    func touchHandled(eventTime: TimeInterval) {
        touchLatency.record(now() - eventTime)
    }

    // MARK: - Hitches

    /// Starts watching the main run loop. Idempotent.
    func startWatchingMainThread() {
        guard observer == nil else { return }
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { [weak self] _, activity in
            // The main run loop's observers run on the main thread.
            MainActor.assumeIsolated {
                if activity == .afterWaiting {
                    self?.iterationBegan()
                } else {
                    self?.iterationEnded()
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    func stopWatchingMainThread() {
        guard let observer else { return }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = nil
    }

    /// The main thread woke up to handle something.
    func iterationBegan() {
        iterationStart = now()
    }

    /// The main thread finished and is going back to sleep.
    func iterationEnded() {
        guard let start = iterationStart else { return }
        iterationStart = nil
        let busy = now() - start
        guard busy > Self.hitchThreshold else { return }
        hitchCount += 1
        worstHitch = max(worstHitch, busy)
        log(String(format: "hitch %.0fms", busy * 1000))
    }

    // MARK: - Reporting

    /// Writes the period's summary to the health log and starts a new period.
    func flush() {
        if let summary = touchLatency.summary {
            log("touchLatency " + summary)
        }
        if hitchCount > 0 {
            log(String(format: "hitches %d worst %.0fms", hitchCount, worstHitch * 1000))
        }
        touchLatency.reset()
        hitchCount = 0
        worstHitch = 0
    }
}
