//
//  KeyboardSpring.swift
//  Wurstfinger
//
//  The springs the keyboard moves with, in one set of terms for SwiftUI and
//  UIKit alike.
//

import SwiftUI

/// A spring as (duration, bounce): the terms of `Animation.spring(duration:bounce:)`
/// and of `UIView.animate(springDuration:bounce:)`, so a SwiftUI view and a
/// UIKit frame given the same spring move together.
///
/// Every spring the keyboard uses is one of these: the feel layer's five
/// (`FeelMotion`) and the geometry's (`LayoutMotion`). Bounce 0 is critically
/// damped, a glide that never passes its target; the feel springs carry a
/// little bounce, the geometry none or nearly none, since a whole keyboard
/// swinging past its size reads as a wobble, not as life.
struct KeyboardSpring: Equatable, Sendable {
    /// The perceptual duration: about when the motion looks finished.
    var duration: TimeInterval
    /// 0 for no overshoot, up to 1 for an undamped one.
    var bounce: Double

    var animation: Animation { .spring(duration: duration, bounce: bounce) }

    // MARK: Feel (`FeelMotion`)

    /// Following a finger: fast and barely bouncy, keeping up with a flick
    /// without swinging past it.
    static let track = KeyboardSpring(duration: 0.18, bounce: 0.15)
    /// Coming to rest, back before the next keystroke at 8–10 keys a second.
    static let settle = KeyboardSpring(duration: 0.24, bounce: 0.15)
    /// Arriving with a little life.
    static let land = KeyboardSpring(duration: 0.2, bounce: 0.25)
    /// Opening up something larger.
    static let unfold = KeyboardSpring(duration: 0.28, bounce: 0.15)
    /// A ratchet pawl: the one snappy, springy one.
    static let detent = KeyboardSpring(duration: 0.14, bounce: 0.3)

    // MARK: Geometry (`LayoutMotion`)

    /// Following a continuous resize frame by frame: stiff and all but
    /// critically damped, smoothing only the steps between frames.
    static let follow = KeyboardSpring(duration: 0.14, bounce: 0.08)

    /// Gliding to a new geometry in `duration`, without overshoot.
    static func glide(_ duration: TimeInterval) -> KeyboardSpring {
        KeyboardSpring(duration: duration, bounce: 0)
    }
}
