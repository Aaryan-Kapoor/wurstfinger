//
//  KeyGestureRecognizer.swift
//  Wurstfinger
//
//  Reusable gesture recognition ViewModifier that classifies touch
//  sequences into GestureType values using the existing preprocessing
//  and feature-extraction pipeline.
//

import CoreGraphics
import Foundation
import SwiftUI

/// Result of classifying a completed gesture.
struct GestureClassification: Sendable {
    let gesture: GestureType
    let isReturn: Bool
}

/// Touch-sequence state backing `KeyGestureRecognizer`.
///
/// Extracted as a pure value type so sequence tracking and cancellation
/// recovery can be unit-tested without rendering SwiftUI views.
struct KeyGestureSequence: Sendable {
    private var positions: RingBuffer<CGPoint>

    /// Largest distance from the touch-down origin seen so far. Tracked as a
    /// running maximum (rather than derived from the buffer) so it survives
    /// ring-buffer eviction and out-and-back paths; used to cancel a pending
    /// long press once the finger has clearly left its resting position.
    private(set) var maxDisplacement: CGFloat = 0

    init(capacity: Int = KeyboardConstants.Gesture.positionBufferSize) {
        positions = RingBuffer<CGPoint>(capacity: capacity)
    }

    /// Whether a touch sequence is currently being recorded.
    var isTracking: Bool {
        !positions.isEmpty
    }

    /// Records one `onChanged` sample. Returns true when this sample is the
    /// first contact of a new sequence (touch down).
    mutating func handleChanged(translation: CGSize) -> Bool {
        let isTouchDown = positions.isEmpty
        if isTouchDown {
            positions.append(.zero)
        }
        positions.append(CGPoint(x: translation.width, y: translation.height))
        maxDisplacement = max(maxDisplacement, hypot(translation.width, translation.height))
        return isTouchDown
    }

    /// Records the final sample and classifies the completed sequence against
    /// an already-resolved settings snapshot — the production path, which never
    /// touches `UserDefaults`.
    mutating func handleEnded(
        translation: CGSize,
        aspectRatio: CGFloat,
        tuning: GestureTuning
    ) -> GestureClassification {
        let samples = recordFinalSample(translation: translation)
        return KeyGestureRecognizer.classify(
            positions: samples, aspectRatio: aspectRatio, tuning: tuning
        )
    }

    /// Records the final sample and classifies the completed sequence, reading
    /// the settings from `SharedDefaults`. Kept for tests and tools; the view
    /// layer passes its snapshot to `handleEnded(translation:aspectRatio:tuning:)`.
    mutating func handleEnded(translation: CGSize, aspectRatio: CGFloat) -> GestureClassification {
        let samples = recordFinalSample(translation: translation)
        return KeyGestureRecognizer.classify(positions: samples, aspectRatio: aspectRatio)
    }

    /// Appends the release sample, returns the origin-anchored path, and resets
    /// the sequence for the next touch.
    private mutating func recordFinalSample(translation: CGSize) -> [CGPoint] {
        defer {
            positions.removeAll()
            maxDisplacement = 0
        }
        if positions.isEmpty {
            positions.append(.zero)
        }
        positions.append(CGPoint(x: translation.width, y: translation.height))
        return KeyGestureRecognizer.anchoringOrigin(positions.elements)
    }

    /// Discards the partial sequence after the system cancelled the touches
    /// (`onEnded` is never called for cancelled gestures). Without this, the
    /// next touch would skip touch-down handling and append onto the stale
    /// path, misclassifying a tap as the previous gesture's swipe.
    mutating func handleCancelled() {
        positions.removeAll()
        maxDisplacement = 0
    }
}

/// Reusable gesture recognition logic used by `KeyView`.
///
/// Wraps the existing `GesturePreprocessor` + `GestureFeatures` pipeline and
/// produces `GestureType` values instead of `KeyboardDirection`.
///
/// The modifier itself is main-actor (it is a `ViewModifier`), but the
/// classification statics are `nonisolated`: they are pure functions of their
/// arguments and belong to the value domain, so they can be called from any
/// isolation — including, one day, off the main thread.
struct KeyGestureRecognizer: ViewModifier {
    /// Called once per completed gesture with the classified result.
    let onGestureRecognized: (GestureClassification) -> Void

