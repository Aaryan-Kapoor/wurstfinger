//
//  GesturePreprocessor.swift
//  Wurstfinger
//
//  Gesture Recognition Pipeline
//  ============================
//
//  This module implements gesture preprocessing and feature extraction for
//  distinguishing between taps, swipes, return-swipes, and circular gestures.
//
//  ## Data Flow
//
//  ```
//  Touch Events (KeyView)
//       │
//       ▼
//  Raw CGPoint[] ──► GesturePreprocessor.preprocess()
//       │                    │
//       │              ┌─────┴─────┐
//       │              ▼           ▼
//       │         filterJitter  filterOutliers
//       │              │           │
//       │              ▼           ▼
//       │         normalizeAspectRatio
//       │              │
//       │              ▼
//       │         smoothSavitzkyGolay
//       │              │
//       ▼              ▼
//  Cleaned CGPoint[] ──► GestureFeatures.extract()
//       │
//       ▼
//  GestureFeatures { pathLength, maxDisplacement, angularSpan, ... }
//       │
//       ▼
//  Classification: isTap, isReturn, isCircular, direction
//  ```
//
//  ## Preprocessing Steps
//
//  1. **Jitter Filter**: Removes points too close together (< jitterThreshold)
//     - Prevents noise from finger micro-movements
//
//  2. **Outlier Filter**: Removes isolated impossible jumps (> maxJumpDistance)
//     - Handles touch glitches and multitouch interference
//     - Keeps points consistent with a raw neighbor, so a single dropped-frame
//       gap cannot cascade and discard the rest of a genuine fast swipe
//     - Velocity-aware: a jump that continues the movement the finger was
//       already making — same direction to within 45°, at most three times
//       the reference step (the longer of the step the accepted path
//       established and the raw step the jump leads into) and never beyond
//       3x maxJumpDistance — is kept, so a flick covering more than
//       maxJumpDistance per sample is not read as a teleport
//
//  3. **Aspect Ratio Normalization**: Divides X by aspect ratio
//     - Makes horizontal and vertical movements comparable on non-square keys
//
//  4. **Savitzky-Golay Smoothing**: Polynomial smoothing filter
//     - Preserves gesture shape while reducing noise
//     - Uses pre-computed coefficients for efficiency
//
//  ## Feature Extraction
//
//  Geometric features extracted from the cleaned path:
//  - `pathLength`: Total distance traveled
//  - `chordLength`: Direct distance from start to end
//  - `maxDisplacement`: Furthest point from start
//  - `maxDisplacementProgress`: Where in path (0-1) max occurred
//  - `returnRatio`: chordLength / pathLength (low = returned to start)
//  - `angularSpan`: Total angle swept around centroid (radians)
//  - `circularity`: How uniform the radii are (0-1)
//  - `pathSeparation`: Distance between mirrored points (early vs late)
//
//  ## Classification Logic
//
//  - **Tap**: maxDisplacement < minSwipeLength (20pt by default)
//  - **Return-swipe**: returnRatio < 0.5 AND maxDisplacement in middle of path
//  - **Circular**: angularSpan > 255° AND consistent turn direction AND enough
//    oriented compactness (a circle, not a narrow arc)
//  - **Swipe**: Everything else, direction from maxDisplacementAngle
//
//  Note: minSwipeLength is an absolute distance, so its share of the key
//  depends on the user's size setting — 20pt is about a third of the ~58pt
//  key height the layout metrics resolve at the default width.
//
//  ## Key Insight: Spiral vs Return-Swipe
//
//  Both can have high angularSpan, but:
//  - Spiral: Early points (start) far from late points (end) → high pathSeparation
//  - Return: Path comes back, early ≈ late points → low pathSeparation
//

import CoreGraphics
import Foundation

// MARK: - Configuration

struct GesturePreprocessorConfiguration: Sendable, Equatable {
    /// Minimum distance between consecutive points (jitter threshold)
    let jitterThreshold: CGFloat
    /// Maximum jump distance to consider valid (outlier threshold)
    let maxJumpDistance: CGFloat
    /// Window size for Savitzky-Golay filter (must be odd)
    let smoothingWindow: Int
    /// Polynomial order for Savitzky-Golay filter
    let smoothingOrder: Int
    /// Aspect ratio of the key (width/height) for normalizing coordinates
    let aspectRatio: CGFloat

    // MARK: - Default Values

    static let defaultJitterThreshold: CGFloat = 3.0
    static let defaultMaxJumpDistance: CGFloat = 50.0
    static let defaultSmoothingWindow: Int = 5

    // MARK: - Value Ranges

    /// The ranges the Expert UI offers, shared with the loaders below so a
    /// stale or foreign store value (an older build's range, a hand-written
    /// default) is clamped instead of reaching the pipeline.
    static let jitterThresholdRange: ClosedRange<Double> = 1 ... 10
    static let maxJumpDistanceRange: ClosedRange<Double> = 20 ... 100
    /// Upper bound is odd on purpose: the loader rounds even windows up.
    static let smoothingWindowRange: ClosedRange<Int> = 3 ... 11

    // MARK: - UserDefaults Keys

    static let jitterThresholdKey = "gesture.jitterThreshold"
    static let maxJumpDistanceKey = "gesture.maxJumpDistance"
    static let smoothingWindowKey = "gesture.smoothingWindow"

    static let `default` = GesturePreprocessorConfiguration(
        jitterThreshold: defaultJitterThreshold,
        maxJumpDistance: defaultMaxJumpDistance,
        smoothingWindow: defaultSmoothingWindow,
        smoothingOrder: 2,
        aspectRatio: 1.0
    )

    /// Loads config from SharedDefaults with fallback to defaults.
    /// Non-finite values (NaN, Inf) are replaced with defaults, out-of-range
    /// ones clamped to the Expert range.
    /// Custom values only apply while expert mode is enabled; when it is off,
    /// the defaults are returned. The stored values are kept so they survive
    /// toggling expert mode off and on again.
    static func fromUserDefaults(store: UserDefaults = SharedDefaults.store) -> GesturePreprocessorConfiguration {
        guard store.bool(forKey: SettingsKey.expertModeEnabled.rawValue) else { return .default }
        let jitter = clampedCGFloat(
            from: store, key: jitterThresholdKey,
            default: defaultJitterThreshold, range: jitterThresholdRange
        )
        let maxJump = clampedCGFloat(
            from: store, key: maxJumpDistanceKey,
            default: defaultMaxJumpDistance, range: maxJumpDistanceRange
        )
        return GesturePreprocessorConfiguration(
            jitterThreshold: jitter,
            maxJumpDistance: maxJump,
            smoothingWindow: validSmoothingWindow(from: store),
            smoothingOrder: 2,
            aspectRatio: 1.0
        )
    }

