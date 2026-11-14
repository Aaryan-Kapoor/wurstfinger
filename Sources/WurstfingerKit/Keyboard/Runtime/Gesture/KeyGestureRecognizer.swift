//
//  KeyGestureRecognizer.swift
//  Wurstfinger
//
//  Gesture classification: touch paths into GestureType values, using the
//  preprocessing and feature-extraction pipeline.
//

import CoreGraphics
import Foundation
import SwiftUI

/// Result of classifying a completed gesture.
struct GestureClassification: Sendable {
    let gesture: GestureType
    let isReturn: Bool

    /// Where the finger ended, relative to where it landed, in key sizes:
    /// x in key widths, y in key heights, so a flick across a whole key reads
    /// 1.0 on its axis whatever the key's shape. Zero when the classifier was
    /// not told the key's size. Long swipes are decided from this
    /// (`LongSwipeConfiguration.action(for:)`).
    var displacementInKeys: CGVector = .zero
}

/// One finger's touch-sequence state on a flick key (see `TouchEngine`).
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

    /// The path recorded so far, origin-anchored like the one `handleEnded`
    /// classifies — what the input engine classifies speculatively while the
    /// finger is still moving.
    var path: [CGPoint] {
        KeyGestureRecognizer.anchoringOrigin(positions.elements)
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
    ///
    /// `keySize` is the key's rendered size in points; with it the result
    /// carries the finger's displacement in key sizes (see
    /// `GestureClassification.displacementInKeys`).
    mutating func handleEnded(
        translation: CGSize,
        aspectRatio: CGFloat,
        tuning: GestureTuning,
        keySize: CGSize = .zero
    ) -> GestureClassification {
        let samples = recordFinalSample(translation: translation)
        return KeyGestureRecognizer.classify(
            positions: samples, aspectRatio: aspectRatio, tuning: tuning, keySize: keySize
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

/// Gesture classification: turns a completed (or in-flight) touch path into a
/// `GestureType`, wrapping the `GesturePreprocessor` + `GestureFeatures`
/// pipeline.
///
/// A namespace of pure, `nonisolated` functions in the value domain: the input
/// engine (`TouchEngine`) calls them on the main actor between touch events,
/// but nothing here depends on an isolation domain. (This used to be the
/// per-key SwiftUI `ViewModifier` that owned a `DragGesture`; the engine
/// replaced that, and the classification it wrapped lives on here.)
enum KeyGestureRecognizer {
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
    ///
    /// `keySize` (points) is only needed for the displacement in key sizes the
    /// result carries; leave it `.zero` where long swipes are not in play.
    nonisolated static func classify(
        positions: [CGPoint],
        aspectRatio: CGFloat = 1.0,
        tuning: GestureTuning,
        keySize: CGSize = .zero
    ) -> GestureClassification {
        classify(
            positions: positions,
            config: tuning.config.with(aspectRatio: aspectRatio),
            thresholds: tuning.thresholds,
            keySize: keySize
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
        thresholds: GestureClassificationThresholds,
        keySize: CGSize = .zero
    ) -> GestureClassification {
        let preprocessor = GesturePreprocessor(config: config)
        let cleaned = preprocessor.cleaned(positions)
        let processed = cleaned.count >= 2 ? preprocessor.smoothSavitzkyGolay(cleaned) : cleaned
        let features = GestureFeatures.extract(from: processed, thresholds: thresholds)

        var classification = classify(features: features)
        classification.displacementInKeys = displacementInKeys(
            of: cleaned, aspectRatio: config.aspectRatio, keySize: keySize
        )
        return classification
    }

    /// Where a cleaned (aspect-normalised, unsmoothed) path ends relative to
    /// where it began, in key sizes. The preprocessor divided x by the aspect
    /// ratio, so it is multiplied back here before dividing by the key's width.
    /// Unsmoothed on purpose: the live check that tints the trail judges the
    /// raw finger position, and a release must agree with it.
    nonisolated static func displacementInKeys(
        of cleaned: [CGPoint], aspectRatio: CGFloat, keySize: CGSize
    ) -> CGVector {
        guard let first = cleaned.first, let last = cleaned.last,
              keySize.width > 0, keySize.height > 0
        else { return .zero }
        return CGVector(
            dx: (last.x - first.x) * aspectRatio / keySize.width,
            dy: (last.y - first.y) / keySize.height
        )
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
