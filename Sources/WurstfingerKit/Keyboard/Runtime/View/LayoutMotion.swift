//
//  LayoutMotion.swift
//  Wurstfinger
//
//  How the keyboard moves when its geometry changes: rotation, a window
//  resize, the split or numpad column switched, a size slider dragged.
//

import SwiftUI

/// The geometry a frame of the keyboard is drawn with: what, when it changes,
/// moves keys. A mode switch that keeps every key where it was leaves it
/// equal, so it triggers no layout animation — the keys' labels cross-fade on
/// their own (`FeelMotion.labelSwap`); one that reshapes a key (the numeric
/// mode's narrower space bar beside its zero) reshapes it quickly
/// (`LayoutMotion.reshapeDuration`).
struct KeyboardGeometrySignature: Equatable, Sendable {
    let metrics: KeyboardLayoutMetrics
    let cells: [SolvedCell]
    let isSplit: Bool

    init(_ plan: KeyboardLayoutPlan) {
        metrics = plan.metrics
        cells = GridLayoutSolver.solve(plan.arrangement)
        isSplit = plan.isSplit
    }
}

/// The two ways the keyboard's geometry moves.
enum LayoutMotion: Equatable, Sendable {
    /// A change on its own — rotation, a toggle, a language with another
    /// shape: the keys glide to their new places and settle, without bounce,
    /// in `duration` (the system's transition time when it gave one, so the
    /// keys land with the keyboard's frame).
    case settle(duration: TimeInterval)
    /// A change that is one frame of a continuous one — a window being
    /// resized, a slider being dragged: the keys follow at once, a stiff
    /// spring smoothing only the steps between frames, and retargeting
    /// mid-flight without lag.
    case follow

    /// Settle duration when nothing better is known.
    static let settleDuration: TimeInterval = 0.34

    /// Settle duration when only the keys' shape changed at the same size —
    /// a mode with another arrangement. Quick: the user is mid-typing, and
    /// the new keys already answer touches at their final places.
    static let reshapeDuration: TimeInterval = 0.2

    /// Changes closer together than this are frames of one continuous change.
    static let continuityWindow: TimeInterval = 0.12

    /// The spring, for the SwiftUI keys and the UIKit side that animates
    /// alongside them (the controller's height constraint) alike.
    var spring: KeyboardSpring {
        switch self {
        case let .settle(duration): .glide(duration)
        case .follow: .follow
        }
    }

    var animation: Animation { spring.animation }
}

/// Decides, per geometry change, how it moves (`LayoutMotion`).
///
/// Asked by the root view each time it renders and by the controller when it
/// sets its height, both for the same signature: the first ask of a new
/// signature decides and records it, every later ask of the same one gets the
/// same answer, so the SwiftUI keys and the UIKit frame always move together.
/// A plain reference type, not observed: deciding never invalidates a view.
@MainActor
final class LayoutMotionClock {
    private var lastSignature: KeyboardGeometrySignature?
    private var lastChange: TimeInterval = -.infinity
    private var current: LayoutMotion?
    /// A system transition (rotation) announced its duration for the next
    /// change (`noteSystemTransition`).
    private var pendingTransitionDuration: TimeInterval?
    private let now: () -> TimeInterval

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    /// The next geometry change belongs to a system transition of
    /// `duration` (rotation): it settles in exactly that time.
    func noteSystemTransition(duration: TimeInterval) {
        pendingTransitionDuration = duration > 0 ? duration : nil
    }

    /// How the change to `signature` moves; nil for no animation — the first
    /// geometry ever drawn, an unchanged one, or Reduce Motion.
    func motion(for signature: KeyboardGeometrySignature, reduceMotion: Bool) -> LayoutMotion? {
        guard signature != lastSignature else { return current }
        let time = now()
        defer {
            lastSignature = signature
            lastChange = time
        }
        guard lastSignature != nil, !reduceMotion else {
            pendingTransitionDuration = nil
            current = nil
            return nil
        }
        if let duration = pendingTransitionDuration {
            pendingTransitionDuration = nil
            current = .settle(duration: duration)
        } else if time - lastChange < LayoutMotion.continuityWindow {
            current = .follow
        } else if signature.metrics == lastSignature?.metrics, signature.isSplit == lastSignature?.isSplit {
            current = .settle(duration: LayoutMotion.reshapeDuration)
        } else {
            current = .settle(duration: LayoutMotion.settleDuration)
        }
        return current
    }
}