    /// Reads smoothingWindow from defaults, clamped to the Expert range and
    /// forced to an odd width (the Savitzky-Golay window must be centred).
    private static func validSmoothingWindow(from store: UserDefaults) -> Int {
        let raw = store.object(forKey: smoothingWindowKey) as? Int ?? defaultSmoothingWindow
        let clamped = min(max(raw, smoothingWindowRange.lowerBound), smoothingWindowRange.upperBound)
        return clamped.isMultiple(of: 2) ? clamped + 1 : clamped
    }

    /// Loads a CGFloat from the store, clamped to `range`. A missing key or a
    /// NaN/Inf value falls back to `defaultValue`.
    private static func clampedCGFloat(
        from store: UserDefaults,
        key: String,
        default defaultValue: CGFloat,
        range: ClosedRange<Double>
    ) -> CGFloat {
        guard store.object(forKey: key) != nil else { return defaultValue }
        let value = store.double(forKey: key)
        guard value.isFinite else { return defaultValue }
        return CGFloat(min(max(value, range.lowerBound), range.upperBound))
    }

    /// Creates a config with custom aspect ratio.
    /// Non-finite or non-positive values (the ratio reaches this via a raw
    /// `@AppStorage` read) fall back to 1.0 — `normalizeAspectRatio` divides
    /// by the ratio, and dividing by zero/NaN would poison the whole pipeline
    /// so that every gesture classifies as `.swipeRight`.
    func with(aspectRatio: CGFloat) -> GesturePreprocessorConfiguration {
        GesturePreprocessorConfiguration(
            jitterThreshold: jitterThreshold,
            maxJumpDistance: maxJumpDistance,
            smoothingWindow: smoothingWindow,
            smoothingOrder: smoothingOrder,
            aspectRatio: aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 1.0
        )
    }
}

// MARK: - Gesture Preprocessor

struct GesturePreprocessor {
    let config: GesturePreprocessorConfiguration

    init(config: GesturePreprocessorConfiguration = .default) {
        self.config = config
    }

    /// Main preprocessing pipeline
    func preprocess(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        // Step 4: Savitzky-Golay smoothing, over the cleaned and normalized path.
        return smoothSavitzkyGolay(cleaned(points))
    }

    /// Steps 1-3 of the pipeline: jitter and outlier filtering and aspect
    /// ratio normalization, without the smoothing. The path as the finger
    /// travelled it, which is what a distance measurement wants: smoothing
    /// pulls the end of a path back by a point or two.
    func cleaned(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 2 else { return points }

        // Step 1: Jitter filter
        let dejittered = filterJitter(points)

        // Step 2: Outlier filter
        let filtered = filterOutliers(dejittered)

        // Step 2b: Lone sideways spikes
        let despiked = filterSpikes(filtered)

        // Step 3: Aspect ratio correction (normalize horizontal movement)
        return normalizeAspectRatio(despiked)
    }

    /// Runs a buffer step over an array: `body` reads the input, writes at
    /// most `points.count` elements to the output and returns how many.
    /// The array entry points are wrappers over the buffer ones, so there is
    /// exactly one implementation of every step.
    private func transform(
        _ points: [CGPoint],
        _ body: (UnsafeBufferPointer<CGPoint>, UnsafeMutableBufferPointer<CGPoint>) -> Int
    ) -> [CGPoint] {
        points.withUnsafeBufferPointer { input in
            [CGPoint](unsafeUninitializedCapacity: input.count) { output, count in
                count = body(input, output)
            }
        }
    }

    /// Copies `input` to `output` unchanged — what every step does with a
    /// path too short to filter. Returns the count.
    @inline(__always)
    private func passThrough(
        _ input: UnsafeBufferPointer<CGPoint>, into output: UnsafeMutableBufferPointer<CGPoint>
    ) -> Int {
        for i in 0 ..< input.count {
            output[i] = input[i]
        }
        return input.count
    }

    // MARK: - Step 1: Jitter Filter

    /// Removes points that are too close to the previous point
    func filterJitter(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        return transform(points) { filterJitter($0, into: $1) }
    }

    /// Buffer form of `filterJitter(_:)`: writes the kept points to `output`
    /// (at least `input.count` slots, which the filter can never exceed) and
    /// returns how many. `input` and `output` must not overlap.
    func filterJitter(
        _ points: UnsafeBufferPointer<CGPoint>, into output: UnsafeMutableBufferPointer<CGPoint>
    ) -> Int {
        guard points.count >= 2 else { return passThrough(points, into: output) }

        output[0] = points[0]
        var kept = 1
        var last = points[0]

        for i in 1 ..< points.count {
            let current = points[i]
            if current.distance(to: last) >= config.jitterThreshold {
                output[kept] = current
                kept += 1
                last = current
            }
        }

        // Always include the last point if different from current last
        let lastInput = points[points.count - 1]
        if lastInput.distance(to: last) >= 0.1 {
            output[kept] = lastInput
            kept += 1
        }

        return kept
    }

    // MARK: - Step 2: Outlier Filter

    /// Removes points with physically impossible jumps.
    ///
    /// A point is an outlier only when it is farther than `maxJumpDistance`
    /// from the last accepted point AND from both of its raw neighbors.
    /// Comparing solely against the last accepted point would cascade: one
    /// dropped-frame gap leaves the anchor stuck before the gap, so every
    /// later sample of a genuine fast swipe (or of a re-anchored long drag
    /// whose retained window sits far from the origin) would be discarded
    /// too. Consistency with a raw neighbor proves real motion; the ceiling
    /// below is what stops a ghost cluster from vouching for itself.
    ///
    /// Those criteria all measure *where* a sample landed. The last one
    /// measures *how the finger got there*, and it is the only evidence that
    /// separates the two cases this filter has to tell apart — a touch glitch
    /// and a violent flick land in the same place, but the glitch appears out
    /// of a near-stationary path while the flick is preceded by a finger
    /// already covering that ground every sample. Without it a fling faster
    /// than `maxJumpDistance` per sample had *every* sample discarded and
    /// committed the key's center letter, while the gesture trail — which
    /// draws the raw path — showed the full swipe (review 2026-08-09,
    /// finding 3).
    ///
    /// Accepting a point moves the anchor onto it, so a glitch let in here is
    /// paid for twice: the genuine sample after it is then measured from the
    /// glitch and can fail every criterion. That is why `isSameMovement` is
    /// deliberately narrow — a jump has to continue the reference direction to
    /// within 45° and stay inside three times the reference step.
    ///
    /// The one shape it cannot resolve is a burst of consistently-moving
    /// interference: two samples travelling coherently at flick speed arrive
    /// byte-identical to a finger that accelerated into a flick. How long the
    /// finger rested first would separate them, but the jitter filter has
    /// already collapsed that dwell by the time this filter runs. Because
    /// `continuesEstablishedMotion` takes the longer of its two candidate
    /// references, the ambiguity is uniform along the path instead of confined
    /// to the origin — deliberately, since the established step is no evidence
    /// against a real flick either. Both are accepted; what bounds the damage
    /// is the magnitude ceiling and the direction cone in `isSameMovement`,
    /// not the shape. Separating them needs the pipeline order changed (or the
    /// trail clamped to post-filter samples), which is the structural half of
    /// finding 3 and is not attempted here.
    func filterOutliers(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        return transform(points) { filterOutliers($0, into: $1) }
    }

