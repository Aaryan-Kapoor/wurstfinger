//
//  GestureTrailScratch.swift
//  Wurstfinger
//
//  The buffers one frame of the gesture trail is built in, kept between
//  frames.
//

import CoreGraphics

/// Reusable working arrays for `GestureTrailInk.shape`.
///
/// The overlay rebuilds the ribbon on every display-link frame while a trail
/// is visible (up to 120 Hz for about a second per gesture). Built out of
/// fresh arrays, that was eight heap allocations a frame — the visible
/// samples, the points, two width-scale arrays, the spline, the arc lengths
/// and the two ribbon edges — plus the `Path`. These arrays keep their
/// capacity from frame to frame, so after the first frame only the `Path`
/// (CoreGraphics storage, unavoidable) allocates.
///
/// Owned by the `GestureTrailRecorder`, which the overlay already reads on
/// the main actor; not `Sendable`, like any scratch memory.
final class GestureTrailScratch {
    var points: [CGPoint] = []
    var scales: [CGFloat] = []
    var smoothedPoints: [CGPoint] = []
    var smoothedScales: [CGFloat] = []
    var distances: [CGFloat] = []
    var leftEdge: [CGPoint] = []
    var rightEdge: [CGPoint] = []

    /// Reserves for the longest trail the recorder keeps plus the predicted
    /// tail, before and after spline subdivision.
    init(
        sampleCapacity: Int = KeyboardConstants.GestureTrail.sampleCapacity + 8,
        subdivisions: Int = KeyboardConstants.GestureTrail.smoothingSubdivisions
    ) {
        let smoothedCapacity = sampleCapacity * subdivisions + 1
        points.reserveCapacity(sampleCapacity)
        scales.reserveCapacity(sampleCapacity)
        smoothedPoints.reserveCapacity(smoothedCapacity)
        smoothedScales.reserveCapacity(smoothedCapacity)
        distances.reserveCapacity(smoothedCapacity)
        leftEdge.reserveCapacity(smoothedCapacity)
        rightEdge.reserveCapacity(smoothedCapacity)
    }
}
