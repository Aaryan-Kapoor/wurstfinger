//
//  FeelMotion.swift
//  Wurstfinger
//
//  Every animation the keyboard's feel layer uses, in one place, with the
//  reason for each number. docs/feel.md tabulates them.
//

import SwiftUI

/// The keyboard's motion vocabulary.
///
/// Two rules shape every entry. **Nothing the user is waiting for animates
/// in:** a pressed key, the lit target of a flick and the typed text appear
/// on the first frame; only their *exit* and the *movement between* targets
/// are animated. **Springs, not curves,** for anything a finger drives: a
/// spring picks up from wherever an interrupted animation left off, so a fast
/// typist re-pressing a key mid-release never sees a jump.
///
/// Each spring is given as (response, damping fraction): response is roughly
/// the time to settle, damping below 1 allows a little overshoot.
enum FeelMotion {
    // MARK: Keys

    /// A key coming back up after the finger lifts. Damped enough that the
    /// 3 % scale and the fill never visibly bounce, quick enough to be back
    /// before the next keystroke at 8–10 keys a second.
    static let keyRelease = Animation.spring(response: 0.24, dampingFraction: 0.82)
    /// The same release under Reduce Motion: the fill fades, nothing moves.
    static let keyReleaseReduced = Animation.easeOut(duration: 0.14)

    /// How far a pressed key sinks. Small: the cap must read as "pushed",
    /// not as "shrunk", and the hints near its edge must stay put.
    static let pressedScale: CGFloat = 0.965

    /// The flick's target hint swelling and the others receding. Fast and
    /// barely underdamped: the target reads at once and settles without a
    /// visible wobble while the finger is still moving.
    static let hintEmphasis = Animation.spring(response: 0.18, dampingFraction: 0.84)

    /// Labels and hints changing with the mode (shift, numbers, symbols) or
    /// the language: a short cross-fade (glyphs morph where SwiftUI can
    /// interpolate them, e.g. a → A), so the change is seen as a change
    /// rather than a flash. Not motion, so it stays under Reduce Motion.
    static let labelSwap = Animation.easeInOut(duration: 0.16)

    /// The glass ripple: one wavelet leaving the touch point, over this long.
    static let rippleDuration: TimeInterval = 0.46
    /// Its largest displacement in points: a hint of refraction, never enough
    /// to blur a label.
    static let rippleAmplitude: CGFloat = 1.1

    // MARK: Guide card

    /// The lit target appearing on the card: it swells from 55 % toward the
    /// key it belongs to, slightly underdamped so it lands with a little life.
    static let guideAppear = Animation.spring(response: 0.2, dampingFraction: 0.74)
    /// The lit target sliding from one map cell to the next as the direction
    /// changes. Close to critical damping: it must track the finger, not
    /// swing past it.
    static let guideMove = Animation.spring(response: 0.18, dampingFraction: 0.86)
    /// The whole map unfolding after the finger rests (after
    /// `TouchGuideCard.revealDelay`).
    static let guideReveal = Animation.spring(response: 0.28, dampingFraction: 0.86)
    /// The map's scale before it unfolds.
    static let guideRevealScale: CGFloat = 0.92

    // MARK: Commit pop

    /// A committed glyph lifting off and fading.
    static let popDuration: TimeInterval = 0.3
    static let pop = Animation.timingCurve(0.2, 0.7, 0.3, 1, duration: popDuration)
    /// How far it rises, in key heights (from the key) or cells (from the card).
    static let popRise: CGFloat = 0.42
    static let popScale: CGFloat = 1.16
    /// Under Reduce Motion the glyph only fades, in place.
    static let popReduced = Animation.easeOut(duration: 0.18)

    // MARK: Long press

    /// The ring appearing once the finger has rested `LongPressFeel.ringLeadIn`.
    static let ringAppear = Animation.easeOut(duration: 0.12)
    /// The ring flashing out when the long press fires.
    static let ringFire = Animation.easeOut(duration: 0.22)
    /// The ring vanishing when the finger moves or lifts first.
    static let ringCancel = Animation.easeOut(duration: 0.1)

    // MARK: Slides

    /// One detent of the slide ratchet passing. Underdamped like a real
    /// ratchet pawl; short enough that at 60 steps a second the strip still
    /// reads as moving, not as vibrating.
    static let ratchetStep = Animation.spring(response: 0.14, dampingFraction: 0.7)
    static let ratchetFade = Animation.easeOut(duration: 0.18)
}

/// Geometry shared by the feel overlays.
enum FeelGeometry {
    /// The key as drawn, from its touch frame: the touch frame reaches into
    /// half of each inner gap (`KeyboardGridLayout.gapInsets`), except at the
    /// grid's outer edges.
    static func visibleKeyRect(touchFrame frame: CGRect, in bounds: CGSize) -> CGRect {
        let halfH = KeyboardConstants.Layout.gridHorizontalSpacing / 2
        let halfV = KeyboardConstants.Layout.gridVerticalSpacing / 2
        let edge: CGFloat = 0.5
        let leading = frame.minX <= edge ? 0 : halfH
        let trailing = frame.maxX >= bounds.width - edge ? 0 : halfH
        let top = frame.minY <= edge ? 0 : halfV
        let bottom = frame.maxY >= bounds.height - edge ? 0 : halfV
        return CGRect(
            x: frame.minX + leading,
            y: frame.minY + top,
            width: max(frame.width - leading - trailing, 0),
            height: max(frame.height - top - bottom, 0)
        )
    }

    /// The unit offset of a gesture's cell in the guide card's 3×3 map
    /// (`TouchGuideCard.layout`), from its centre: -1, 0 or 1 on each axis.
    static func mapOffset(of gesture: GestureType) -> CGVector {
        switch gesture {
        case .swipeUpLeft: CGVector(dx: -1, dy: -1)
        case .swipeUp: CGVector(dx: 0, dy: -1)
        case .swipeUpRight: CGVector(dx: 1, dy: -1)
        case .swipeLeft: CGVector(dx: -1, dy: 0)
        case .swipeRight: CGVector(dx: 1, dy: 0)
        case .swipeDownLeft: CGVector(dx: -1, dy: 1)
        case .swipeDown: CGVector(dx: 0, dy: 1)
        case .swipeDownRight: CGVector(dx: 1, dy: 1)
        default: .zero
        }
    }
}