    /// Buffer form of `filterOutliers(_:)`: `points` is the raw (dejittered)
    /// path the neighbour tests read, `output` receives the accepted points
    /// (at least `points.count` slots) and the return value says how many.
    /// The two must not overlap — the filter keeps reading raw neighbours
    /// after it has written accepted ones.
    func filterOutliers(
        _ points: UnsafeBufferPointer<CGPoint>, into output: UnsafeMutableBufferPointer<CGPoint>
    ) -> Int {
        guard points.count >= 2 else { return passThrough(points, into: output) }

        output[0] = points[0]
        var kept = 1
        // Step between the two most recently accepted samples — the velocity
        // the accepted path has established so far. Nil while the origin is
        // the entire accepted path.
        var acceptedStep: CGVector?

        for i in 1 ..< points.count {
            let lastAccepted = output[kept - 1]
            let current = points[i]

            let step = CGVector(dx: current.x - lastAccepted.x, dy: current.y - lastAccepted.y)
            let distanceToAccepted = current.distance(to: lastAccepted)
            let nearAccepted = distanceToAccepted <= config.maxJumpDistance
            let nearRawPrevious = current.distance(to: points[i - 1]) <= config.maxJumpDistance
            let nearRawNext = i + 1 < points.count &&
                current.distance(to: points[i + 1]) <= config.maxJumpDistance

            // Raw-neighbor support alone can be bootstrapped by a clustered
            // glitch burst: two mutually close ghost points admit each other.
            // Support therefore only counts while the point stays within a
            // plausibility ceiling of the accepted path, unless it belongs to
            // a sustained run of mutually consistent samples (a re-anchored
            // long drag or a genuine post-gap tail keeps moving; a ghost
            // cluster does not).
            let ceiling = config.maxJumpDistance * Self.plausibilityCeilingFactor
            let supportIsPlausible = distanceToAccepted <= ceiling
                || consistentRunLength(in: points, at: i) >= Self.sustainedRunMinimumLength

            if nearAccepted
                || ((nearRawPrevious || nearRawNext) && supportIsPlausible)
                || continuesEstablishedMotion(step, after: acceptedStep, in: points, at: i) {
                output[kept] = current
                kept += 1
                acceptedStep = step
            }
            // Isolated or clustered outlier: skip — and leave `acceptedStep`
            // alone, so a rejected glitch never raises the velocity that would
            // admit the next one. An *accepted* one cannot either: the
            // reference is capped in `isSameMovement`.
        }

        return kept
    }

    /// Raw-neighbor support only counts within this multiple of
    /// `maxJumpDistance` from the accepted path; farther points need a
    /// sustained run instead.
    private static let plausibilityCeilingFactor: CGFloat = 3

    /// A run of at least this many mutually consistent samples counts as
    /// sustained real motion regardless of distance from the accepted path.
    private static let sustainedRunMinimumLength = 3

    /// Length of the run of mutually consistent raw samples containing
    /// index `i` (consecutive neighbors within `maxJumpDistance`).
    private func consistentRunLength(in points: UnsafeBufferPointer<CGPoint>, at i: Int) -> Int {
        var length = 1
        var backward = i
        while backward > 0,
              points[backward].distance(to: points[backward - 1]) <= config.maxJumpDistance {
            length += 1
            backward -= 1
        }
        var forward = i
        while forward + 1 < points.count,
              points[forward].distance(to: points[forward + 1]) <= config.maxJumpDistance {
            length += 1
            forward += 1
        }
        return length
    }

    /// A jump may be this multiple of the step the finger was already
    /// covering — itself capped at `maxJumpDistance`, see `isSameMovement` —
    /// and still count as the same movement.
    ///
    /// Sized against the two regimes it separates. The rule only ever runs for
    /// jumps beyond `maxJumpDistance`, so the reference step is already a
    /// third of that (≈17 pt per sample at the default — a finger crossing two
    /// key heights in about six frames) before anything can be accepted at
    /// all. The cap is what keeps the number meaning something: an accepted
    /// jump becomes the next sample's reference, so without it every
    /// admission would triple the allowance for the one after it and a chain
    /// of ever-longer jumps would walk itself off the key. With it the rule
    /// can never admit more than 3 × `maxJumpDistance` — 150 pt per sample at
    /// the default, ≈1.4 m/s at 60 Hz, about three times the fling it exists
    /// for.
    private static let velocityToleranceFactor: CGFloat = 3

    /// How far a jump may turn away from the reference direction and still
    /// count as the same movement, as a cosine: 45° of *raw* screen turn.
    ///
    /// That is one swipe sector only on square keys. This test runs before
    /// `normalizeAspectRatio`, while the classifier's 45° sectors are measured
    /// after it, so the widest admitted turn opens up with the key's aspect
    /// ratio: 45° raw is 46.7° normalized at the 1.06:1 keys the extension
    /// renders, 52.4° at 1.3:1 and 63.4° at 2:1. Testing direction
    /// post-normalization would close that gap, but it is a behavior change
    /// and not a comment fix, so the number stated here is the raw one.
    ///
    /// A finger that crosses a key in a single frame does not also change
    /// direction in it. The half-plane this replaced — any angle short of a
    /// right angle — admitted a near-perpendicular jump at three times the
    /// reference step, which flipped the committed direction of ordinary fast
    /// swipes carrying one trailing glitch sample (review 2026-08-09).
    private static let minimumDirectionCosine = CGFloat(cos(Double.pi / 4))

