//
//  ClassificationScratch.swift
//  Wurstfinger
//
//  The working memory of one classification, owned by whoever classifies.
//

import CoreGraphics

/// Three equal point buffers the classifier works in: the origin-anchored
/// path as it was recorded, and two more that the pipeline steps ping-pong
/// between (jitter filter, outlier filter and normalisation, smoothing).
///
/// The input engine classifies the path so far on every drag event, and a
/// pipeline that builds an array per step spends ten heap allocations a call.
/// This hands the pipeline its memory instead: one block, allocated once in
/// `init` and freed in `deinit`, so a classification is allocation-free by
/// construction.
///
/// An arena rather than `withUnsafeTemporaryAllocation` per call: the
/// stdlib falls back to the heap above a size threshold (which is
/// implementation-defined and changes between releases), and even the stack
/// path would have to be re-zeroed and re-sliced on every event. An arena
/// costs nothing per call and has no threshold to stay under.
///
/// Not `Sendable` — a classification mutates the buffers in place, so one
/// scratch serves one isolation domain (the engine's main actor). Give each
/// its own; the footprint is a few kilobytes.
nonisolated final class ClassificationScratch {
    /// The longest path each buffer holds: the position ring's capacity plus
    /// the origin, which is prepended when the ring has evicted it.
    let pathCapacity: Int

    private let base: UnsafeMutablePointer<CGPoint>

    /// `capacity` is the position buffer's capacity (the longest recorded
    /// path, before the origin is re-anchored).
    init(capacity: Int = KeyboardConstants.Gesture.positionBufferSize) {
        precondition(capacity >= 0, "ClassificationScratch capacity must not be negative")
        pathCapacity = capacity + 1
        base = .allocate(capacity: 3 * pathCapacity)
        base.initialize(repeating: .zero, count: 3 * pathCapacity)
    }

    deinit {
        base.deallocate()
    }

    /// Where the origin-anchored path is copied to (see
    /// `KeyGestureSequence.withOriginAnchoredPath`).
    var path: UnsafeMutableBufferPointer<CGPoint> {
        UnsafeMutableBufferPointer(start: base, count: pathCapacity)
    }

    /// First ping-pong buffer.
    var a: UnsafeMutableBufferPointer<CGPoint> {
        UnsafeMutableBufferPointer(start: base + pathCapacity, count: pathCapacity)
    }

    /// Second ping-pong buffer.
    var b: UnsafeMutableBufferPointer<CGPoint> {
        UnsafeMutableBufferPointer(start: base + 2 * pathCapacity, count: pathCapacity)
    }
}
