//
//  TouchFeelEvents.swift
//  Wurstfinger
//
//  What the input engine reports to the feel layer (haptics, animations)
//  beyond the keystrokes themselves.
//

import CoreGraphics
import Foundation

/// Where an in-flight flick is heading, as the engine's speculative
/// classification sees it: the target that releasing now would produce.
///
/// The feel layer compares the previous and the new value to decide what the
/// finger should feel (a direction detent, the turn of a return swipe, the
/// long-swipe threshold), so the engine only reports *that* it changed.
struct GestureCandidate: Equatable, Sendable {
    /// The gesture, or nil while releasing would still be a tap.
    var gesture: GestureType?
    var isReturn = false
    var isLongSwipe = false

    /// A finger that has not left the key's centre.
    static let tap = GestureCandidate()

    var isCircle: Bool {
        gesture == .circularClockwise || gesture == .circularCounterclockwise
    }
}

/// A long press's life, for the swell and the progress ring.
enum LongPressFeelPhase: Equatable, Sendable {
    /// The timer was armed at touch-down and fires after `delay` unless the
    /// finger moves or lifts. `keyFrame` is the key's touch frame in the
    /// grid's coordinate space.
    case armed(keyFrame: CGRect, delay: TimeInterval)
    /// The finger moved or lifted first, or the hold resolved to nothing.
    case cancelled
    /// The long press fired and typed.
    case fired
}