    /// Whether the jump onto `points[i]` continues the movement the finger was
    /// already making.
    ///
    /// Two steps can speak for the jump: the one the accepted path has
    /// established (`previousStep`) and the raw one that leads away from
    /// `points[i]`. The reference is whichever of the two is longer.
    ///
    /// Letting the established step win whenever it exists — the rule this
    /// replaced — loses every flick that launches out of a rolling start, a
    /// finger that settles on the key with a slow drift and only then flicks.
    /// The drift establishes a step of a few points, the first fast sample is
    /// more than three times it, and because a rejected sample leaves the
    /// anchor and the reference alone, every sample after it fails the same
    /// way: the classifier only ever sees the drift. Measured over three drift
    /// samples followed by three 80 pt flick samples at the default config,
    /// that starts at roughly 1 pt per sample of drift — below it the jitter
    /// filter still collapses the drift — and never stops. What gets committed
    /// is the key's center letter while the drift is shorter than
    /// `minSwipeLength`, and from about 8 pt per sample a swipe in the
    /// *drift's* direction: a drift running across the flick therefore types a
    /// different letter than the one the finger drew, at any drift rate, since
    /// the cone rejects the turn from drift into flick however fast the drift
    /// was. Taking the longer step fixes the whole band — the flick's own
    /// following step vouches for its first sample.
    ///
    /// Before there is an established step at all — the first sample after
    /// touch-down, where the whole accepted path is the origin — the following
    /// raw step is the only evidence there is anyway: a finger that lands
    /// already moving keeps moving at a comparable rate, whereas a glitch
    /// lands once and stops.
    ///
    /// A trailing jump has no following step, so it is judged against
    /// `previousStep` alone, and only when the accepted path is still just the
    /// origin does it have no evidence at all and stay an outlier. What keeps
    /// a glitch at the end of a tap out is therefore how far it jumped, not
    /// where it sits in the path: a tap establishes a step of a few points and
    /// `isSameMovement` allows three times that, while the glitch is beyond
    /// `maxJumpDistance`. A finger already travelling `maxJumpDistance`/3 per
    /// sample does carry a trailing jump in — deliberately, since the last
    /// sample of a genuine flick is itself one.
    ///
    /// What the longer reference costs is that the origin's ambiguity now
    /// applies along the whole path rather than only at touch-down: two
    /// spurious samples travelling coherently at flick speed are
    /// byte-identical to a finger accelerating into one. The established step
    /// is no evidence against them — a rolling start *is* a slow step followed
    /// by a fast one — so the two cases cannot be told apart here. The shapes this filter was
    /// actually built against are unaffected: a ghost cluster's own step is a
    /// few points, so it establishes no reference to ride in on, and an
    /// out-and-back teleport is opposed to both candidate references and fails
    /// the cone. See `filterOutliers` for what bounds the residue.
    private func continuesEstablishedMotion(
        _ step: CGVector,
        after previousStep: CGVector?,
        in points: UnsafeBufferPointer<CGPoint>,
        at i: Int
    ) -> Bool {
        guard let reference = longerStep(previousStep, followingRawStep(in: points, at: i)) else {
            return false
        }
        return isSameMovement(reference, step)
    }

    /// Whichever of the two candidate references is longer, or the only one
    /// that exists. Nil when neither does — a trailing sample on a path whose
    /// accepted part is still just the origin.
    private func longerStep(_ first: CGVector?, _ second: CGVector?) -> CGVector? {
        guard let first else { return second }
        guard let second else { return first }
        return hypot(first.dx, first.dy) >= hypot(second.dx, second.dy) ? first : second
    }

    /// The raw step leading away from `points[i]`, or nil when it is the last
    /// sample.
    private func followingRawStep(in points: UnsafeBufferPointer<CGPoint>, at i: Int) -> CGVector? {
        guard i + 1 < points.count else { return nil }
        return CGVector(dx: points[i + 1].x - points[i].x, dy: points[i + 1].y - points[i].y)
    }

    /// Two steps belong to one movement when they point the same way to within
    /// `minimumDirectionCosine` and the second does not explode in length.
    ///
    /// The direction test is what rejects an out-and-back teleport, whose two
    /// steps are both long but opposed — a shape that a magnitude comparison
    /// alone would happily accept — and, as a cone rather than a half-plane,
    /// the sideways glitch: past a 45° turn the accepted sample pulls the
    /// max-displacement angle far enough that the swipe can commit out of the
    /// sector the finger was travelling towards.
    ///
    /// The reference is capped at `maxJumpDistance` so that a jump this rule
    /// admits cannot raise the allowance for the next one. A zero-length
    /// reference establishes no direction; the guard says so rather than
    /// leaning on the magnitude test, which happens to reject it too because a
    /// zero budget admits no step.
    ///
    /// The corroboration this asks for is the inverse of the rule it replaced,
    /// and the trade is deliberate. The old filter wanted a raw neighbor
    /// within `maxJumpDistance` and ignored direction; this one wants
    /// direction and ignores neighbors, so a single sample inside the cone is
    /// now trusted on its own evidence. That is what buys the flick rescue,
    /// and it is paid for at the cone's edge: a fast swipe with a short prefix
    /// carrying one trailing glitch just inside 45° commits the neighbouring
    /// sector where the old filter kept the right one — measured at 3 of 960
    /// swept shapes, e.g. two 45 pt steps followed by 120 pt at 40°, which
    /// commits `swipeDownRight` instead of `swipeRight`. A tighter cone would
    /// buy that class back and lose flick rescues in exchange, so the angle
    /// stays where it is; this is a choice about `minimumDirectionCosine`, not
    /// a defect to patch here.
    private func isSameMovement(_ reference: CGVector, _ step: CGVector) -> Bool {
        let referenceLength = hypot(reference.dx, reference.dy)
        let stepLength = hypot(step.dx, step.dy)
        let budget = min(referenceLength, config.maxJumpDistance)
        guard budget > 0, stepLength <= budget * Self.velocityToleranceFactor else { return false }
        return reference.dx * step.dx + reference.dy * step.dy
            >= Self.minimumDirectionCosine * referenceLength * stepLength
    }

    // MARK: - Step 2b: Spike Filter

    /// A lone sample must make the path at least this much (points) longer than
    /// its neighbours' own chord to be called a spike: well above the jitter the
    /// jitter filter already removed, well under the jumps the outlier filter
    /// catches.
    private static let spikeMinimumDetour: CGFloat = 20

    /// The path through a spike's neighbours must run straight on into the
    /// samples beyond them: the turn at each, as a cosine, within 40°.
    fileprivate static let spikeMinimumContinuationCosine = CGFloat(cos(Double.pi * 40 / 180))

    /// Removes lone samples that jump off the path sideways and come straight
    /// back: a digitizer glitch puts the finger a fraction of a key off its line
    /// for one frame — too small for the outlier filter, which only judges jumps
    /// beyond `maxJumpDistance` — and a circle is the shape that cannot afford it:
    /// one such sample breaks its turn count and its circle fit.
    ///
    /// What separates a spike from the shapes that look like one:
    /// - it costs a real detour against its neighbours' chord;
    /// - the path runs *on* through it: into the spike and out of it the same
    ///   way, within 40° (a return swipe's tip turns the path back: its two
    ///   sides are opposed). A fast circle sampled three times a turn also puts a
    ///   sample far off its neighbours' chord, but its path bends at every
    ///   sample and never goes straight on.
    /// The first and last interior samples are judged on the one side they have
    /// (the very first and the release itself are never cut). A spike is cut and
    /// the next sample judged against the repaired path.
    ///
    /// In place; returns the new count.
    func filterSpikes(_ points: UnsafeMutableBufferPointer<CGPoint>) -> Int {
        var count = points.count
        var i = 1
        while i < count - 1 {
            if isSpike(in: points, at: i, count: count) {
                for j in i ..< count - 1 {
                    points[j] = points[j + 1]
                }
                count -= 1
            } else {
                i += 1
            }
        }
        return count
    }

