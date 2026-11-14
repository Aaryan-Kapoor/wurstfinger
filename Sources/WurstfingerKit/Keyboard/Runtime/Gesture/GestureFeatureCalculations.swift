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

    /// Calculates turn consistency (how consistently the path turns in one direction)
    /// 1.0 = all turns same direction (circle), ~0.5 = mixed directions (return swipe)
    ///
    /// `turnThreshold` is the minimum turn **angle** in radians (default ~8.6°)
    /// for a segment pair to count as a turn. Using the angle keeps the cutoff
    /// scale-invariant; a raw cross product has magnitude `|v1||v2|sin θ` (px²),
    /// so a fixed cross threshold would make the effective angle depend on
    /// segment length (large gestures count nearly every wobble, tiny ones none).
    static func turnConsistency<C: RandomAccessCollection<CGPoint>>(
        of points: C, turnThreshold: CGFloat = 0.15
    ) -> CGFloat where C.Index == Int {
        // Consecutive duplicate samples are skipped as the points stream by; a
        // repeated point (A→B→B→C) would otherwise split the real A→B / B→C
        // turn across two zero-length segments and never count it. Only the
        // last two distinct points are kept — the turn at `corner` needs its
        // predecessor and successor, and nothing older.
        var previous: CGPoint?
        var corner: CGPoint?

        var cwCount = 0
        var ccwCount = 0

        for i in 0 ..< points.count {
            let p = points[i]
            if let current = corner, current == p { continue }
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

        let totalTurns = cwCount + ccwCount
        guard totalTurns > 0 else { return 1.0 }

        return CGFloat(max(cwCount, ccwCount)) / CGFloat(totalTurns)
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
