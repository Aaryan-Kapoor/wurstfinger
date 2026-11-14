//
//  TouchPath.swift
//  WurstfingerScenarioKit
//
//  Synthetic finger movements. A path is what SwiftUI's `DragGesture` would
//  deliver for a real touch — translations from the touch-down point sampled
//  at the display rate, with the small tremor of a real finger — so the
//  recognition code under test sees the input it sees on a device.
//

import CoreGraphics
import Foundation
@testable import WurstfingerKit

/// A recorded finger movement: translations from the touch-down point.
struct TouchPath: Equatable {
    /// Display rate the samples are spaced at (a ProMotion iPhone).
    static let sampleRate: Double = 120

    /// Samples relative to touch-down; the first one is always `.zero`, like
    /// the first `onChanged` of a drag.
    var samples: [CGPoint]

    /// How long the touch lasted.
    var duration: TimeInterval {
        Double(max(samples.count - 1, 0)) / Self.sampleRate
    }

    /// Largest distance from the touch-down point.
    var maxDisplacement: CGFloat {
        samples.map { hypot($0.x, $0.y) }.max() ?? 0
    }

    /// Where the finger lifted.
    var end: CGPoint {
        samples.last ?? .zero
    }

    /// The same path with every sample moved by `offset`, for drawing it at a
    /// place on screen instead of relative to touch-down.
    func offset(by offset: CGPoint) -> [CGPoint] {
        samples.map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
    }
}

/// Small deterministic generator, so a scenario produces the same touch paths
/// on every run and a failure can be reproduced.
struct SplitMix64: RandomNumberGenerator {
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
}

/// Builds touch paths for a key of a given size.
struct TouchSynthesizer {
    /// The key the finger is on, in points. Swipe lengths scale with it, the
    /// way a thumb's reach scales with the key it aims across.
    var keySize: CGSize

    /// Peak sideways tremor of the finger, in points. Mild: it stays below the
    /// preprocessor's jitter threshold, like a steady hand.
    var jitter: CGFloat = 0.5

    private var generator: SplitMix64

    init(keySize: CGSize, jitter: CGFloat = 0.5, seed: UInt64 = 1) {
        self.keySize = keySize
        self.jitter = jitter
        generator = SplitMix64(seed: seed)
    }

    // MARK: Gestures

    /// A press and release in place.
    mutating func tap(duration: TimeInterval = 0.08) -> TouchPath {
        path(duration: duration) { _ in .zero }
    }

    /// A press held in place, as for a long press.
    mutating func hold(duration: TimeInterval) -> TouchPath {
        path(duration: duration) { _ in .zero }
    }

    /// A flick from the touch-down point toward `gesture`, travelling
    /// `fraction` of the way to the key's edge.
    mutating func swipe(
        _ gesture: GestureType, fraction: CGFloat = 0.85, duration: TimeInterval = 0.14
    ) -> TouchPath {
        let target = vector(for: gesture, length: reach(for: gesture) * fraction)
        return path(duration: duration) { t in
            CGPoint(x: target.x * Self.smoothstep(t), y: target.y * Self.smoothstep(t))
        }
    }

    /// A flick out toward `gesture` and back: it ends near where it began.
    mutating func returnSwipe(
        _ gesture: GestureType, fraction: CGFloat = 0.9, comeBack: CGFloat = 0.9,
        duration: TimeInterval = 0.3
    ) -> TouchPath {
        let target = vector(for: gesture, length: reach(for: gesture) * fraction)
        return path(duration: duration) { t in
            // Out in the first half, back in the second.
            let out = Self.smoothstep(min(t * 2, 1))
            let back = Self.smoothstep(max(t * 2 - 1, 0)) * comeBack
            let s = out - back
            return CGPoint(x: target.x * s, y: target.y * s)
        }
    }