    /// Array form of `filterSpikes(_:)`.
    func filterSpikes(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 4 else { return points }
        var copy = points
        let count = copy.withUnsafeMutableBufferPointer { filterSpikes($0) }
        return Array(copy.prefix(count))
    }

    private func isSpike(in points: UnsafeMutableBufferPointer<CGPoint>, at i: Int, count: Int) -> Bool {
        let a = points[i - 1], c = points[i + 1]
        let chord = CGVector(dx: c.x - a.x, dy: c.y - a.y)
        let length = hypot(chord.dx, chord.dy)
        // The detour through the sample: how much longer the way via it is than
        // the neighbours' own chord. A sideways spike, or one that jumps ahead of
        // its successor and falls back, costs about twice its size.
        let detour = a.distance(to: points[i]) + points[i].distance(to: c) - length
        guard detour >= Self.spikeMinimumDetour else { return false }

        // The path on either side runs the same way: into the spike and out of
        // it. A turn-back (a return swipe's tip) has the two opposed. The first
        // and last interior samples have only one side to look at, and judge on
        // that one: the neighbours' chord against the stretch beyond them.
        let before: CGVector? = i >= 2
            ? CGVector(dx: a.x - points[i - 2].x, dy: a.y - points[i - 2].y) : nil
        let after: CGVector? = i + 2 < count
            ? CGVector(dx: points[i + 2].x - c.x, dy: points[i + 2].y - c.y) : nil
        if let before, let after, !continues(before, into: after, cosine: 0) { return false }
        guard before != nil || after != nil else { return false }
        // When the neighbours are far enough apart to have a direction, it runs
        // along their chord; closer together the chord is noise and only the
        // sides can speak (and both must exist).
        guard length >= 8 else { return before != nil && after != nil }
        if let before, !continues(before, into: chord) { return false }
        if let after, !continues(chord, into: after) { return false }
        return true
    }

    /// Whether `second` carries on from `first` to within the continuation cone.
    private func continues(
        _ first: CGVector, into second: CGVector, cosine: CGFloat = GesturePreprocessor.spikeMinimumContinuationCosine
    ) -> Bool {
        let firstLength = hypot(first.dx, first.dy)
        let secondLength = hypot(second.dx, second.dy)
        guard firstLength > 0, secondLength > 0 else { return false }
        return first.dx * second.dx + first.dy * second.dy >= cosine * firstLength * secondLength
    }

    // MARK: - Step 3: Aspect Ratio Normalization

    /// Normalizes points for non-square aspect ratio
    /// Divides X by aspect ratio so horizontal movement equals vertical movement
    func normalizeAspectRatio(_ points: [CGPoint]) -> [CGPoint] {
        guard config.aspectRatio != 1.0 else { return points }
        var normalized = points
        normalized.withUnsafeMutableBufferPointer { normalizeAspectRatio($0) }
        return normalized
    }

    /// In-place form of `normalizeAspectRatio(_:)`: the pipeline normalises the
    /// outlier filter's output where it lies instead of copying it.
    func normalizeAspectRatio(_ points: UnsafeMutableBufferPointer<CGPoint>) {
        guard config.aspectRatio != 1.0 else { return }
        for i in 0 ..< points.count {
            points[i].x /= config.aspectRatio
        }
    }

    // MARK: - Step 4: Savitzky-Golay Smoothing

    /// Applies Savitzky-Golay filter to smooth the path while preserving shape
    func smoothSavitzkyGolay(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count >= config.smoothingWindow else { return points }
        return transform(points) { smoothSavitzkyGolay($0, into: $1) }
    }

    /// Buffer form of `smoothSavitzkyGolay(_:)`: writes the smoothed path to
    /// `output` (at least `points.count` slots, not overlapping `points`)
    /// and returns the count, which equals the input's. A path shorter than
    /// the window is copied through unsmoothed.
    func smoothSavitzkyGolay(
        _ points: UnsafeBufferPointer<CGPoint>, into output: UnsafeMutableBufferPointer<CGPoint>
    ) -> Int {
        guard points.count >= config.smoothingWindow else { return passThrough(points, into: output) }

        let window = config.smoothingWindow
        let halfWindow = window / 2
        let last = points.count - 1

        // The kernels are constants (`SavitzkyGolayKernel`), never rebuilt;
        // a window without one averages uniformly.
        @inline(__always)
        func convolve(weight: (Int) -> CGFloat) {
            for i in 0 ..< points.count {
                var sumX: CGFloat = 0
                var sumY: CGFloat = 0

                for j in 0 ..< window {
                    let idx = i - halfWindow + j
                    let clampedIdx = max(0, min(last, idx))
                    let w = weight(j)
                    sumX += w * points[clampedIdx].x
                    sumY += w * points[clampedIdx].y
                }

                output[i] = CGPoint(x: sumX, y: sumY)
            }
        }

        if let kernel = SavitzkyGolayKernel.coefficients(windowSize: window, polyOrder: config.smoothingOrder) {
            kernel.withUnsafeBufferPointer { coefficients in
                convolve { coefficients[$0] }
            }
        } else {
            let uniform = CGFloat(1.0 / Double(window))
            convolve { _ in uniform }
        }
        return points.count
    }
}

/// Savitzky-Golay convolution coefficients, computed once.
///
/// The classifier runs on every drag event, so the kernels are `static let`
/// constants: looking one up is a retain, not an allocation, where the code
/// this replaced rebuilt the array with `.map` on every call. The arrays are
/// immutable and `Sendable`, so sharing them needs no isolation.
private enum SavitzkyGolayKernel {
    // Window=5, Order=2: [-3, 12, 17, 12, -3] / 35
    private static let window5: [CGFloat] = [-3, 12, 17, 12, -3].map { CGFloat($0) / 35.0 }
    // Window=7, Order=2: [-2, 3, 6, 7, 6, 3, -2] / 21
    private static let window7: [CGFloat] = [-2, 3, 6, 7, 6, 3, -2].map { CGFloat($0) / 21.0 }
    private static let window9: [CGFloat] = [-21, 14, 39, 54, 59, 54, 39, 14, -21].map { CGFloat($0) / 231.0 }
    private static let window11: [CGFloat] = [-36, 9, 44, 69, 84, 89, 84, 69, 44, 9, -36].map { CGFloat($0) / 429.0 }

    /// The pre-computed kernel for a window, or nil where there is none (any
    /// other window, or a polynomial order above 3) and the caller falls back
    /// to uniform weights — a plain moving average.
    static func coefficients(windowSize: Int, polyOrder: Int) -> [CGFloat]? {
        guard polyOrder <= 3 else { return nil }
        switch windowSize {
        case 5: return window5
        case 7: return window7
        case 9: return window9
        case 11: return window11
        default: return nil
        }
    }
}

