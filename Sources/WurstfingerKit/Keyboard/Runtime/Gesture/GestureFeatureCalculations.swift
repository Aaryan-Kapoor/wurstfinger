//
//  GestureFeatureCalculations.swift
//  Wurstfinger
//
//  Helper functions for gesture feature extraction.
//  Extracted from GestureFeatures.extract() to improve readability and testability.
//

import CoreGraphics

// MARK: - Gesture Feature Calculation Helpers

/// Namespace for gesture feature calculation functions.
/// These are pure functions that take input and return a result,
/// making them easy to test in isolation.
///
/// Every function is generic over the path's storage (`[CGPoint]` for tests
/// and tools, `UnsafeBufferPointer<CGPoint>` for the input engine's scratch
/// arena) and works in passes over it, so none builds an intermediate array.
/// They live in the same module as their callers, so the optimizer
/// specialises them per storage type.
enum GestureCalculations {
    // MARK: - Path Metrics

    /// Calculates the total path length (sum of distances between consecutive points)
    static func pathLength<C: RandomAccessCollection<CGPoint>>(of points: C) -> CGFloat where C.Index == Int {
        guard points.count >= 2 else { return 0 }

        var length: CGFloat = 0
        for i in 1 ..< points.count {
            length += points[i - 1].distance(to: points[i])
        }
        return length
    }

    /// Calculates the chord length (direct distance from start to end)
    static func chordLength<C: RandomAccessCollection<CGPoint>>(of points: C) -> CGFloat where C.Index == Int {
        guard let first = points.first, let last = points.last else { return 0 }
        return first.distance(to: last)
    }

