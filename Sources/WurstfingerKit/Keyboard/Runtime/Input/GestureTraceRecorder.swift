//
//  GestureTraceRecorder.swift
//  Wurstfinger
//
//  The opt-in recorder of gesture traces: the engine feeds it the path of every
//  flick gesture, it labels them and hands them to the store in batches.
//

import CoreGraphics
import Foundation

/// Records the shape and timing of the user's gestures, so the recognizer can be
/// tuned against how they really type (`GestureTraceRecord`, `GestureLab`).
///
/// **Off the keystroke path.** The engine holds the recorder as an optional
/// (`TouchEngine.traceSink`) that is nil unless the user turned recording on, so
/// with it off a touch pays one optional check per event and the keystroke path
/// allocates nothing. With it on, a gesture costs the samples it collects (one
/// array per finger, grown as it moves) and one record when it lifts — a handful
/// of small allocations per keystroke, never a file operation: finished records
/// wait in memory and are written in one batch `flushDelay` seconds after the
/// first one, on a timer from the `TimerSource`, by a background task.
///
/// **What is kept** is decided by `GestureTraceRecord` (geometry, never the
/// character) and **where it may be recorded** by the owner of this object
/// (`KeyboardViewModel.updateTraceRecording`): not in a sensitive field, not
/// where the host asks for no suggestions (URL, email, code), not without Full
/// Access. A recorder that is switched off mid-gesture drops what it holds.
@MainActor
final class GestureTraceRecorder {
    /// A batch is written this long after the first record in it.
    static let flushDelay: TimeInterval = 5

    /// One finger's gesture so far.
    private struct Capture {
        var keyId: String
        var keySize: CGSize
        /// Where the finger landed, in points from the key's centre.
        var offset: CGPoint
        var startTime: TimeInterval
        /// `[translation.x, translation.y, seconds since touch-down]`, in points.
        var samples: [[Double]]
    }

    private var captures: [PointerID: Capture] = [:]
    private var labeler = GestureTraceLabeler()
    private var ready: [GestureTraceRecord] = []
    private let store: GestureTraceStore?
    private let timers: any TimerSource
    /// Whether a batch is being written. Writes never overlap, so records land
    /// in the order they were made.
    private var isWriting = false
    private var pendingFlush: TimerHandle?
    /// Writes inline instead of on a background task (tests).
    private let writesInline: Bool

    /// Gestures recorded since this recorder was made, for tests.
    private(set) var recordedCount = 0

    init(store: GestureTraceStore?, timers: any TimerSource, writesInline: Bool = false) {
        self.store = store
        self.timers = timers
        self.writesInline = writesInline
    }

    // MARK: - From the engine

    /// A finger landed on a flick key.
    func began(_ id: PointerID, keyId: String, keySize: CGSize, offset: CGPoint, time: TimeInterval) {
        var samples: [[Double]] = []
        samples.reserveCapacity(48)
        samples.append([0, 0, 0])
        captures[id] = Capture(keyId: keyId, keySize: keySize, offset: offset, startTime: time, samples: samples)
    }

    /// The finger moved to `translation` (points from where it landed).
    func moved(_ id: PointerID, translation: CGPoint, time: TimeInterval) {
        guard let start = captures[id]?.startTime else { return }
        captures[id]?.samples.append([Double(translation.x), Double(translation.y), time - start])
    }

    /// The finger lifted at `translation`, and the recognizer read the gesture as
    /// `classification`.
    func ended(_ id: PointerID, translation: CGPoint, time: TimeInterval, classification: GestureClassification) {
        guard var capture = captures.removeValue(forKey: id), capture.keySize.height > 0 else { return }
        capture.samples.append([Double(translation.x), Double(translation.y), time - capture.startTime])

        // Key heights from the key's centre; the time to the farthest point.
        let height = Double(capture.keySize.height)
        var peak = 0.0
        var farthest = 0.0
        let samples: [[Double]] = capture.samples.map { sample in
            let distance = (sample[0] * sample[0] + sample[1] * sample[1]).squareRoot()
            if distance > farthest {
                farthest = distance
                peak = sample[2]
            }
            return [(sample[0] + Double(capture.offset.x)) / height, (sample[1] + Double(capture.offset.y)) / height, sample[2]]
        }
        let record = GestureTraceRecord(
            meant: classification.gesture.rawValue, meantIsReturn: classification.isReturn, label: .accepted,
            classified: classification.gesture.rawValue, classifiedIsReturn: classification.isReturn,
            slot: capture.keyId, keyWidth: Double(capture.keySize.width), keyHeight: height,
            samples: samples, peakTime: peak, duration: time - capture.startTime
        )
        recordedCount += 1
        ready.append(contentsOf: labeler.gesture(record, endedAt: time))
        scheduleFlush()
    }

    /// The finger was taken away without a gesture.
    func cancelled(_ id: PointerID) {
        captures.removeValue(forKey: id)
    }

    // MARK: - From the view model

    /// The user deleted something: a gesture just before it may have been wrong.
    func noteDelete(at time: TimeInterval? = nil) {
        labeler.delete(at: time ?? timers.now)
    }

    /// Stops recording: drops the gestures in flight, decides the pending one,
    /// and writes what is waiting. Called when the user turns recording off or
    /// the field turns sensitive.
    func stop() {
        captures.removeAll()
        flush(force: true)
    }

    // MARK: - Writing

    private func scheduleFlush() {
        guard store != nil, pendingFlush == nil else { return }
        pendingFlush = timers.schedule(after: Self.flushDelay) { [weak self] in
            guard let self else { return }
            pendingFlush = nil
            flush()
        }
    }

    /// Writes the finished records now. `force` also decides the gesture still
    /// waiting for a correction (accepted).
    func flush(force: Bool = false) {
        pendingFlush?.cancel()
        pendingFlush = nil
        ready.append(contentsOf: labeler.settle(at: timers.now, force: force))
        guard let store else {
            ready = []
            return
        }
        // A gesture still inside its correction window is looked at again.
        defer { if labeler.hasPending || (!ready.isEmpty && isWriting) { scheduleFlush() } }
        guard !ready.isEmpty, !isWriting else { return }
        let batch = ready
        ready = []
        if writesInline {
            store.append(batch)
            return
        }
        isWriting = true
        // The write itself runs off the main actor; its completion comes back.
        Task { @MainActor [weak self] in
            await Task.detached(priority: .utility) { store.append(batch) }.value
            guard let self else { return }
            isWriting = false
            if !ready.isEmpty { scheduleFlush() }
        }
    }
}
