//
//  SlideGestureState.swift
//  Wurstfinger
//
//  Touch state for keys with slide behavior (space, delete): continuous drag
//  deltas during the gesture, and tap/swipe classification at the end.
//

import CoreGraphics

/// Phase of a slide gesture lifecycle.
enum SlidePhase: Equatable, Sendable {
    /// First drag movement detected beyond activation threshold.
    case began
    /// Continuous drag update with horizontal delta since last report.
    case changed(deltaX: CGFloat)
    /// Drag ended while sliding.
    case ended
    /// Drag ended without exceeding the slide activation threshold → tap.
    case tap
    /// Vertical up-swipe ended while the horizontal slide never activated.
    /// `isReturn` is true when the finger came back toward its origin
    /// (MessagEase: up toggles extra-symbol labels, return-up toggles
    /// letter + standard-symbol labels).
    case swipeUp(isReturn: Bool)
    /// Downward swipe (not coming back) while the horizontal slide never
    /// activated. Only keys whose configuration has a `swipeDownThreshold`
    /// report it: the space bar, where it takes the first word completion.
    case swipeDown
    /// Touch sequence was cancelled by the system (incoming call, edge
    /// swipe, keyboard dismissal mid-drag). Consumers must discard drag
    /// state without committing any input.
    case cancelled
}

/// Thresholds a slide key classifies against.
///
/// Bundled per key rather than passed as loose arguments: the delete key has
/// no up-swipe binding (`KeyboardViewModel.handleDeleteSlide` ignores
/// `.swipeUp`), so handing it the space bar's up-swipe threshold makes a
/// diagonal delete drag latch no slide and end as an up-swipe nobody
/// consumes — deleting nothing at all.
struct SlideGestureConfiguration: Equatable, Sendable {
    /// Horizontal travel that latches the continuous slide.
    let activationThreshold: CGFloat

    /// Upward travel that classifies a vertical swipe, or nil for keys
    /// without an up-swipe binding — those never let the vertical axis block
    /// the latch and never report `.swipeUp`. An up-and-return flick on such
    /// a key ends near its origin and therefore classifies as a tap — on
    /// delete that deletes one character. Deliberate: the alternative, a
    /// gesture that produces nothing at all, reads as a dropped input.
    let swipeUpThreshold: CGFloat?

    /// Downward travel that classifies a down-swipe, or nil for keys without
    /// one (every key but the space bar). Unlike the up-swipe it has no return
    /// variant: a pull down and back stays a tap, as it always was.
    var swipeDownThreshold: CGFloat?

    static let moveCursor = SlideGestureConfiguration(
        activationThreshold: KeyboardConstants.SpaceGestures.dragActivationThreshold,
        swipeUpThreshold: KeyboardConstants.SpaceGestures.swipeUpActivationThreshold,
        swipeDownThreshold: KeyboardConstants.SpaceGestures.swipeDownActivationThreshold
    )

    static let delete = SlideGestureConfiguration(
        activationThreshold: KeyboardConstants.DeleteGestures.slideActivationThreshold,
        swipeUpThreshold: nil,
        swipeDownThreshold: nil
    )

    /// A key without slide behavior: nothing can latch.
    static let inactive = SlideGestureConfiguration(
        activationThreshold: .infinity,
        swipeUpThreshold: nil,
        swipeDownThreshold: nil
    )

    static func `for`(_ slideType: SlideType) -> SlideGestureConfiguration {
        switch slideType {
        case .moveCursor: .moveCursor
        case .delete: .delete
        case .none: .inactive
        }
    }
}

/// One finger's slide state machine on a space or delete key (see `TouchEngine`).
///
/// Extracted as a pure value type so tap/slide classification and
/// cancellation recovery can be unit-tested without rendering SwiftUI views.
struct SlideGestureState: Sendable {
    private(set) var dragStarted = false
    private(set) var isSliding = false
    private(set) var lastTranslationX: CGFloat = 0
    /// Most-negative vertical translation seen this gesture (SwiftUI's y axis
    /// points down, so upward travel is negative). Peak of the up-swipe.
    private(set) var upwardPeakY: CGFloat = 0
    /// Largest downward translation seen this gesture, for the down-swipe.
    private(set) var downwardPeakY: CGFloat = 0
    /// Largest distance from the touch-down origin seen so far. Mirrors
    /// `KeyGestureSequence.maxDisplacement`; used to cancel a pending long
    /// press once the finger has clearly left its resting position.
    private(set) var maxDisplacement: CGFloat = 0

    /// Events produced by a single drag update.
    ///
    /// One sample can latch the slide (`.began`) and report its first travel
    /// (`.changed`) in the same update, and never anything else, so the two
    /// are stored as two fields rather than an array: the input engine reads
    /// them on every drag sample, and an array of phases cost a heap
    /// allocation per sample for as long as a cursor slide lasted.
    struct Update: Equatable, Sendable {
        var isTouchDown = false
        /// The slide latched on this sample.
        var began = false
        /// Horizontal travel since the last report, when the slide is latched
        /// and the finger moved.
        var deltaX: CGFloat?

        /// The phases in the order they are reported, for callers that want
        /// a sequence (the tests); the engine reads the fields directly.
        var phases: [SlidePhase] {
            var phases: [SlidePhase] = []
            if began { phases.append(.began) }
            if let deltaX { phases.append(.changed(deltaX: deltaX)) }
            return phases
        }
    }