// MARK: - Classification Thresholds

struct GestureClassificationThresholds: Sendable, Equatable {
    /// Minimum path length to be considered a swipe (not a tap)
    let minSwipeLength: CGFloat
    /// Maximum return ratio to be considered a return-swipe
    let maxReturnRatio: CGFloat
    /// Range where maxDisplacement should occur for return-swipe (as % of path)
    let returnDisplacementRange: ClosedRange<CGFloat>
    /// Minimum circularity score to be considered circular
    let minCircularity: CGFloat
    /// Minimum angular span (radians) to be considered circular
    let minAngularSpan: CGFloat
    /// Minimum path separation to distinguish spiral from return-swipe
    let minPathSeparation: CGFloat
    /// Minimum turn consistency to be considered circular (1.0 = all same direction)
    let minTurnConsistency: CGFloat
    /// Minimum oriented compactness (width/length) to be considered circular (1.0 = square, 0 = line)
    let minOrientedCompactness: CGFloat
    /// The shortest *fast* stroke that is still a swipe, points on a reference
    /// key (`GestureFeatures.referenceKeyHeight`). A quick flick of 14 pt is a
    /// deliberate flick; a slow drift of the same length is a resting thumb.
    var fastSwipeLength: CGFloat = GestureClassificationThresholds.defaultFastSwipeLength
    /// How fast a stroke shorter than `minSwipeLength` must be to count, points
    /// per second on a reference key.
    var fastSwipeSpeed: CGFloat = GestureClassificationThresholds.defaultFastSwipeSpeed
    /// The largest deviation from a circle, as a fraction of its radius, that
    /// still counts as a circle (`GestureCalculations.circleFitResidual`).
    var maxCircleFitResidual: CGFloat = GestureClassificationThresholds.defaultMaxCircleFitResidual

    // MARK: - Default Values

    static let defaultMinSwipeLength: CGFloat = 20
    static let defaultFastSwipeLength: CGFloat = 12
    static let defaultFastSwipeSpeed: CGFloat = 100
    /// 0.3: a 2:1 ellipse with a thumb's wobble fits a circle to 0.2-0.3; the
    /// flat loop of a return swipe whose way back runs wide of the way out,
    /// 0.3 and more. 0.2 loses one circle in ten, 0.45 admits those loops.
    static let defaultMaxCircleFitResidual: CGFloat = 0.3
    static let defaultMaxReturnRatio: CGFloat = 0.5
    static let defaultReturnDisplacementStart: CGFloat = 0.2
    static let defaultReturnDisplacementEnd: CGFloat = 0.8
    static let defaultMinCircularity: CGFloat = 0.3
    /// 255°, not a full 270: the span is measured around the path's centroid,
    /// which sits off the true centre of an open arc, so a thumb's C-shaped
    /// 270-300° circle measures 245-270° and a good share of the short ones fell
    /// under the line. 255° is where the gesture lab's circles stop being lost
    /// without the returns (whose loops measure over 350°) being let in, and it
    /// stays above what a 200° arc measures (252°). See `GestureLab`.
    static let defaultMinAngularSpan: CGFloat = .pi * 255 / 180
    static let defaultMinPathSeparation: CGFloat = 0.5
    static let defaultMinTurnConsistency: CGFloat = 0.8 // 80% turns in same direction
    /// Width must be at least 45% of length. Raised from 40% with the span: a
    /// return swipe whose way back runs wide of the way out is a thin loop
    /// (compactness 0.40-0.44 in the lab), a circle is rounder.
    static let defaultMinOrientedCompactness: CGFloat = 0.45

    // MARK: - Value Ranges

    /// The ranges the Expert UI offers, shared with the loader below so a
    /// stale or foreign store value (an older build's range, a hand-written
    /// default) is clamped instead of reaching classification.
    static let minSwipeLengthRange: ClosedRange<Double> = 10 ... 60
    static let fastSwipeLengthRange: ClosedRange<Double> = 6 ... 30
    static let fastSwipeSpeedRange: ClosedRange<Double> = 40 ... 400
    static let maxCircleFitResidualRange: ClosedRange<Double> = 0.1 ... 0.8
    static let maxReturnRatioRange: ClosedRange<Double> = 0.2 ... 0.8
    static let returnDisplacementStartRange: ClosedRange<Double> = 0.1 ... 0.4
    static let returnDisplacementEndRange: ClosedRange<Double> = 0.6 ... 0.9
    static let minCircularityRange: ClosedRange<Double> = 0.1 ... 0.7
    static let minAngularSpanRange: ClosedRange<Double> = .pi ... (2 * .pi)
    static let minTurnConsistencyRange: ClosedRange<Double> = 0.5 ... 1.0
    static let minOrientedCompactnessRange: ClosedRange<Double> = 0.2 ... 0.8
    /// No Expert control (the circular branch does not read it); clamped to
    /// the ratio's meaningful band so a stored value cannot be nonsense.
    static let minPathSeparationRange: ClosedRange<Double> = 0 ... 1

    // MARK: - UserDefaults Keys

    static let minSwipeLengthKey = "gesture.minSwipeLength"
    static let fastSwipeLengthKey = "gesture.fastSwipeLength"
    static let fastSwipeSpeedKey = "gesture.fastSwipeSpeed"
    static let maxCircleFitResidualKey = "gesture.maxCircleFitResidual"
    static let maxReturnRatioKey = "gesture.maxReturnRatio"
    static let returnDisplacementStartKey = "gesture.returnDisplacementStart"
    static let returnDisplacementEndKey = "gesture.returnDisplacementEnd"
    static let minCircularityKey = "gesture.minCircularity"
    static let minAngularSpanKey = "gesture.minAngularSpan"
    static let minPathSeparationKey = "gesture.minPathSeparation"
    static let minTurnConsistencyKey = "gesture.minTurnConsistency"
    static let minOrientedCompactnessKey = "gesture.minOrientedCompactness"

    static let `default` = GestureClassificationThresholds(
        minSwipeLength: defaultMinSwipeLength,
        maxReturnRatio: defaultMaxReturnRatio,
        returnDisplacementRange: defaultReturnDisplacementStart ... defaultReturnDisplacementEnd,
        minCircularity: defaultMinCircularity,
        minAngularSpan: defaultMinAngularSpan,
        minPathSeparation: defaultMinPathSeparation,
        minTurnConsistency: defaultMinTurnConsistency,
        minOrientedCompactness: defaultMinOrientedCompactness
    )

    /// Loads a CGFloat from UserDefaults, clamped to `range`. A missing key or
    /// a NaN/Inf value falls back to `defaultValue`.
    private static func clampedCGFloat(
        from store: UserDefaults,
        key: String,
        default defaultValue: CGFloat,
        range: ClosedRange<Double>
    ) -> CGFloat {
        guard store.object(forKey: key) != nil else { return defaultValue }
        let value = store.double(forKey: key)
        guard value.isFinite else { return defaultValue }
        return CGFloat(min(max(value, range.lowerBound), range.upperBound))
    }