    /// Called on first touch contact (for haptic feedback).
    let onTouchDown: () -> Void

    /// Key aspect ratio forwarded to the preprocessor for normalization.
    let aspectRatio: CGFloat

    /// The user's gesture settings, resolved once by the view model and passed
    /// down by value. Classification and long-press timing read this — never
    /// `UserDefaults` — so the touch path does no store lookups.
    let tuning: GestureTuning

    /// Called when the finger has rested on the key for
    /// `KeyboardConstants.LongPress.duration` without moving beyond
    /// `movementTolerance`. Returns whether the long press was handled; a
    /// handled long press consumes the touch, so releasing produces no tap.
    /// An unhandled one (no long-press binding resolves for the key) leaves
    /// the touch untouched and it classifies normally on release. `nil`
    /// disables long-press detection entirely.
    var onLongPress: (() -> Bool)?

    /// Collects the touch path for the gesture trail overlay. Nil disables the
    /// feed entirely (previews and tests); when set, the recorder itself
    /// decides whether the user has the trail turned on.
    var trail: GestureTrailRecorder?

    @State private var sequence = KeyGestureSequence()
    @State private var longPress: LongPressScheduler
    /// Identifies this key's touch sequence to the shared trail recorder.
    @State private var trailToken = GestureTrailToken()
    @Binding var isActive: Bool

    /// True while a touch sequence is in flight. Unlike `@State`, SwiftUI
    /// guarantees `@GestureState` is reset when the system cancels the
    /// touches (incoming call, edge swipe, keyboard dismissal), where
    /// `onEnded` is never called — the reset is our cancellation signal.
    @GestureState private var sequenceInFlight = false

    /// - Parameter longPress: The scheduler this recognizer arms. Held in
    ///   `@State` so it survives body re-evaluations, and injectable so a test
    ///   can arm it from the outside and then observe what teardown does to
    ///   it. Without that seam the `onDisappear` → `abandonSequence()` wiring
    ///   is unobservable from a unit test: arming it through the real gesture
    ///   needs touch events the test target cannot synthesize. Mutation
    ///   testing found the wiring unpinned for exactly that reason (review
    ///   2026-08-09, finding 15).
    init(
        onGestureRecognized: @escaping (GestureClassification) -> Void,
        onTouchDown: @escaping () -> Void,
        aspectRatio: CGFloat,
        tuning: GestureTuning,
        onLongPress: (() -> Bool)? = nil,
        trail: GestureTrailRecorder? = nil,
        isActive: Binding<Bool>,
        longPress: LongPressScheduler = LongPressScheduler()
    ) {
        self.onGestureRecognized = onGestureRecognized
        self.onTouchDown = onTouchDown
        self.aspectRatio = aspectRatio
        self.tuning = tuning
        self.onLongPress = onLongPress
        self.trail = trail
        _isActive = isActive
        _longPress = State(initialValue: longPress)
    }

    func body(content: Content) -> some View {
        content
            .gesture(
                // The coordinate space affects only `value.location`, which the
                // trail records. `value.translation` is a delta, so the
                // classification below reads the same values in any space.
                DragGesture(minimumDistance: 0, coordinateSpace: GestureTrailRecorder.coordinateSpace)
                    .updating($sequenceInFlight) { _, inFlight, _ in
                        inFlight = true
                    }
                    .onChanged { value in
                        // A fired long press owns the rest of this touch: the
                        // digit is typed and the release is discarded in
                        // `onEnded`, so the sequence stops following the
                        // finger. The trail already froze when the press fired.
                        if longPress.consumedTouch {
                            isActive = true
                            return
                        }
                        let isTouchDown = sequence.handleChanged(translation: value.translation)
                        if isTouchDown {
                            trail?.begin(at: value.location, from: trailToken)
                        } else {
                            trail?.extend(to: value.location, from: trailToken)
                        }
                        if isTouchDown {
                            onTouchDown()
                            scheduleLongPress()
                        } else if longPress.isScheduled,
                                  sequence.maxDisplacement > tuning.longPressMovementTolerance {
                            longPress.cancel()
                        }
                        isActive = true
                    }
                    .onEnded { value in
                        longPress.cancel()
                        if longPress.consumedTouch {
                            // The long press already dispatched its action;
                            // discard the touch instead of classifying it, so
                            // releasing doesn't produce a second key event.
                            longPress.clearConsumed()
                            sequence.handleCancelled()
                            isActive = false
                            return
                        }
                        let signposter = InputSignposts.signposter
                        let classifyInterval = signposter.beginInterval(InputSignposts.classify)
                        let classification = sequence.handleEnded(
                            translation: value.translation,
                            aspectRatio: aspectRatio,
                            tuning: tuning
                        )
                        signposter.endInterval(InputSignposts.classify, classifyInterval)
                        trail?.finish(from: trailToken)
                        isActive = false
                        onGestureRecognized(classification)
                    }
            )
            .onChange(of: sequenceInFlight) { _, inFlight in
                // A normal end already cleared the sequence in `onEnded`; if
                // the sequence stops while samples remain, the system
                // cancelled the touches. Discard the partial gesture without
                // classifying it.
                guard !inFlight, sequence.isTracking else { return }
                abandonSequence()
                isActive = false
            }
            .onDisappear {
                // A key torn down mid-gesture hands its touch back here: the
                // recorder would otherwise keep the trail marked visible with
                // no fade scheduled, and the armed long press would still fire.
                // Ownership makes the trail hand-back a no-op for any key that
                // is not the one drawing, including while a trail is fading.
                abandonSequence()
            }
    }