    /// Processes one `onChanged` sample.
    mutating func handleChanged(
        translation: CGSize,
        configuration: SlideGestureConfiguration
    ) -> Update {
        var update = Update()
        if !dragStarted {
            dragStarted = true
            update.isTouchDown = true
        }

        let currentX = translation.width
        upwardPeakY = min(upwardPeakY, translation.height)
        downwardPeakY = max(downwardPeakY, translation.height)
        maxDisplacement = max(maxDisplacement, hypot(translation.width, translation.height))

        // Activate only while the horizontal axis dominates: crossing the
        // (small) horizontal threshold during a mostly-vertical movement must
        // not latch the slide, or an upward label-toggle swipe with a few
        // points of sideways drift turns into a cursor slide and the vertical
        // classification in `handleEnded` becomes unreachable. Once latched,
        // the slide stays tolerant of vertical drift as before.
        //
        // Instantaneous dominance alone is not enough: on the return leg of a
        // return-up swipe the vertical translation shrinks through ~0 while
        // sideways drift stays, so a lift-off sample like (10, -6) would
        // latch the slide even though the peak committed the up-swipe long
        // ago. Once the upward peak crossed the up-swipe threshold, the
        // gesture belongs to `handleEnded`'s vertical classification and must
        // never latch — *unless* the finger then makes a clearly dominant
        // horizontal move.
        //
        // Re-arm (finding #11): the committed up-peak latch never decayed, so
        // an incidental up-flick followed by a genuine sideways drag stayed
        // stuck as an up-swipe and the cursor never moved. Re-allow latching
        // only when the current horizontal travel is both large in absolute
        // terms (≥ the 30 pt up-swipe threshold) and strongly horizontal
        // (> 2× the vertical). Return-leg drift (~10 pt sideways) stays well
        // below the 30 pt floor, so this does not re-introduce the return-up
        // mis-latch the peak guard was added to fix. A key without an up-swipe
        // binding has no threshold at all, so neither guard applies to it.
        let upSwipeCommitted = configuration.swipeUpThreshold.map { -upwardPeakY >= $0 } ?? false
        // A committed down-swipe blocks the latch the same way (word completions).
        let downSwipeCommitted = configuration.swipeDownThreshold.map { downwardPeakY >= $0 } ?? false
        let dominantHorizontalSlide = (configuration.swipeUpThreshold ?? configuration.swipeDownThreshold).map {
            abs(currentX) >= $0 && abs(currentX) > abs(translation.height) * 2
        } ?? false
        if !isSliding,
           abs(currentX) >= configuration.activationThreshold,
           abs(currentX) > abs(translation.height),
           !(upSwipeCommitted || downSwipeCommitted) || dominantHorizontalSlide {
            isSliding = true
            // Anchor at the threshold crossing (not the full translation) so
            // the travel beyond the threshold is reported on the same tick
            // instead of being dropped — otherwise the first `threshold`
            // points are a dead zone.
            lastTranslationX = currentX < 0
                ? -configuration.activationThreshold
                : configuration.activationThreshold
            update.began = true
        }

        if isSliding {
            let deltaX = currentX - lastTranslationX
            if deltaX != 0 {
                lastTranslationX = currentX
                update.deltaX = deltaX
            }
        }

        return update
    }

    /// Processes `onEnded`. Returns the phase to report, or nil when the
    /// gesture qualifies as neither a slide, an up-swipe, nor a tap.
    mutating func handleEnded(
        translation: CGSize,
        configuration: SlideGestureConfiguration
    ) -> SlidePhase? {
        defer { reset() }
        if isSliding { return .ended }
        // Vertical classification runs only when the horizontal slide never
        // activated, so cursor drags with vertical drift are unaffected. It
        // must precede the tap check: a return-up swipe ends near its origin
        // and would otherwise be classified as a tap.
        if let swipeUpThreshold = configuration.swipeUpThreshold, -upwardPeakY >= swipeUpThreshold {
            // The finger "returned" when it came back at least
            // (1 - returnSwipeThreshold) of the way from the peak toward the
            // origin. Compared signed (peak is negative, y grows downward) so
            // overshooting past the origin still counts as a return — fast
            // return swipes routinely end below their starting point, and an
            // absolute-distance ratio would misread them as plain up-swipes.
            // Downward peaks are never tracked, so down-swipes still fall
            // through and stay ignored.
            let returnBoundary = upwardPeakY * KeyboardConstants.SpaceGestures.returnSwipeThreshold
            return .swipeUp(isReturn: translation.height >= returnBoundary)
        }
        // A down-swipe must still be low when the finger lifts: pulled down and
        // back it is a tap, exactly as before the space bar had a down-swipe.
        if let swipeDownThreshold = configuration.swipeDownThreshold, downwardPeakY >= swipeDownThreshold,
           translation.height > downwardPeakY * KeyboardConstants.SpaceGestures.returnSwipeThreshold {
            return .swipeDown
        }
        // A tap must stay near its origin on *both* axes. Gating on
        // horizontal travel alone would classify a vertical flick (e.g.
        // 80 pt up on the space bar) as a tap and commit its center action.
        let displacement = hypot(translation.width, translation.height)
        return displacement < configuration.activationThreshold ? .tap : nil
    }

    /// Processes a system cancellation of the touch sequence (`onEnded` is
    /// never called for cancelled gestures). Resets all state so the next
    /// touch starts a fresh sequence instead of computing deltas against a
    /// stale anchor; returns `.cancelled` when a drag was in flight.
    mutating func handleCancelled() -> SlidePhase? {
        defer { reset() }
        return dragStarted ? .cancelled : nil
    }

    private mutating func reset() {
        dragStarted = false
        isSliding = false
        lastTranslationX = 0
        upwardPeakY = 0
        downwardPeakY = 0
        maxDisplacement = 0
    }
}