    /// Loads thresholds from SharedDefaults with fallback to defaults.
    /// Custom values only apply while expert mode is enabled; when it is off,
    /// the defaults are returned. The stored values are kept so they survive
    /// toggling expert mode off and on again.
    static func fromUserDefaults(store: UserDefaults = SharedDefaults.store) -> GestureClassificationThresholds {
        guard store.bool(forKey: SettingsKey.expertModeEnabled.rawValue) else { return .default }
        let start = clampedCGFloat(
            from: store, key: returnDisplacementStartKey,
            default: defaultReturnDisplacementStart, range: returnDisplacementStartRange
        )
        let end = clampedCGFloat(
            from: store, key: returnDisplacementEndKey,
            default: defaultReturnDisplacementEnd, range: returnDisplacementEndRange
        )
        return GestureClassificationThresholds(
            minSwipeLength: clampedCGFloat(
                from: store, key: minSwipeLengthKey,
                default: defaultMinSwipeLength, range: minSwipeLengthRange
            ),
            maxReturnRatio: clampedCGFloat(
                from: store, key: maxReturnRatioKey,
                default: defaultMaxReturnRatio, range: maxReturnRatioRange
            ),
            returnDisplacementRange: min(start, end) ... max(start, end),
            minCircularity: clampedCGFloat(
                from: store, key: minCircularityKey,
                default: defaultMinCircularity, range: minCircularityRange
            ),
            minAngularSpan: clampedCGFloat(
                from: store, key: minAngularSpanKey,
                default: defaultMinAngularSpan, range: minAngularSpanRange
            ),
            minPathSeparation: clampedCGFloat(
                from: store, key: minPathSeparationKey,
                default: defaultMinPathSeparation, range: minPathSeparationRange
            ),
            minTurnConsistency: clampedCGFloat(
                from: store, key: minTurnConsistencyKey,
                default: defaultMinTurnConsistency, range: minTurnConsistencyRange
            ),
            minOrientedCompactness: clampedCGFloat(
                from: store, key: minOrientedCompactnessKey,
                default: defaultMinOrientedCompactness, range: minOrientedCompactnessRange
            ),
            fastSwipeLength: clampedCGFloat(
                from: store, key: fastSwipeLengthKey,
                default: defaultFastSwipeLength, range: fastSwipeLengthRange
            ),
            fastSwipeSpeed: clampedCGFloat(
                from: store, key: fastSwipeSpeedKey,
                default: defaultFastSwipeSpeed, range: fastSwipeSpeedRange
            ),
            maxCircleFitResidual: clampedCGFloat(
                from: store, key: maxCircleFitResidualKey,
                default: defaultMaxCircleFitResidual, range: maxCircleFitResidualRange
            )
        )
    }
}

// MARK: - Gesture Features

struct GestureFeatures: Sendable {
    /// Thresholds used for classification
    let thresholds: GestureClassificationThresholds

    // Geometric features
    let pathLength: CGFloat
    let chordLength: CGFloat
    let boundingBox: CGRect
    let maxDisplacement: CGFloat
    let maxDisplacementPoint: CGPoint
    let maxDisplacementProgress: CGFloat // 0.0-1.0: where in the path maxDisplacement occurs
    let centroid: CGPoint

    // Ratio features
    let returnRatio: CGFloat // chordLength / pathLength (low = returned to start)
    let aspectRatio: CGFloat // boundingBox width / height

    // Direction features
    let dominantAngle: CGFloat // angle from start to end
    let maxDisplacementAngle: CGFloat // angle from start to max displacement

    // Circularity features
    let angularSpan: CGFloat // total angle traversed (positive = CW, negative = CCW)
    let circularity: CGFloat // how circular (0-1, 1 = perfect circle)
    let pathSeparation: CGFloat // how separated are mirrored points (spiral > 0.5, return < 0.3)
    let turnConsistency: CGFloat // how consistent turn direction is (1.0 = all same direction, 0.5 = half each)
    let orientedCompactness: CGFloat // width/length along principal axis (1.0 = square, 0 = line)

    /// The key the stroke was drawn on, relative to the reference key the
    /// thresholds are stated for (1 when unknown), and how long the finger took
    /// to reach `maxDisplacement` (0 when unknown). Set by `extract`.
    var keyScale: CGFloat = 1
    var peakTime: TimeInterval = 0
    /// How far the path is from the best circle through it (see
    /// `GestureCalculations.circleFitResidual`). Only computed for a path that
    /// already passes every other circle test, so only circles pay for it; 0
    /// otherwise, which is no objection.
    var circleFitResidual: CGFloat = 0

    /// The key height the length thresholds are stated for: a phone at the
    /// default width. A smaller key (an SE, the numpad column) has a shorter
    /// reach, a larger one (an iPad) a longer, and a stroke that is a third of a
    /// key should be a swipe on both.
    static let referenceKeyHeight: CGFloat = 58

    /// How the thresholds scale for `keySize`, clamped so one odd frame cannot
    /// make swipes impossible or free.
    static func keyScale(for keySize: CGSize) -> CGFloat {
        guard keySize.height > 0 else { return 1 }
        return min(max(keySize.height / referenceKeyHeight, 0.7), 1.6)
    }

    /// The shortest stroke that counts as a swipe on this key.
    var swipeLength: CGFloat { thresholds.minSwipeLength * keyScale }

    /// A stroke shorter than `swipeLength` that was nonetheless quick and long
    /// enough to be a flick. Needs the time; without it (0) nothing is fast.
    /// The finger must also have *meant* it: either it ends out there (a chord of
    /// at least 60% of the reach) or it is a sustained out-and-back — a return
    /// swipe, quick and short. One stray sample that jumps away and straight
    /// back is a glitch in a tap, not a stroke; what tells them apart is that a
    /// return swipe spends several samples out near its far point.
    var isFastSwipe: Bool {
        peakTime > 0
            && (chordLength >= 0.6 * maxDisplacement || isSustainedOutAndBack)
            && maxDisplacement >= thresholds.fastSwipeLength * keyScale
            && maxDisplacement >= thresholds.fastSwipeSpeed * keyScale * CGFloat(peakTime)
    }

    /// How many samples of the path lie at least half way out to its farthest
    /// point. A glitch has one; a stroke out and back has several. Set by `extract`.
    var samplesOut: Int = 0

    /// The finger went out and came back (the return-swipe geometry) and spent
    /// at least three samples out there: not a lone glitch.
    private var isSustainedOutAndBack: Bool {
        samplesOut >= 3
            && returnRatio < thresholds.maxReturnRatio
            && thresholds.returnDisplacementRange.contains(maxDisplacementProgress)
    }

    // Derived classifications (using configurable thresholds)
    var isTap: Bool {
        maxDisplacement < swipeLength && !isFastSwipe
    }