    /// Finds the bounding box of a set of points
    static func boundingBox<C: RandomAccessCollection<CGPoint>>(of points: C) -> CGRect where C.Index == Int {
        guard let first = points.first else { return .zero }

        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y

        for i in 1 ..< points.count {
            let point = points[i]
            if point.x < minX { minX = point.x } else if point.x > maxX { maxX = point.x }
            if point.y < minY { minY = point.y } else if point.y > maxY { maxY = point.y }
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Calculates the centroid (geometric center) of a set of points
    static func centroid<C: RandomAccessCollection<CGPoint>>(of points: C) -> CGPoint where C.Index == Int {
        guard !points.isEmpty else { return .zero }

        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        for i in 0 ..< points.count {
            sumX += points[i].x
            sumY += points[i].y
        }

        return CGPoint(
            x: sumX / CGFloat(points.count),
            y: sumY / CGFloat(points.count)
        )
    }

    // MARK: - Displacement Analysis

    /// Result of max displacement calculation
    struct MaxDisplacementResult: Sendable {
        let distance: CGFloat
        let point: CGPoint
        let index: Int
        /// Progress (0.0-1.0) indicating where in the path the max occurred
        let progress: CGFloat
    }

    /// Finds the point with maximum displacement from the start
    static func maxDisplacement<C: RandomAccessCollection<CGPoint>>(in points: C) -> MaxDisplacementResult where C.Index == Int {
        guard let start = points.first, points.count >= 2 else {
            return MaxDisplacementResult(distance: 0, point: .zero, index: 0, progress: 0)
        }

        var maxDist: CGFloat = 0
        var maxPoint = start
        var maxIndex = 0

        for index in 0 ..< points.count {
            let point = points[index]
            let dist = start.distance(to: point)
            if dist > maxDist {
                maxDist = dist
                maxPoint = point
                maxIndex = index
            }
        }

        let progress = CGFloat(maxIndex) / CGFloat(points.count - 1)

        return MaxDisplacementResult(
            distance: maxDist,
            point: maxPoint,
            index: maxIndex,
            progress: progress
        )
    }

    // MARK: - Angular Analysis

    /// Calculates the total angular span around the centroid
    /// Positive = clockwise, Negative = counterclockwise
    static func angularSpan<C: RandomAccessCollection<CGPoint>>(of points: C, around centroid: CGPoint) -> CGFloat where C.Index == Int {
        guard points.count >= 2 else { return 0 }

        var totalAngle: CGFloat = 0

        for i in 1 ..< points.count {
            let prev = Vector2D(point: points[i - 1], relativeTo: centroid)
            let curr = Vector2D(point: points[i], relativeTo: centroid)
            totalAngle += prev.angle(to: curr)
        }

        return totalAngle
    }

    // MARK: - Direction

    /// How far from the origin a path may stray before it counts as having left
    /// the touch-down settle: the finger lands, rocks a few points, then goes.
    private static let settleRadius: CGFloat = 5

    /// The direction a stroke was *aimed*, in radians (`atan2` convention),
    /// from three views of its outward leg that fail in different ways, or `nil`
    /// when the leg is too short to judge.
    ///
    /// The farthest point from the origin — the one direction read before — is
    /// the stroke's end, and the end is where a thumb lies: a lift-off flick
    /// swings it sideways, an overshoot carries it past, and on a return swipe
    /// it is the turn, rounded off by the sideways way back. The aim is better
    /// read from the stroke's body:
    /// - the farthest point itself (right when the stroke is clean);
    /// - the principal axis of the cruise (15%-90% of the arc length out to the
    ///   farthest point), which neither end can bend;
    /// - the chord from where the finger left the touch-down settle to the point
    ///   85% of the way along, which drops both the landing rock and the
    ///   lift-off.
    /// Their unit vectors are averaged. In the gesture lab the three together
    /// beat any one on every sloppiness profile (hooks, bow, boundary aims,
    /// return swipes), where a single estimator wins one and loses another.
    ///
    /// A pass over the outward leg per estimator and no allocation.
    static func robustDirection<C: RandomAccessCollection<CGPoint>>(
        of points: C, farthest f: Int
    ) -> CGFloat? where C.Index == Int {
        guard f >= 2, f < points.count else { return nil }
        let origin = points[0]
        let far = points[f]

        var total: CGFloat = 0
        for i in 1 ... f { total += points[i - 1].distance(to: points[i]) }
        guard total > 0 else { return nil }

        // 1. The farthest point.
        var sumX = cos(atan2(far.y - origin.y, far.x - origin.x))
        var sumY = sin(atan2(far.y - origin.y, far.x - origin.x))

        // 2. Principal axis of the cruise, from the polyline's continuous
        // second moments over its arc-length window.
        let lower = 0.15 * total
        let upper = 0.9 * total
        var weight: CGFloat = 0
        var mx: CGFloat = 0, my: CGFloat = 0
        var mxx: CGFloat = 0, myy: CGFloat = 0, mxy: CGFloat = 0
        var walked: CGFloat = 0
        for i in 1 ... f {
            let a = points[i - 1], b = points[i]
            let length = a.distance(to: b)
            let t0 = length > 0 ? min(max((lower - walked) / length, 0), 1) : 0
            let t1 = length > 0 ? min(max((upper - walked) / length, 0), 1) : 0
            walked += length
            guard t1 > t0 else { continue }
            let p = CGPoint(x: a.x + (b.x - a.x) * t0, y: a.y + (b.y - a.y) * t0)
            let q = CGPoint(x: a.x + (b.x - a.x) * t1, y: a.y + (b.y - a.y) * t1)
            let l = (t1 - t0) * length
            weight += l
            mx += l * (p.x + q.x) / 2
            my += l * (p.y + q.y) / 2
            mxx += l * (p.x * p.x + p.x * q.x + q.x * q.x) / 3
            myy += l * (p.y * p.y + p.y * q.y + q.y * q.y) / 3
            mxy += l * (2 * p.x * p.y + p.x * q.y + q.x * p.y + 2 * q.x * q.y) / 6
        }
        if weight > 0 {
            let cx = mx / weight, cy = my / weight
            let cxx = mxx / weight - cx * cx
            let cyy = myy / weight - cy * cy
            let cxy = mxy / weight - cx * cy
            var theta = 0.5 * atan2(2 * cxy, cxx - cyy)
            // The axis has no sense: point it the way the stroke went.
            if cos(theta) * (far.x - origin.x) + sin(theta) * (far.y - origin.y) < 0 { theta += .pi }
            sumX += cos(theta)
            sumY += sin(theta)
        }

        // 3. Settle to 85%.
        var settled = 0
        while settled < f - 1, origin.distance(to: points[settled + 1]) < settleRadius { settled += 1 }
        let from = points[settled]
        let target = 0.85 * total
        var along: CGFloat = 0
        var end = far
        for i in 1 ... f {
            let length = points[i - 1].distance(to: points[i])
            if along + length >= target, length > 0 {
                let t = (target - along) / length
                end = CGPoint(
                    x: points[i - 1].x + (points[i].x - points[i - 1].x) * t,
                    y: points[i - 1].y + (points[i].y - points[i - 1].y) * t
                )
                break
            }
            along += length
        }
        let settledAngle = atan2(end.y - from.y, end.x - from.x)
        sumX += cos(settledAngle)
        sumY += sin(settledAngle)

        return atan2(sumY, sumX)
    }

    // MARK: - Circle fit

    /// How far a path strays from the best circle through it, as a fraction of
    /// that circle's radius: the root-mean-square radial error of the algebraic
    /// (Kåsa) fit. 0 is a circle; a thin loop, a U-bend or a figure of eight fit
    /// no circle and score high; an ellipse of 2:1 scores about 0.2.
    ///
    /// The angular span, turn count and compactness each look at one thing; this
    /// looks at the whole shape, and is what separates a circle from a return
    /// swipe whose way back runs wide of the way out — both sweep a full turn,
    /// but the loop is a flat ellipse. The gesture lab: returns read as circles
    /// fell by two thirds with no circle lost. Returns 1 when no circle fits
    /// (collinear points).
    ///
    /// One pass for the sums and one for the residual; 3×3 solved in closed form.
    static func circleFitResidual<C: RandomAccessCollection<CGPoint>>(of points: C) -> CGFloat where C.Index == Int {
        let n = CGFloat(points.count)
        guard points.count >= 4 else { return 1 }
        let c = centroid(of: points)

        // Normal equations of min Σ (x² + y² + D·x + E·y + F)² on centred points.
        var sxx: CGFloat = 0, sxy: CGFloat = 0, syy: CGFloat = 0, sx: CGFloat = 0, sy: CGFloat = 0
        var bx: CGFloat = 0, by: CGFloat = 0, b1: CGFloat = 0
        for i in 0 ..< points.count {
            let x = points[i].x - c.x, y = points[i].y - c.y
            let z = -(x * x + y * y)
            sxx += x * x; sxy += x * y; syy += y * y; sx += x; sy += y
            bx += x * z; by += y * z; b1 += z
        }
        // | sxx sxy sx |   | D |   | bx |
        // | sxy syy sy | · | E | = | by |
        // | sx  sy  n  |   | F |   | b1 |
        let det = sxx * (syy * n - sy * sy) - sxy * (sxy * n - sy * sx) + sx * (sxy * sy - syy * sx)
        guard abs(det) > 1e-9 else { return 1 }
        let d = (bx * (syy * n - sy * sy) - sxy * (by * n - sy * b1) + sx * (by * sy - syy * b1)) / det
        let e = (sxx * (by * n - sy * b1) - bx * (sxy * n - sy * sx) + sx * (sxy * b1 - by * sx)) / det
        let f = (sxx * (syy * b1 - sy * by) - sxy * (sxy * b1 - by * sx) + bx * (sxy * sy - syy * sx)) / det

        let ox = -d / 2, oy = -e / 2
        let r2 = ox * ox + oy * oy - f
        guard r2 > 1e-9 else { return 1 }
        let r = r2.squareRoot()
        var error: CGFloat = 0
        for i in 0 ..< points.count {
            let x = points[i].x - c.x - ox, y = points[i].y - c.y - oy
            let delta = (x * x + y * y).squareRoot() - r
            error += delta * delta
        }
        return (error / n).squareRoot() / r
    }

    // MARK: - Circularity Analysis

    /// Calculates how circular a path is (0-1, where 1 = perfect circle)
    /// Based on coefficient of variation of radii from centroid
    static func circularity<C: RandomAccessCollection<CGPoint>>(of points: C, centroid: CGPoint) -> CGFloat where C.Index == Int {
        guard !points.isEmpty else { return 0 }

        // Two passes over the points (mean radius, then variance) instead of
        // materialising the radii: the distance is recomputed, not stored.
        let count = CGFloat(points.count)
        var radiusSum: CGFloat = 0
        for i in 0 ..< points.count {
            radiusSum += points[i].distance(to: centroid)
        }
        let meanRadius = radiusSum / count

        guard meanRadius > 0 else { return 0 }

        var varianceSum: CGFloat = 0
        for i in 0 ..< points.count {
            let diff = points[i].distance(to: centroid) - meanRadius
            varianceSum += diff * diff
        }

        let stdDev = sqrt(varianceSum / count)
        let coefficientOfVariation = stdDev / meanRadius

        // Invert and clamp to 0-1 range
        return max(0, min(1, 1 - coefficientOfVariation))
    }

    /// Calculates path separation (how far apart mirrored points are)
    /// High value = spiral, Low value = return swipe
    static func pathSeparation<C: RandomAccessCollection<CGPoint>>(of points: C, maxDisplacement: CGFloat) -> CGFloat where C.Index == Int {
        guard points.count >= 2, maxDisplacement > 0 else { return 0 }

        let comparisons = min(points.count / 2, 10)
        guard comparisons > 0 else { return 0 }

        var mirrorDistanceSum: CGFloat = 0
        for i in 0 ..< comparisons {
            let earlyPoint = points[i]
            let latePoint = points[points.count - 1 - i]
            mirrorDistanceSum += earlyPoint.distance(to: latePoint)
        }

        let avgMirrorDistance = mirrorDistanceSum / CGFloat(comparisons)
        return avgMirrorDistance / maxDisplacement
    }

    /// A path of more samples than this is dense enough for the digitizer's own
    /// spacing to matter, and `turnConsistency` reads it resampled.
    private static let turnDenseSampleCount = 16

    /// How many equal steps a dense path is resampled to, at most, and the
    /// closest two resampled points may sit.
    private static let turnResampleSteps: CGFloat = 24
    private static let turnResampleMinimumSpacing: CGFloat = 4

    /// Tallies the direction of each turn along a stream of points. Consecutive
    /// duplicates are skipped as the points arrive; a repeated point (A→B→B→C)
    /// would otherwise split the real A→B / B→C turn across two zero-length
    /// segments and never count it. Only the last two distinct points are kept —
    /// the turn at `corner` needs its predecessor and successor, nothing older.
    private struct TurnTally {
        var previous: CGPoint?
        var corner: CGPoint?
        var cwCount = 0
        var ccwCount = 0
        let turnThreshold: CGFloat

        mutating func add(_ p: CGPoint) {
            if let current = corner, current == p { return }
            if let before = previous, let current = corner {
                let v1 = Vector2D(from: before, to: current)
                let v2 = Vector2D(from: current, to: p)
                // Skip degenerate segments — turn angle is undefined for zero length.
                if v1.magnitudeSquared > 0, v2.magnitudeSquared > 0 {
                    let turn = v1.angle(to: v2) // signed radians: + = CCW, - = CW
                    if turn > turnThreshold {
                        ccwCount += 1
                    } else if turn < -turnThreshold {
                        cwCount += 1
                    }
                }
            }
            previous = corner
            corner = p
        }

        /// The share of turns that went the majority way; 1 when none turned.
        var consistency: CGFloat {
            let totalTurns = cwCount + ccwCount
            guard totalTurns > 0 else { return 1.0 }
            return CGFloat(max(cwCount, ccwCount)) / CGFloat(totalTurns)
        }
    }

    /// Calculates turn consistency (how consistently the path turns in one direction)
    /// 1.0 = all turns same direction (circle), ~0.5 = mixed directions (return swipe)
    ///
    /// A dense path (more than `turnDenseSampleCount` samples) is read
    /// resampled at equal arc-length steps rather than as it arrived. The
    /// samples' spacing is the digitizer's, not the gesture's: a slow circle on
    /// a 120 Hz display has steps of a point or two, where a tenth of a point of
    /// tremor is a turn of several degrees, so a third of a clean circle's turns
    /// went the wrong way and it failed the 80% test. At two dozen steps the same
    /// tremor moves a step's angle by a few degrees against ~15° of real
    /// turning, which is what the threshold was meant to see. (The gesture lab
    /// measured it: circles drawn at 120 Hz lost two points of accuracy to this.)
    /// A path of a handful of samples is already as coarse as that, and is
    /// counted exactly as it was given.
    ///
    /// `turnThreshold` is the minimum turn **angle** in radians (default ~8.6°)
    /// for a segment pair to count as a turn. Using the angle keeps the cutoff
    /// scale-invariant; a raw cross product has magnitude `|v1||v2|sin θ` (px²),
    /// so a fixed cross threshold would make the effective angle depend on
    /// segment length (large gestures count nearly every wobble, tiny ones none).
    static func turnConsistency<C: RandomAccessCollection<CGPoint>>(
        of points: C, turnThreshold: CGFloat = 0.15
    ) -> CGFloat where C.Index == Int {
        var tally = TurnTally(turnThreshold: turnThreshold)
        guard points.count > turnDenseSampleCount else {
            for i in 0 ..< points.count { tally.add(points[i]) }
            return tally.consistency
        }

        let spacing = max(pathLength(of: points) / turnResampleSteps, turnResampleMinimumSpacing)
        // Walk the polyline, emitting a point every `spacing` of arc length.
        tally.add(points[0])
        var walked: CGFloat = 0
        for i in 1 ..< points.count {
            var from = points[i - 1]
            let to = points[i]
            var remaining = from.distance(to: to)
            while walked + remaining >= spacing {
                let t = (spacing - walked) / remaining
                let next = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                tally.add(next)
                from = next
                remaining = from.distance(to: to)
                walked = 0
            }
            walked += remaining
        }
        return tally.consistency
    }

    /// Calculates oriented compactness (width/length along principal axis)
    /// 1.0 = square, 0 = narrow line
    static func orientedCompactness<C: RandomAccessCollection<CGPoint>>(of points: C, principalAngle: CGFloat) -> CGFloat where C.Index == Int {
        guard let start = points.first else { return 0 }

        let cosA = cos(principalAngle)
        let sinA = sin(principalAngle)

        var minPara: CGFloat = 0, maxPara: CGFloat = 0
        var minPerp: CGFloat = 0, maxPerp: CGFloat = 0

        for i in 0 ..< points.count {
            let p = points[i]
            let dx = p.x - start.x
            let dy = p.y - start.y

            // Project onto principal axis (parallel) and perpendicular axis
            let para = dx * cosA + dy * sinA
            let perp = -dx * sinA + dy * cosA

            minPara = min(minPara, para)
            maxPara = max(maxPara, para)
            minPerp = min(minPerp, perp)
            maxPerp = max(maxPerp, perp)
        }

        let axisLength = maxPara - minPara
        let axisWidth = maxPerp - minPerp

        guard axisLength > 0 else { return 0 }
        return axisWidth / axisLength
    }
}

// Note: CGPoint extensions (distance, magnitude, asVector) are defined in GeometryExtensions.swift
// Note: Vector2D type is defined in Vector2D.swift
