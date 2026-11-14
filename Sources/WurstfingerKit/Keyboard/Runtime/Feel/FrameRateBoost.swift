//
//  FrameRateBoost.swift
//  Wurstfinger
//
//  Asks a ProMotion display for its full rate while a finger is on the keys.
//

import Foundation
#if os(iOS)
import QuartzCore
import UIKit
#endif

/// When the keyboard wants the display at full rate: from a touch until a
/// short while after the last feel event, so a press, a flick's guide card
/// and the release spring all render at 120 Hz on a ProMotion iPhone — and
/// nothing is asked for while the keyboard is idle.
///
/// Pure bookkeeping, so the window can be tested with a clock; the display
/// link that acts on it is `FrameRateBoost`.
struct FrameRateWindow: Equatable, Sendable {
    /// How long the boost outlasts the last touch moment: long enough for the
    /// release spring and a pop to finish (~0.3 s), short enough not to keep
    /// the display fast while the user reads.
    static let linger: TimeInterval = 0.45

    private(set) var deadline: TimeInterval = -.infinity

    /// A touch moment at `time`. Returns whether the boost has to start.
    mutating func engage(at time: TimeInterval) -> Bool {
        let wasActive = isActive(at: time)
        deadline = max(deadline, time + Self.linger)
        return !wasActive
    }

    func isActive(at time: TimeInterval) -> Bool {
        time < deadline
    }
}

/// A paused-while-idle display link that requests 80–120 Hz while engaged.
///
/// On iPhone a request above 60 Hz is honoured only with
/// `CADisableMinimumFrameDurationOnPhone` in the bundle's Info.plist (set for
/// the app and the keyboard). The link's own callback does nothing but check
/// the window and pause itself when it has passed: no timer, no main-thread
/// work beyond one comparison per frame while a finger is down. A no-op on
/// macOS and in tests.
@MainActor
final class FrameRateBoost {
    private var window = FrameRateWindow()
    private let now: () -> TimeInterval
    #if os(iOS)
    private var link: CADisplayLink?
    #endif

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    /// A touch moment: keeps the display fast for `FrameRateWindow.linger`.
    func engage() {
        guard window.engage(at: now()) else { return }
        #if os(iOS)
        guard !UnitTestHost.isActive else { return }
        if link == nil {
            let link = CADisplayLink(target: FrameRateBoostTarget(self), selector: #selector(FrameRateBoostTarget.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.isPaused = false
        #endif
    }

    /// Releases the display link (the keyboard is going away).
    func stop() {
        #if os(iOS)
        link?.invalidate()
        link = nil
        #endif
    }

    var isEngaged: Bool { window.isActive(at: now()) }

    fileprivate func tick() {
        #if os(iOS)
        if !window.isActive(at: now()) { link?.isPaused = true }
        #endif
    }
}

#if os(iOS)
/// The display link's target: holds the boost weakly, so the link (which
/// retains its target) cannot keep the keyboard's feel layer alive. A link
/// that outlives its boost (gone without `stop`) invalidates itself on its
/// next frame instead of ticking at full rate for nothing.
@MainActor
private final class FrameRateBoostTarget: NSObject {
    weak var boost: FrameRateBoost?

    init(_ boost: FrameRateBoost) {
        self.boost = boost
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let boost else {
            link.invalidate()
            return
        }
        boost.tick()
    }
}
#endif