    /// Drops everything the in-flight touch owns: the armed long press, the
    /// partial path, and the trail. Shared by the system-cancel path and by
    /// teardown — a key removed mid-gesture (mode switch, rotation, definition
    /// reload) reaches neither `onEnded` nor the `sequenceInFlight` reset,
    /// because both live on the view that went away, so an armed timer
    /// would fire 0.7 s later and type the old key's digit into the new mode.
    private func abandonSequence() {
        longPress.abandon()
        sequence.handleCancelled()
        trail?.cancel(from: trailToken)
    }

    // MARK: - Long Press

    /// Arms the shared scheduler with this recognizer's fire guard. The guard
    /// reads live `@State` (`sequence`) at fire time through the property
    /// wrapper. A fired press has typed its digit, so its trail freezes and
    /// fades like any other completed keystroke.
    ///
    /// The armed timer deliberately survives a mode switch that keeps this key
    /// alive — an accepted tradeoff, re-derived exhaustively in the
    /// 2026-08-09 review (finding 14) and recorded here so it does not get
    /// re-litigated:
    ///
    /// * A `.longPress` resolves to exactly two things: the space bar's zero
    ///   binding and the `GhostKeyResolver`'s digit-category tap fallback.
    ///   Everything else leaves the touch unconsumed and classifies normally
    ///   on release, so nothing else can fire late.
    /// * A key that is *removed* by the switch tears the hold down through
    ///   `onDisappear` → `abandonSequence()`. The portrait letters ↔ numeric
    ///   switch moves the space and return cells structurally, so a space hold
    ///   is torn down rather than surviving it.
    /// * For a pure mode switch that keeps the slot, the digit that fires is
    ///   the same one the uninterrupted hold would have typed — the numeric
    ///   fallback is shared. The only observable deviation is a mid-hold
    ///   *language* switch, i.e. a 0.7 s two-thumb race on an opt-in feature.
    ///
    /// Closing it would mean cancelling the timer from an `onChange` of the
    /// active mode; it is not worth the extra state for that window.
    private func scheduleLongPress() {
        guard onLongPress != nil else { return }
        let tolerance = tuning.longPressMovementTolerance
        longPress.schedule(after: tuning.longPressDuration) {
            let fired = sequence.isTracking
                && sequence.maxDisplacement <= tolerance
                && onLongPress?() == true
            if fired { trail?.finish(from: trailToken) }
            return fired
        }
    }

    /// Guarantees the touch-down origin `(0,0)` is the first sample.
    ///
    /// Every recorded point is a translation relative to touch-down, so the
    /// true gesture origin is always `(0,0)` — appended first in `onChanged`.
    /// On a long gesture (more samples than the position buffer's capacity)
    /// the ring buffer evicts that origin, leaving a mid-gesture point as
    /// `elements[0]`. Since all start-relative features (maxDisplacement,
    /// returnRatio, dominant angle, circularity) measure from `points.first`,
    /// a lost origin mis-classifies the gesture. When the origin was evicted
    /// (`elements[0] != .zero`), re-anchor it.
    nonisolated static func anchoringOrigin(_ points: [CGPoint]) -> [CGPoint] {
        guard let first = points.first, first != .zero else { return points }
        return [.zero] + points
    }

