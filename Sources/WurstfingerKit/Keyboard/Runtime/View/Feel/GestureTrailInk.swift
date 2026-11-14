//
//  GestureTrailInk.swift
//  Wurstfinger
//
//  The gesture trail drawn like ink: thinner where the finger moved fast,
//  fading toward its tail, with a soft glow under the finger.
//

import CoreGraphics
import Foundation
import SwiftUI

/// Velocity-aware geometry and shading for the gesture trail
/// (`GestureTrailOverlay`), on top of `GestureTrailGeometry`'s ribbon.
///
/// **Width follows speed.** A pen line is thin where the hand moved fast and
/// full where it lingered; the trail does the same, so a quick flick reads as
/// a light stroke and a slow, deliberate drag as a firm one. Speeds are
/// smoothed along the path so one noisy sample cannot pinch the ribbon.
///
/// **The tail fades.** Rather than a uniform fill that ends in a hard tip,
/// the ink thins out in opacity over `tailSpan(headWidth:)` from the finger,
/// with a brighter core right under it (`feelTrailInk`, or a radial gradient
/// when the shaders are unavailable or Reduce Transparency is on).
///
/// Pure functions of the recorded samples, testable without rendering.
enum GestureTrailInk {
    /// Below this speed (points per second) the ribbon is at full width.
    static let slowSpeed: CGFloat = 220
    /// At and above this speed it is at its thinnest.
    static let fastSpeed: CGFloat = 1500
    /// The thinnest the ribbon gets, as a fraction of the head width.
    static let thinnest: CGFloat = 0.6
    /// Weight of the previous sample in the speed smoothing (exponential).
    static let smoothing: CGFloat = 0.55
    /// Ink opacity at the tail end, relative to the head.
    static let tailOpacity: CGFloat = 0.3

    /// Width multiplier for a finger moving at `speed` (smoothstep between
    /// `slowSpeed` and `fastSpeed`).
    static func widthScale(forSpeed speed: CGFloat) -> CGFloat {
        let t = min(max((speed - slowSpeed) / (fastSpeed - slowSpeed), 0), 1)
        let eased = t * t * (3 - 2 * t)
        return 1 - (1 - thinnest) * eased
    }

    /// One width multiplier per sample, from the speed into each sample,
    /// smoothed forward along the path.
    static func widthScales(for samples: [GestureTrailSample]) -> [CGFloat] {
        guard !samples.isEmpty else { return [] }
        var scales: [CGFloat] = []
        scales.reserveCapacity(samples.count)
        var smoothedSpeed: CGFloat = 0
        for index in samples.indices {
            if index > 0 {
                let previous = samples[index - 1]
                let sample = samples[index]
                let distance = hypot(sample.point.x - previous.point.x, sample.point.y - previous.point.y)
                // A 240 Hz digitizer's period as the floor: coalesced samples
                // can share a timestamp.
                let interval = max(sample.time - previous.time, 1.0 / 240)
                let speed = distance / CGFloat(interval)
                smoothedSpeed = index == 1 ? speed : smoothing * smoothedSpeed + (1 - smoothing) * speed
            }
            scales.append(widthScale(forSpeed: smoothedSpeed))
        }
        return scales
    }

    /// The trail's shape: the press dot for a lone sample, otherwise the
    /// tapered ribbon with velocity-scaled widths. `predicted` points (the
    /// finger's expected path ahead) extend the ribbon at the last width.
    static func shape(samples: [GestureTrailSample], predicted: [CGPoint], headWidth: CGFloat) -> Path {
        let points = samples.map(\.point) + predicted
        guard points.count > 1 else {
            return GestureTrailGeometry.shape(through: points, headWidth: headWidth)
        }
        var scales = widthScales(for: samples)
        if let last = scales.last {
            scales.append(contentsOf: repeatElement(last, count: predicted.count))
        }
        let subdivisions = KeyboardConstants.GestureTrail.smoothingSubdivisions
        let smoothedPoints = GestureTrailGeometry.smoothed(points, subdivisions: subdivisions)
        let smoothedScales = resample(scales, toMatch: smoothedPoints.count, subdivisions: subdivisions)
        return ribbon(through: smoothedPoints, widthScales: smoothedScales, headWidth: headWidth)
    }