    /// Return-swipe: maxDisplacement in the middle of the path (not at the end) AND finger returned to start
    var isReturn: Bool {
        let t = thresholds
        // Must have significant movement
        guard !isTap else { return false }
        // Must have returned close to start (low chord/path ratio)
        guard returnRatio < t.maxReturnRatio else { return false }
        // maxDisplacement should be in the middle of the path, not at the very end
        return t.returnDisplacementRange.contains(maxDisplacementProgress)
    }

    var isCircular: Bool {
        passesCircleGates && circleFitResidual <= thresholds.maxCircleFitResidual
    }

    /// Beyond this much turning (540°, a turn and a half) the circle fit is not
    /// consulted.
    static let fitExemptSpan: CGFloat = .pi * 3

    /// Every circle test but the fit: the cheap ones, which decide whether the
    /// fit is worth computing.
    var passesCircleGates: Bool {
        let t = thresholds
        // Require minimum size (2x swipe length) to avoid small wiggles being detected as circles
        // Also require high turn consistency and compactness to distinguish from return swipes
        // (circle: turns consistently one direction AND is not a narrow arc)
        return pathLength > swipeLength * 2 &&
            circularity > t.minCircularity &&
            abs(angularSpan) > t.minAngularSpan &&
            turnConsistency > t.minTurnConsistency &&
            orientedCompactness > t.minOrientedCompactness
    }

    var isClockwise: Bool {
        angularSpan > 0
    }

    /// Extracts features from preprocessed points.
    /// Uses GestureCalculations helper functions for cleaner, testable code.
    ///
    /// Generic over the path's storage so the engine can hand it a scratch
    /// buffer and tests an array; same-module generics are specialised, so
    /// neither pays for the abstraction.
    static func extract<C: RandomAccessCollection<CGPoint>>(
        from points: C, thresholds: GestureClassificationThresholds = .default,
        keyScale: CGFloat = 1, peakTime: TimeInterval = 0
    ) -> GestureFeatures where C.Index == Int {
        var features = extractFeatures(from: points, thresholds: thresholds)
        features.keyScale = keyScale
        features.peakTime = peakTime
        // Samples at least half way out: what a glitch lacks.
        let half = features.maxDisplacement / 2
        if half > 0, let origin = points.first {
            var out = 0
            for i in 0 ..< points.count where points[i].distance(to: origin) >= half { out += 1 }
            features.samplesOut = out
        }
        // A path that winds one and a half times or more is no return swipe,
        // whatever shape it fits (a spiral fits no circle): the fit is only
        // asked where a flat loop could be mistaken for a circle.
        if features.passesCircleGates, abs(features.angularSpan) < GestureFeatures.fitExemptSpan {
            features.circleFitResidual = GestureCalculations.circleFitResidual(of: points)
        }
        return features
    }

    private static func extractFeatures<C: RandomAccessCollection<CGPoint>>(
        from points: C, thresholds: GestureClassificationThresholds
    ) -> GestureFeatures where C.Index == Int {
        guard points.count >= 2 else {
            return GestureFeatures.empty(thresholds: thresholds)
        }

        let start = points[0]
        let end = points[points.count - 1]

        // Use helper functions from GestureCalculations
        let pathLen = GestureCalculations.pathLength(of: points)
        let chordLen = GestureCalculations.chordLength(of: points)
        let bbox = GestureCalculations.boundingBox(of: points)
        let centroid = GestureCalculations.centroid(of: points)

        // Max displacement analysis
        let maxDispResult = GestureCalculations.maxDisplacement(in: points)
        let maxDisp = maxDispResult.distance
        let maxDispPoint = maxDispResult.point
        let maxDispProgress = maxDispResult.progress

        // Angles (simple calculations, kept inline)
        let dominantAngle = atan2(end.y - start.y, end.x - start.x)
        let maxDispAngle = atan2(maxDispPoint.y - start.y, maxDispPoint.x - start.x)

        // Circularity features using helpers
        let angularSpan = GestureCalculations.angularSpan(of: points, around: centroid)
        let circularity = GestureCalculations.circularity(of: points, centroid: centroid)
        let pathSeparation = GestureCalculations.pathSeparation(of: points, maxDisplacement: maxDisp)
        let turnConsistency = GestureCalculations.turnConsistency(of: points)
        let orientedCompactness = GestureCalculations.orientedCompactness(of: points, principalAngle: maxDispAngle)

        // Derived ratios
        let returnRatio = pathLen > 0 ? chordLen / pathLen : 1
        let bboxAspect = bbox.height > 0 ? bbox.width / bbox.height : 1

        return GestureFeatures(
            thresholds: thresholds,
            pathLength: pathLen,
            chordLength: chordLen,
            boundingBox: bbox,
            maxDisplacement: maxDisp,
            maxDisplacementPoint: maxDispPoint,
            maxDisplacementProgress: maxDispProgress,
            centroid: centroid,
            returnRatio: returnRatio,
            aspectRatio: bboxAspect,
            dominantAngle: dominantAngle,
            maxDisplacementAngle: maxDispAngle,
            angularSpan: angularSpan,
            circularity: circularity,
            pathSeparation: pathSeparation,
            turnConsistency: turnConsistency,
            orientedCompactness: orientedCompactness
        )
    }

    static func empty(thresholds: GestureClassificationThresholds = .default) -> GestureFeatures {
        GestureFeatures(
            thresholds: thresholds,
            pathLength: 0,
            chordLength: 0,
            boundingBox: .zero,
            maxDisplacement: 0,
            maxDisplacementPoint: .zero,
            maxDisplacementProgress: 0,
            centroid: .zero,
            returnRatio: 1,
            aspectRatio: 1,
            dominantAngle: 0,
            maxDisplacementAngle: 0,
            angularSpan: 0,
            circularity: 0,
            pathSeparation: 0,
            turnConsistency: 1,
            orientedCompactness: 0
        )
    }
}

// MARK: - Debug Logging

extension GestureFeatures: CustomStringConvertible {
    var description: String {
        """
        GestureFeatures:
          pathLength: \(String(format: "%.1f", pathLength))
          chordLength: \(String(format: "%.1f", chordLength))
          maxDisplacement: \(String(format: "%.1f", maxDisplacement)) @ \(String(format: "%.0f%%", maxDisplacementProgress * 100))
          returnRatio: \(String(format: "%.2f", returnRatio))
          angularSpan: \(String(format: "%.1f°", angularSpan * 180 / .pi))
          circularity: \(String(format: "%.2f", circularity))
          pathSeparation: \(String(format: "%.2f", pathSeparation))
          turnConsistency: \(String(format: "%.2f", turnConsistency))
          orientedCompactness: \(String(format: "%.2f", orientedCompactness))
          isTap: \(isTap), isReturn: \(isReturn), isCircular: \(isCircular)
        """
    }
}
