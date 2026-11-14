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
    var gesture: GestureType
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

    /// How long after touch-down the finger reached `maxDisplacement`, seconds
    /// (0 when the caller gave no times). The stroke's speed is its reach over
    /// this, not over the whole touch, which may end in a rest: a fast flick
    /// followed by a held thumb is still a fast flick.
    private(set) var peakElapsed: TimeInterval = 0

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

    /// Calls `body` with the origin-anchored path — what `path` returns —
    /// copied into `scratch.path` instead of a fresh array. The origin is
    /// prepended exactly when the ring evicted it (`anchoringOrigin`'s rule).
    /// The scratch is passed in, never stored, so the sequence stays a
    /// `Sendable` value.
    func withOriginAnchoredPath<R>(
        scratch: ClassificationScratch, _ body: (UnsafeBufferPointer<CGPoint>) -> R
    ) -> R {
        let destination = scratch.path
        precondition(
            positions.count < destination.count,
            "scratch is smaller than the position buffer: it needs room for the ring plus the origin"
        )
        guard !positions.isEmpty, let base = destination.baseAddress else {
            return body(UnsafeBufferPointer(start: destination.baseAddress, count: 0))
        }
        // The ring is copied behind slot 0 so the origin can be put in front
        // of it without moving anything.
        let count = positions.copyOrdered(into: UnsafeMutableBufferPointer(start: base + 1, count: positions.count))
        if base[1] == .zero {
            return body(UnsafeBufferPointer(start: base + 1, count: count))
        }
        base[0] = .zero
        return body(UnsafeBufferPointer(start: base, count: count + 1))
    }

    /// Records one `onChanged` sample. Returns true when this sample is the
    /// first contact of a new sequence (touch down).
    mutating func handleChanged(translation: CGSize, elapsed: TimeInterval = 0) -> Bool {
        let isTouchDown = positions.isEmpty
        if isTouchDown {
            positions.append(.zero)
        }
        positions.append(CGPoint(x: translation.width, y: translation.height))
        notePeak(hypot(translation.width, translation.height), at: elapsed)
        return isTouchDown
    }

    private mutating func notePeak(_ distance: CGFloat, at elapsed: TimeInterval) {
        if distance > maxDisplacement {
            maxDisplacement = distance
            peakElapsed = elapsed
        }
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

    /// Records the final sample and classifies the completed sequence through
    /// `scratch` without allocating — the input engine's release path. The
    /// result is identical to `handleEnded(translation:aspectRatio:tuning:keySize:)`,
    /// which classifies the same samples through arrays.
    mutating func handleEnded(
        translation: CGSize,
        aspectRatio: CGFloat,
        tuning: GestureTuning,
        keySize: CGSize = .zero,
        elapsed: TimeInterval = 0,
        scratch: ClassificationScratch
    ) -> GestureClassification {
        defer {
            positions.removeAll()
            maxDisplacement = 0
            peakElapsed = 0
        }
        if positions.isEmpty {
            positions.append(.zero)
        }
        positions.append(CGPoint(x: translation.width, y: translation.height))
        // The release sample may itself be the farthest.
        notePeak(hypot(translation.width, translation.height), at: elapsed)
        let peakTime = peakElapsed
        return withOriginAnchoredPath(scratch: scratch) { path in
            KeyGestureRecognizer.classify(
                path: path,
                config: tuning.config.with(aspectRatio: aspectRatio),
                thresholds: tuning.thresholds,
                keySize: keySize,
                peakTime: peakTime,
                scratch: scratch
            )
        }
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
            peakElapsed = 0
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
        peakElapsed = 0
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
        keySize: CGSize = .zero,
        peakTime: TimeInterval = 0
    ) -> GestureClassification {
        classify(
            positions: positions,
            config: tuning.config.with(aspectRatio: aspectRatio),
            thresholds: tuning.thresholds,
            keySize: keySize,
            peakTime: peakTime
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
        keySize: CGSize = .zero,
        peakTime: TimeInterval = 0
    ) -> GestureClassification {
        // The array entry point is a wrapper over the buffer pipeline, so
        // there is exactly one implementation of it. The scratch it allocates
        // here is the cost of convenience; the engine passes its own.
        let scratch = ClassificationScratch(capacity: positions.count)
        return positions.withUnsafeBufferPointer { path in
            classify(path: path, config: config, thresholds: thresholds, keySize: keySize, peakTime: peakTime, scratch: scratch)
        }
    }

    /// The classification pipeline over a path in a buffer, allocation-free:
    /// every step works in `scratch`.
    ///
    /// Data flow, with the buffer each step reads and writes:
    /// jitter filter `path → a`; outlier filter `a → b` (it needs the raw,
    /// dejittered neighbours in `a` while it writes the accepted points to
    /// `b`); spike filter and aspect normalisation in place on `b`; displacement in keys read
    /// from `b`; Savitzky-Golay `b → a`; feature extraction over `a`.
    ///
    /// `path` must be origin-anchored (see `anchoringOrigin`) and no longer
    /// than `scratch.pathCapacity`; it may live in `scratch.path`, but not in
    /// `a` or `b`.
    nonisolated static func classify(
        path: UnsafeBufferPointer<CGPoint>,
        config: GesturePreprocessorConfiguration,
        thresholds: GestureClassificationThresholds,
        keySize: CGSize = .zero,
        peakTime: TimeInterval = 0,
        scratch: ClassificationScratch
    ) -> GestureClassification {
        precondition(path.count <= scratch.pathCapacity, "path is longer than the scratch it is classified in")
        let preprocessor = GesturePreprocessor(config: config)

        // Too short to filter: the preprocessor passes it through untouched.
        guard path.count >= 2 else {
            return finish(processed: path, cleaned: path, config: config, thresholds: thresholds, keySize: keySize, peakTime: peakTime)
        }

        let a = scratch.a
        let b = scratch.b

        // Steps 1-3: jitter, outliers, aspect ratio.
        let dejitteredCount = preprocessor.filterJitter(path, into: a)
        let dejittered = UnsafeBufferPointer(start: a.baseAddress, count: dejitteredCount)
        let outlierFreeCount = preprocessor.filterOutliers(dejittered, into: b)
        // Lone sideways spikes, cut from `b` in place.
        let cleanedCount = preprocessor.filterSpikes(
            UnsafeMutableBufferPointer(start: b.baseAddress, count: outlierFreeCount)
        )
        let cleanedPath = UnsafeMutableBufferPointer(start: b.baseAddress, count: cleanedCount)
        preprocessor.normalizeAspectRatio(cleanedPath)
        let cleaned = UnsafeBufferPointer(start: b.baseAddress, count: cleanedCount)

        // Step 4: smoothing, only for a path with something to smooth.
        guard cleanedCount >= 2 else {
            return finish(processed: cleaned, cleaned: cleaned, config: config, thresholds: thresholds, keySize: keySize, peakTime: peakTime)
        }
        let smoothedCount = preprocessor.smoothSavitzkyGolay(cleaned, into: a)
        let smoothed = UnsafeBufferPointer(start: a.baseAddress, count: smoothedCount)
        return finish(processed: smoothed, cleaned: cleaned, config: config, thresholds: thresholds, keySize: keySize, peakTime: peakTime)
    }

    /// Features, verdict and displacement from a processed path and its
    /// cleaned (unsmoothed) original.
    @inline(__always)
    private nonisolated static func finish(
        processed: UnsafeBufferPointer<CGPoint>,
        cleaned: UnsafeBufferPointer<CGPoint>,
        config: GesturePreprocessorConfiguration,
        thresholds: GestureClassificationThresholds,
        keySize: CGSize,
        peakTime: TimeInterval
    ) -> GestureClassification {
        let features = GestureFeatures.extract(
            from: processed, thresholds: thresholds,
            keyScale: GestureFeatures.keyScale(for: keySize), peakTime: peakTime
        )
        var classification = classify(features: features)
        // A swipe's direction is read from the body of the stroke rather than its
        // farthest point (`GestureCalculations.robustDirection`); taps and
        // circles never pay for it.
        if classification.gesture.isSwipe, processed.count >= 3 {
            let farthest = Int((features.maxDisplacementProgress * CGFloat(processed.count - 1)).rounded())
            if let angle = GestureCalculations.robustDirection(of: processed, farthest: farthest) {
                classification.gesture = angleToGestureType(angle)
            }
        }
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
    nonisolated static func displacementInKeys<C: RandomAccessCollection<CGPoint>>(
        of cleaned: C, aspectRatio: CGFloat, keySize: CGSize
    ) -> CGVector where C.Index == Int {
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
        // Circular first: a small circle's farthest point from where it began
        // can be under the swipe length (a 30 x 16 pt ellipse reads as a tap by
        // displacement alone), yet it has walked more than twice that length,
        // and no tap does — a tap's path is a few points of drift. `isCircular`
        // demands that length, a full turn and a steady direction on top.
        if features.isCircular {
            let gesture: GestureType = features.isClockwise
                ? .circularClockwise
                : .circularCounterclockwise
            return GestureClassification(gesture: gesture, isReturn: false)
        }

        // Tap
        if features.isTap {
            return GestureClassification(gesture: .tap, isReturn: false)
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