    /// Spreads per-sample values over the spline's subdivided points by
    /// linear interpolation (`GestureTrailGeometry.smoothed` emits
    /// `subdivisions` points per segment plus the last one; short paths pass
    /// through unchanged).
    static func resample(_ values: [CGFloat], toMatch count: Int, subdivisions: Int) -> [CGFloat] {
        guard values.count > 2, subdivisions > 1, count == (values.count - 1) * subdivisions + 1 else {
            return values.count == count ? values : Array(repeating: values.last ?? 1, count: count)
        }
        var result: [CGFloat] = []
        result.reserveCapacity(count)
        for index in 0 ..< values.count - 1 {
            for step in 0 ..< subdivisions {
                let t = CGFloat(step) / CGFloat(subdivisions)
                result.append(values[index] + (values[index + 1] - values[index]) * t)
            }
        }
        result.append(values[values.count - 1])
        return result
    }

    /// `GestureTrailGeometry.ribbon` with a width multiplier per point.
    static func ribbon(
        through points: [CGPoint],
        widthScales: [CGFloat],
        headWidth: CGFloat,
        taperExponent: CGFloat = KeyboardConstants.GestureTrail.taperExponent,
        taperLengthFactor: CGFloat = KeyboardConstants.GestureTrail.taperLengthFactor
    ) -> Path {
        var path = Path()
        guard points.count >= 2, headWidth > 0, widthScales.count == points.count else { return path }
        let last = points.count - 1
        let distances = GestureTrailGeometry.cumulativeDistances(along: points)
        let taperSpan = min(headWidth * taperLengthFactor, distances[last])

        var leftEdge: [CGPoint] = []
        var rightEdge: [CGPoint] = []
        leftEdge.reserveCapacity(points.count)
        rightEdge.reserveCapacity(points.count)
        var normal = CGVector(dx: 0, dy: 0)
        for (index, point) in points.enumerated() {
            if let tangent = GestureTrailGeometry.unitTangent(at: index, in: points) {
                normal = CGVector(dx: -tangent.dy, dy: tangent.dx)
            }
            let progress = taperSpan > 0 ? distances[index] / taperSpan : 1
            let half = GestureTrailGeometry.halfWidth(
                atProgress: progress, headWidth: headWidth * widthScales[index], taperExponent: taperExponent
            )
            leftEdge.append(CGPoint(x: point.x + normal.dx * half, y: point.y + normal.dy * half))
            rightEdge.append(CGPoint(x: point.x - normal.dx * half, y: point.y - normal.dy * half))
        }
        path.move(to: leftEdge[0])
        for point in leftEdge.dropFirst() { path.addLine(to: point) }
        GestureTrailGeometry.appendHeadCap(
            to: &path, head: points[last], normal: normal, radius: headWidth * widthScales[last] / 2
        )
        for point in rightEdge.reversed() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    /// The distance from the finger over which the ink fades to
    /// `tailOpacity`: a little over the visible comet tail of a flick.
    static func tailSpan(headWidth: CGFloat) -> CGFloat {
        headWidth * 9
    }

    /// How the ribbon is filled: the ink shader when available, otherwise a
    /// radial gradient around the finger that fades the same way.
    static func shading(
        head: CGPoint, headWidth: CGFloat, color: Color, opacity: Double, glow: Double, library: ShaderLibrary?
    ) -> GraphicsContext.Shading {
        let span = tailSpan(headWidth: headWidth)
        if let library {
            return .shader(library.feelTrailInk(
                .float2(head.x, head.y), .float(span), .color(color), .float(opacity), .float(glow)
            ))
        }
        return .radialGradient(
            Gradient(colors: [color.opacity(opacity), color.opacity(opacity * Double(tailOpacity))]),
            center: head,
            startRadius: 0,
            endRadius: span
        )
    }
}

extension GestureTrail {
    /// `visiblePoints(at:)` with the samples' timestamps, for the
    /// velocity-aware ink. Same window and same never-empty rule.
    func visibleSamples(
        at now: TimeInterval,
        visibleDuration: TimeInterval = KeyboardConstants.GestureTrail.visibleDuration
    ) -> [GestureTrailSample] {
        let reference = releaseTime ?? now
        let cutoff = reference - visibleDuration
        let visible = samples.drop { $0.time < cutoff }
        guard visible.isEmpty else { return Array(visible) }
        return samples.last.map { [$0] } ?? []
    }
}