    /// A loop that starts and ends at the touch-down point.
    mutating func circle(
        clockwise: Bool, radiusFraction: CGFloat = 0.38, duration: TimeInterval = 0.4
    ) -> TouchPath {
        let radius = min(keySize.width, keySize.height) * radiusFraction
        // Screen y points down, so a growing angle runs clockwise. The loop
        // starts at its bottom point and runs a little past one turn, the way
        // a thumb overshoots its start.
        let turns = 1.05
        return path(duration: duration) { t in
            let angle = Double.pi / 2 + (clockwise ? 1 : -1) * 2 * Double.pi * turns * Self.smoothstep(t)
            let x = radius * cos(angle)
            let y = radius * sin(angle) - radius
            return CGPoint(x: x, y: y)
        }
    }

    /// A straight drag by `translation`, at constant speed. For the slide keys
    /// (space bar cursor drag, delete drag).
    mutating func drag(by translation: CGSize, speed: CGFloat = 500) -> TouchPath {
        let length = hypot(translation.width, translation.height)
        let duration = max(Double(length / speed), 0.05)
        return path(duration: duration) { t in
            CGPoint(x: translation.width * t, y: translation.height * t)
        }
    }

    // MARK: Geometry

    /// Direction of `gesture` on screen (y grows downward), as a unit vector
    /// along the key's own diagonal for the corner directions: a thumb aiming
    /// at a corner of a non-square key heads for the corner, not at 45°.
    private func vector(for gesture: GestureType, length: CGFloat) -> CGPoint {
        let (sx, sy): (CGFloat, CGFloat)
        switch gesture {
        case .swipeUp: (sx, sy) = (0, -1)
        case .swipeDown: (sx, sy) = (0, 1)
        case .swipeLeft: (sx, sy) = (-1, 0)
        case .swipeRight: (sx, sy) = (1, 0)
        case .swipeUpLeft: (sx, sy) = (-1, -1)
        case .swipeUpRight: (sx, sy) = (1, -1)
        case .swipeDownLeft: (sx, sy) = (-1, 1)
        case .swipeDownRight: (sx, sy) = (1, 1)
        default: (sx, sy) = (0, 0)
        }
        let raw = CGPoint(x: sx * keySize.width, y: sy * keySize.height)
        let magnitude = hypot(raw.x, raw.y)
        guard magnitude > 0 else { return .zero }
        return CGPoint(x: raw.x / magnitude * length, y: raw.y / magnitude * length)
    }

    /// How far a full-length flick toward `gesture` travels: a key's height or
    /// width, and three quarters of the diagonal toward a corner.
    private func reach(for gesture: GestureType) -> CGFloat {
        switch gesture {
        case .swipeUp, .swipeDown: keySize.height
        case .swipeLeft, .swipeRight: keySize.width
        default: hypot(keySize.width, keySize.height) * 0.75
        }
    }

    // MARK: Sampling

    /// Samples `position` (progress 0...1 in, translation out) at the display
    /// rate and adds finger tremor.
    private mutating func path(
        duration: TimeInterval, position: (Double) -> CGPoint
    ) -> TouchPath {
        let count = max(Int((duration * TouchPath.sampleRate).rounded()), 1)
        var samples: [CGPoint] = [.zero]
        for index in 1 ... count {
            let t = Double(index) / Double(count)
            let base = position(t)
            let noiseX = CGFloat.random(in: -jitter ... jitter, using: &generator)
            let noiseY = CGFloat.random(in: -jitter ... jitter, using: &generator)
            // The release sample is exact, so a path ends where it was aimed.
            let isLast = index == count
            samples.append(CGPoint(
                x: base.x + (isLast ? 0 : noiseX),
                y: base.y + (isLast ? 0 : noiseY)
            ))
        }
        return TouchPath(samples: samples)
    }

    private static func smoothstep(_ t: Double) -> CGFloat {
        let c = min(max(t, 0), 1)
        return CGFloat(c * c * (3 - 2 * c))
    }
}