    // MARK: - Classification (Pure Function)

    /// Classifies a sequence of touch positions into a `GestureType` against a
    /// resolved settings snapshot. The production entry point: pure arithmetic
    /// over `positions`, no store access.
    nonisolated static func classify(
        positions: [CGPoint],
        aspectRatio: CGFloat = 1.0,
        tuning: GestureTuning
    ) -> GestureClassification {
        classify(
            positions: positions,
            config: tuning.config.with(aspectRatio: aspectRatio),
            thresholds: tuning.thresholds
        )
    }

    /// Classifies a sequence of touch positions into a `GestureType`, reading
    /// preprocessor config and thresholds from `SharedDefaults`.
    ///
    /// Kept for tests and tools, which pin classification against whatever the
    /// store holds. The view layer does not call it: each call costs about a
    /// dozen defaults lookups, which is exactly what `GestureTuning` removes
    /// from the touch path.
    nonisolated static func classify(
        positions: [CGPoint],
        aspectRatio: CGFloat = 1.0
    ) -> GestureClassification {
        classify(positions: positions, aspectRatio: aspectRatio, tuning: .load())
    }

    /// Classifies a sequence of touch positions with explicit configuration.
    ///
    /// This is a pure function so it can be unit-tested without rendering
    /// any SwiftUI views and without depending on the shared defaults store.
    nonisolated static func classify(
        positions: [CGPoint],
        config: GesturePreprocessorConfiguration,
        thresholds: GestureClassificationThresholds
    ) -> GestureClassification {
        let preprocessor = GesturePreprocessor(config: config)
        let processed = preprocessor.preprocess(positions)
        let features = GestureFeatures.extract(from: processed, thresholds: thresholds)

        return classify(features: features)
    }

    /// Classifies already-extracted features. Useful for testing with
    /// synthetic feature vectors.
    nonisolated static func classify(features: GestureFeatures) -> GestureClassification {
        // Tap
        if features.isTap {
            return GestureClassification(gesture: .tap, isReturn: false)
        }

        // Circular
        if features.isCircular {
            let gesture: GestureType = features.isClockwise
                ? .circularClockwise
                : .circularCounterclockwise
            return GestureClassification(gesture: gesture, isReturn: false)
        }

        // Directional (swipe or return-swipe)
        let gesture = angleToGestureType(features.maxDisplacementAngle)
        return GestureClassification(
            gesture: gesture,
            isReturn: features.isReturn
        )
    }

    /// Maps an angle (radians, from `atan2`) to the corresponding swipe
    /// `GestureType`.
    nonisolated static func angleToGestureType(_ angle: CGFloat) -> GestureType {
        let normalized = angle < 0 ? angle + 2 * .pi : angle
        return gestureType(forDegrees: normalized * 180 / .pi)
    }

    /// Maps a normalized angle in degrees (`atan2` convention: 0 = right,
    /// 90 = down) to its 45° swipe sector. Every sector owns its lower
    /// boundary and stops short of the next one, so exactly 22.5° is a
    /// down-right swipe; the sector around 0° wraps across both ends of the
    /// range, and anything outside it (including NaN) falls back to right.
    /// Separate from `angleToGestureType` so the boundaries can be tested at
    /// their exact values — the degree/radian round trip is one ulp off for
    /// several of them, which is exactly where the convention lives.
    nonisolated static func gestureType(forDegrees degrees: CGFloat) -> GestureType {
        switch degrees {
        case 337.5 ... 360, 0 ..< 22.5:
            .swipeRight
        case 22.5 ..< 67.5:
            .swipeDownRight
        case 67.5 ..< 112.5:
            .swipeDown
        case 112.5 ..< 157.5:
            .swipeDownLeft
        case 157.5 ..< 202.5:
            .swipeLeft
        case 202.5 ..< 247.5:
            .swipeUpLeft
        case 247.5 ..< 292.5:
            .swipeUp
        case 292.5 ..< 337.5:
            .swipeUpRight
        default:
            .swipeRight
        }
    }
}
