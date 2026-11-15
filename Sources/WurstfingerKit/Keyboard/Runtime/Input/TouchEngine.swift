//
//  TouchEngine.swift
//  Wurstfinger
//
//  Raw touches in, keystrokes out: the keyboard's whole input path, for every
//  finger at once.
//

import CoreGraphics
import Foundation

/// Identifies one finger for the lifetime of its touch (a `UITouch` identity on
/// iOS, the mouse on macOS, a counter in tests).
typealias PointerID = Int

/// One position of a moving finger, in the grid's coordinate space.
struct TouchSample: Sendable, Equatable {
    var location: CGPoint
    var time: TimeInterval
}

/// What the engine tells the keyboard. Every call happens synchronously on the
/// main actor, inside the touch event that caused it.
@MainActor
struct TouchEngineActions {
    /// A finger landed on a key (haptic, signpost).
    var touchDown: (KeyDefinition) -> Void = { _ in }
    /// A flick key's gesture completed. The full classification, so long
    /// swipes (which depend on the distance, not just the direction) resolve.
    var gesture: (KeyDefinition, GestureClassification) -> Void = { _, _ in }
    /// A slide key (space, delete) reported a phase.
    var slide: (KeyDefinition, SlidePhase) -> Void = { _, _ in }
    /// The finger rested long enough for a long press; returns whether it was
    /// handled. Only consulted while long presses are enabled.
    var longPress: (KeyDefinition) -> Bool = { _ in false }
    /// What a classification on a key would type or do, for the live preview —
    /// resolved without dispatching anything.
    var previewLabel: (KeyDefinition, GestureClassification) -> String? = { _, _ in nil }

    // MARK: Feel hooks (haptics, animation; see docs/feel.md)
    //
    // Fired synchronously inside the touch event, like everything above, and
    // never consulted for what gets typed: the feel layer only watches.

    /// The speculative target of a moving flick changed (from, to).
    var candidateChanged: (KeyDefinition, GestureCandidate, GestureCandidate) -> Void = { _, _, _ in }
    /// A finger lifted off a key with this classification — at the lift, before
    /// rollover ordering may hold its keystroke back, so the release is felt
    /// when it happens. A slide key's tap reports a plain `.tap`. Called
    /// *before* the keystroke is handed on (dispatching can change the mode,
    /// and the feel layer must resolve against the one the finger saw); the
    /// feel layer only resolves here and issues its effects in
    /// `releaseHandled`.
    var released: (KeyDefinition, GestureClassification) -> Void = { _, _ in }
    /// The release reported by `released` has been handed on — typed, or
    /// queued behind an earlier finger. Called at the end of the same touch
    /// event, so the click and the pop never go out ahead of the text.
    var releaseHandled: () -> Void = {}
    /// A long press was armed, cancelled or fired.
    var longPressPhase: (KeyDefinition, LongPressFeelPhase) -> Void = { _, _ in }
}

/// The keyboard's input engine.
///
/// **Why not a gesture per key.** Each key used to own a SwiftUI
/// `DragGesture`. That routes every touch through the gesture system's
/// arbitration before a key sees it, delivers one sample per frame (the
/// coalesced 120/240 Hz samples between frames are dropped), knows nothing of
/// predicted touches, and gives each key its own isolated finger — rollover
/// typing, where the next thumb lands before the last one lifts, was whatever
/// the gesture system made of it. The engine instead receives the raw touch
/// stream for the whole keyboard from one surface (`TouchSurface`), finds the
/// key under each finger with a table lookup (`KeyHitMap`), and runs every
/// finger through its own track.
///
/// **Isolation and latency.** Main-actor and synchronous: a touch event is
/// handled to completion in the call that delivers it — hit test, highlight,
/// haptic, classification, dispatch, `insertText` — with no hop, no lock and no
/// `await` anywhere. Everything slow was moved *out* of this path ahead of time:
/// settings are a `GestureTuning` snapshot, definitions are prewarmed, the hit
/// map is rebuilt only when the layout changes, finger tracks come from a pool,
/// and the classifier works in a scratch arena the engine owns — so a drag
/// sample allocates nothing at all (the bench's allocation rows hold it to
/// zero).
///
/// **Speculation.** While a finger moves, the engine classifies the path so far
/// on every event (a couple of microseconds) and publishes the gesture it is
/// heading for: the key emphasizes that hint and the guide card above the key
/// shows what releasing now would type (`KeyPressRegistry`,
/// `TouchGuideOverlay`). The user sees the result before lifting; the release
/// only confirms it. Updates are change-driven, so a steady flick costs no
/// rendering after its direction settles.
///
/// **Rollover order.** With several fingers down, a gesture that completes
/// while an earlier-pressed finger is still undecided waits for that finger,
/// so text comes out in the order the keys were *pressed* — a fast "th" typed
/// with overlapping thumbs stays "th" even if the h-thumb lifts first. The wait
/// is bounded (`rolloverHold`): a thumb resting on the keyboard for longer than
/// that no longer holds the other thumb's typing back. A long press is a
/// commit like any other and takes its turn the same way (it is deferred, not
/// skipped, while an earlier finger still holds its place).
///
/// **Per-finger state is a phase.** Each track is in exactly one
/// `PointerTrack.Phase` — resting, heading for a candidate, sliding, or
/// consumed by a long press — and every rule below (what holds back a later
/// keystroke, whether a long press may fire, what a release types) is a
/// function of that phase. The loose flags this replaced allowed states such
/// as "consumed by a long press and still speculating", and one real bug
/// (the long press's consumed flag was set *after* the flush that depended on
/// it) came straight out of that.
@MainActor
final class TouchEngine {
    /// Per-key pressed state and the flick preview, for the views.
    let press = KeyPressRegistry()

    /// The gesture trail recorder this engine feeds.
    let trail: GestureTrailRecorder

    /// How long an earlier, still-undecided finger may hold back a completed
    /// gesture (measured from that finger's touch-down). Long enough for
    /// overlapping keystrokes in fast two-thumb typing, short enough that a
    /// resting thumb is never mistaken for one.
    nonisolated static let rolloverHold: TimeInterval = 0.25

    /// Most fingers tracked at once; more are ignored, as on the system keyboard.
    nonisolated static let maxPointers = 10

    private(set) var hitMap = KeyHitMap.empty
    private(set) var tuning = GestureTuning.default
    private var geometry: GridGeometry?
    private var size: CGSize = .zero
    private var keys: [String: KeyDefinition] = [:]
    private var actions = TouchEngineActions()
    private var isLongPressEnabled = false
    /// SLIDE SPEED hook: the touch-clock time of the slide sample being
    /// reported, so the view model can tell how fast the finger slides
    /// (`SlideSpeedTracker`) without a clock of its own.
    private(set) var slideSampleTime: TimeInterval = 0

    /// Fingers currently down, in press order.
    private var tracks: [PointerTrack] = []
    /// Released tracks, reused for the next touches.
    private var pool: [PointerTrack] = []
    /// Completed gestures waiting for an earlier finger (see "Rollover order").
    private var pending = CommitQueue()
    /// When the head of the queue may go out, if a hold is blocking it
    /// (touch-clock time).
    private var flushDeadline: TimeInterval?
    private var nextSequence: UInt64 = 0
    /// The clock and timer every deadline here runs on.
    private let timers: any TimerSource
    /// **The one timer.** The engine has several deadlines in flight — one
    /// long press per resting finger and the rollover flush — but arms a
    /// single timer for the earliest of them and, when it fires, runs whatever
    /// is due and re-arms for the next. Deadlines that go away (a finger
    /// lifts, a flick cancels its long press) do not touch the timer: it wakes
    /// at the old deadline, finds nothing due and re-arms. So typing with
    /// long-press digits on creates about one timer task every long-press
    /// duration, not one per keystroke (the previous design, measured at 9
    /// extra allocations per tap).
    private var timer: TimerHandle?
    /// The deadline `timer` is armed for.
    private var armedDeadline: TimeInterval?
    /// The classifier's working memory, allocated once; see
    /// `ClassificationScratch`.
    private let scratch = ClassificationScratch()

    /// - Parameter timers: The clock touch timestamps are measured on and the
    ///   timer deadlines are armed with. System uptime (like
    ///   `UITouch.timestamp` and `NSEvent.timestamp`) in the keyboard; a
    ///   `ManualTimerSource` in tests.
    init(
        trail: GestureTrailRecorder = GestureTrailRecorder(),
        timers: any TimerSource = SystemTimerSource()
    ) {
        self.trail = trail
        self.timers = timers
        pool.reserveCapacity(Self.maxPointers)
        tracks.reserveCapacity(Self.maxPointers)
    }

    /// An engine on the system timers but a custom clock (tests that drive
    /// synthetic touch times and never let a timer fire).
    convenience init(trail: GestureTrailRecorder = GestureTrailRecorder(), now: @escaping () -> TimeInterval) {
        self.init(trail: trail, timers: SystemTimerSource(now: now))
    }

    // MARK: - Configuration

    /// Hands the engine the keyboard it is driving. Called by the view layer on
    /// every update; cheap when nothing changed. Keys that disappear from the
    /// layout (a mode or language switch) abandon their fingers, as a key view
    /// torn down mid-gesture used to; a key whose slot stays but changes from a
    /// flick key to a slide key (or back) abandons its finger too, since the
    /// track's state machine was chosen at touch-down.
    func configure(
        geometry: GridGeometry,
        keys: [String: KeyDefinition],
        tuning: GestureTuning,
        isLongPressEnabled: Bool,
        actions: TouchEngineActions
    ) {
        self.keys = keys
        self.tuning = tuning
        self.isLongPressEnabled = isLongPressEnabled
        self.actions = actions
        trail.useEnabledSetting(tuning.isTrailEnabled)
        if self.geometry != geometry {
            self.geometry = geometry
            rebuildHitMap()
        }
        for track in tracks {
            if let key = keys[track.keyId], key.slideType == track.key.slideType {
                track.key = key
            } else {
                abandon(track)
            }
        }
    }

    /// The touch surface's size changed.
    func updateSize(_ size: CGSize) {
        guard self.size != size else { return }
        self.size = size
        rebuildHitMap()
    }

    private func rebuildHitMap() {
        guard let geometry, size.width > 0, size.height > 0 else {
            hitMap = .empty
            return
        }
        hitMap = KeyHitMap(geometry: geometry, size: size)
    }

    // MARK: - Touch events

    /// A finger touched down at `location` (grid coordinates).
    func began(_ id: PointerID, at location: CGPoint, time: TimeInterval) {
        if let stale = track(for: id) { abandon(stale) }
        guard tracks.count < Self.maxPointers,
              let hit = hitMap.key(at: location),
              let key = keys[hit.id]
        else { return }

        let track = pool.popLast() ?? PointerTrack()
        track.start(
            id: id, key: key, origin: location, aspectRatio: hit.aspectRatio, keySize: hit.size,
            sequence: nextSequence, time: time
        )
        nextSequence &+= 1
        tracks.append(track)

        // Feel hook: where on the key the finger landed (the press light and
        // ripple start there), written before `isPressed` so the key renders
        // both in the same update.
        press.setTouchPoint(
            CGPoint(
                x: hit.frame.width > 0 ? (location.x - hit.frame.minX) / hit.frame.width : 0.5,
                y: hit.frame.height > 0 ? (location.y - hit.frame.minY) / hit.frame.height : 0.5
            ),
            keyId: key.id
        )
        press.setPressed(true, keyId: key.id)
        if key.slideType == .none {
            press.setGuide(TouchGuide(keyId: key.id, keyFrame: hit.frame, touchID: track.sequence))
        }
        trail.begin(at: location, from: track.trailToken)
        actions.touchDown(key)
        switch track.kind {
        case .flick:
            track.recordFlick(.zero, at: time)
        case let .slide(configuration):
            _ = track.recordSlide(.zero, configuration: configuration)
        }
        if isLongPressEnabled {
            armLongPress(for: track, at: time + tuning.longPressDuration)
            actions.longPressPhase(key, .armed(keyFrame: hit.frame, delay: tuning.longPressDuration))
        }
    }

    /// A finger moved. `samples` are every position since the last event, in
    /// order (the coalesced touches); `predicted` are where the system expects
    /// it next, used for display only.
    ///
    /// The per-sample loop is the hottest code in the keyboard (up to 240
    /// samples a second per finger). It touches no dictionary, allocates
    /// nothing and calls no closure except the slide phases a latched space
    /// or delete key actually reports.
    func moved(_ id: PointerID, samples: [TouchSample], predicted: [CGPoint] = []) {
        guard let track = track(for: id), track.phase != .longPressed else { return }
        let token = track.trailToken
        switch track.kind {
        case .flick:
            for sample in samples {
                trail.extend(to: sample.location, from: token)
                track.recordFlick(track.translation(to: sample.location), at: sample.time)  // WP-A
            }
        case let .slide(configuration):
            for sample in samples {
                trail.extend(to: sample.location, from: token)
                slideSampleTime = sample.time // SLIDE SPEED hook
                let update = track.recordSlide(track.translation(to: sample.location), configuration: configuration)
                reportSlide(update, from: track)
            }
        }
        trail.predict(predicted, from: token)
        // Long swipes: the trail takes the accent colour while letting go
        // would fire one. No work at all while they are off.
        if tuning.longSwipe.isEnabled, case .flick = track.kind, let last = samples.last {
            let translation = track.translation(to: last.location)
            trail.setLongSwipeArmed(
                tuning.longSwipe.isArmed(
                    translation: CGSize(width: translation.x, height: translation.y), keySize: track.keySize
                ),
                from: token
            )
        }
        if track.longPressDeadline != nil, !track.isResting(within: tuning.longPressMovementTolerance) {
            track.longPressDeadline = nil
            actions.longPressPhase(track.key, .cancelled)
        }
        speculate(track)
    }

    /// Dispatches what one slide sample produced: the latch (which moves the
    /// track to `.sliding`, so it no longer holds later keystrokes back) and
    /// the travel since the last report.
    @inline(__always)
    private func reportSlide(_ update: SlideGestureState.Update, from track: PointerTrack) {
        if update.began {
            track.markSliding()
            actions.slide(track.key, .began)
        }
        if let deltaX = update.deltaX {
            actions.slide(track.key, .changed(deltaX: deltaX))
        }
    }

    /// A finger lifted at `location`.
    func ended(_ id: PointerID, at location: CGPoint, time: TimeInterval) {
        guard let track = track(for: id) else { return }
        remove(track)
        if track.longPressDeadline != nil {
            track.longPressDeadline = nil
            actions.longPressPhase(track.key, .cancelled)
        }
        release(track)

        if track.phase == .longPressed {
            // The long press already typed; the release types nothing.
            recycle(track)
            flushPending(at: time)
            return
        }
        // Feel hook: issue the release's click and pop once the keystroke
        // below has been handed on.
        defer { actions.releaseHandled() }

        let translation = track.translation(to: location)
        switch track.kind {
        case .flick:
            InputSignposts.begin(InputSignposts.classify, InputSignposts.classifyID)
            let classification = track.flick.handleEnded(
                translation: CGSize(width: translation.x, height: translation.y),
                aspectRatio: track.aspectRatio,
                tuning: tuning,
                keySize: track.keySize,
                elapsed: time - track.pressTime, // WP-A
                scratch: scratch
            )
            InputSignposts.end(InputSignposts.classify, InputSignposts.classifyID)
            trail.finish(from: track.trailToken)
            actions.released(track.key, classification)
            enqueue(PendingCommit(sequence: track.sequence, key: track.key, kind: .gesture(classification)), at: time)
        case let .slide(configuration):
            // Feed the release position as a final move first, as the drag
            // gesture did, so travel in the last frame is not lost.
            slideSampleTime = time // SLIDE SPEED hook
            reportSlide(track.recordSlide(translation, configuration: configuration), from: track)
            let phase = track.slide.handleEnded(
                translation: CGSize(width: translation.x, height: translation.y),
                configuration: configuration
            )
            trail.finish(from: track.trailToken)
            if phase == .tap { actions.released(track.key, GestureClassification(gesture: .tap, isReturn: false)) }
            if let phase, phase.producesText {
                // Text-producing ends keep their place in the press order.
                enqueue(PendingCommit(sequence: track.sequence, key: track.key, kind: .slide(phase)), at: time)
            } else {
                if let phase { actions.slide(track.key, phase) }
                flushPending(at: time)
            }
        }
        recycle(track)
    }

    /// The system took a finger away (an incoming call, a system gesture).
    func cancelled(_ id: PointerID) {
        guard let track = track(for: id) else { return }
        abandon(track)
    }

    /// Drops every finger (the keyboard is going away) and types whatever
    /// already completed.
    func cancelAll() {
        for track in tracks { abandon(track) }
        flushPending(at: .infinity)
        press.clearAll()
        timer?.cancel()
        timer = nil
        armedDeadline = nil
    }

    /// Fingers currently down.
    var activePointerCount: Int { tracks.count }

    /// Released tracks waiting for reuse.
    var pooledTrackCount: Int { pool.count }

    // MARK: - Speculation

    private func speculate(_ track: PointerTrack) {
        guard case .flick = track.kind else { return }
        let classification = track.flick.withOriginAnchoredPath(scratch: scratch) { path in
            KeyGestureRecognizer.classify(
                path: path,
                config: tuning.config.with(aspectRatio: track.aspectRatio),
                thresholds: tuning.thresholds,
                keySize: track.keySize,
                peakTime: track.flick.peakElapsed, // WP-A
                scratch: scratch
            )
        }
        let candidate: PointerTrack.Candidate? = classification.gesture == .tap
            ? nil
            : PointerTrack.Candidate(
                gesture: classification.gesture,
                isReturn: classification.isReturn,
                // A swipe that crosses the long-swipe threshold keeps its
                // direction but changes what it does, so that counts as a new
                // target too.
                isLongSwipe: tuning.longSwipe.isEnabled && tuning.longSwipe.action(for: classification) != nil
            )
        let previous = track.candidate
        guard track.setCandidate(candidate) else { return }
        // Feel hook: detents, the return turn, the long-swipe threshold.
        actions.candidateChanged(track.key, GestureCandidate(previous), GestureCandidate(candidate))
        press.setCandidate(candidate?.gesture, isReturn: candidate?.isReturn ?? false, keyId: track.keyId)
        let label = candidate == nil ? nil : actions.previewLabel(track.key, classification)
        press.updateGuide(touchID: track.sequence) { guide in
            guide.candidate = candidate?.gesture
            guide.isReturn = candidate?.isReturn ?? false
            guide.label = label
        }
    }

    // MARK: - Long press

    /// Arms the finger's long press for `deadline` (touch-clock time).
    private func armLongPress(for track: PointerTrack, at deadline: TimeInterval) {
        track.longPressDeadline = deadline
        rearmTimer()
    }

    /// The fire guard: the finger is still down, still resting and not yet
    /// consumed, no earlier finger holds its place in the press order, and a
    /// long-press binding resolved.
    ///
    /// A long press that fires while an earlier finger is still inside its
    /// hold is *deferred* to that hold's deadline rather than dispatched out of
    /// order or dropped: it is a commit like any other. (With the stock
    /// timings a hold always expires long before a long press fires, so the
    /// deferral is a guarantee rather than a frequent path.)
    @discardableResult
    private func longPressFired(_ track: PointerTrack) -> Bool {
        guard tracks.contains(where: { $0 === track }), track.phase != .longPressed else { return false }
        guard track.isResting(within: tuning.longPressMovementTolerance) else {
            actions.longPressPhase(track.key, .cancelled)
            return false
        }
        let time = timers.now
        // Commits whose hold expired since the last event are still queued
        // until something flushes them; a long press is a later commit, so it
        // releases them first rather than overtaking them. (The flush timer
        // normally runs before a long press can fire; this makes it a rule.)
        flushPending(at: time)
        if let blocker = tracks.first(where: { $0.holdsBack(track.sequence, at: time) }) {
            armLongPress(for: track, at: blocker.holdDeadline)
            return false
        }
        guard actions.longPress(track.key) else {
            actions.longPressPhase(track.key, .cancelled)
            return false
        }
        // Consumed *before* the flush below: a consumed finger no longer holds
        // back later keystrokes, and the flush reads the phase.
        track.markLongPressed()
        actions.longPressPhase(track.key, .fired)
        trail.finish(from: track.trailToken)
        press.setCandidate(nil, isReturn: false, keyId: track.keyId)
        press.clearGuide(touchID: track.sequence)
        flushPending(at: time)
        return true
    }

    /// Runs the long-press timer for `id` now instead of after the delay —
    /// what the scenario harness uses to type a long press without waiting.
    func fireLongPressTimer(for id: PointerID) {
        guard isLongPressEnabled, let track = track(for: id) else { return }
        track.longPressDeadline = nil
        longPressFired(track)
    }

    // MARK: - The timer

    /// Arms the timer for the earliest deadline in flight, unless the armed
    /// one is already that early. Called whenever a deadline is added or moved
    /// earlier; a deadline that is removed is left to the lazy wake-up (see
    /// `timer`).
    private func rearmTimer() {
        var next = flushDeadline ?? .infinity
        for track in tracks {
            if let deadline = track.longPressDeadline, deadline < next { next = deadline }
        }
        guard next < .infinity else { return }
        if let armed = armedDeadline, timer?.isActive == true, armed <= next { return }
        timer?.cancel()
        armedDeadline = next
        timer = timers.schedule(after: next - timers.now) { [weak self] in
            self?.timerFired()
        }
    }

    /// Runs every deadline that has passed — long presses first, in press
    /// order, then the held-back commits — and re-arms for whatever is left.
    private func timerFired() {
        timer = nil
        armedDeadline = nil
        let time = timers.now
        for track in tracks {
            guard let deadline = track.longPressDeadline, deadline <= time else { continue }
            track.longPressDeadline = nil
            longPressFired(track)
        }
        if let deadline = flushDeadline, deadline <= time {
            flushDeadline = nil
            flushPending(at: time)
        }
        rearmTimer()
    }

    /// The deadline the timer is armed for, if any (for tests).
    var armedTimerDeadline: TimeInterval? {
        timer?.isActive == true ? armedDeadline : nil
    }

    // MARK: - Ordered commits

    private func enqueue(_ commit: PendingCommit, at time: TimeInterval) {
        pending.insert(commit)
        flushPending(at: time)
    }

    /// Dispatches waiting gestures in press order, stopping at the first one
    /// an earlier finger still holds back.
    private func flushPending(at time: TimeInterval) {
        while let head = pending.first {
            if let blocker = tracks.first(where: { $0.holdsBack(head.sequence, at: time) }) {
                flushDeadline = blocker.holdDeadline
                rearmTimer()
                return
            }
            pending.removeFirst()
            switch head.kind {
            case let .gesture(classification): actions.gesture(head.key, classification)
            case let .slide(phase): actions.slide(head.key, phase)
            }
        }
        flushDeadline = nil
    }

    /// Re-checks the waiting gestures at `time` (for tests driving a clock).
    func flushPendingCommits(at time: TimeInterval) {
        flushPending(at: time)
    }

    var pendingCommitCount: Int { pending.count }

    // MARK: - Track bookkeeping

    @inline(__always)
    private func track(for id: PointerID) -> PointerTrack? {
        tracks.first { $0.id == id }
    }

    private func remove(_ track: PointerTrack) {
        tracks.removeAll { $0 === track }
    }

    /// Takes the finger's marks off the views. Another finger may still hold
    /// the same key, in which case the key stays pressed and shows *that*
    /// finger's candidate rather than the lifted finger's.
    private func release(_ track: PointerTrack) {
        if let other = tracks.first(where: { $0.keyId == track.keyId }) {
            if track.candidate != nil {
                press.setCandidate(
                    other.candidate?.gesture, isReturn: other.candidate?.isReturn ?? false, keyId: track.keyId
                )
            }
        } else {
            press.setPressed(false, keyId: track.keyId)
        }
        press.clearGuide(touchID: track.sequence)
    }

    /// Drops a finger without a gesture: no text, a cancelled phase for a
    /// slide in flight, the trail cleared at once.
    private func abandon(_ track: PointerTrack) {
        remove(track)
        if track.longPressDeadline != nil {
            track.longPressDeadline = nil
            actions.longPressPhase(track.key, .cancelled)
        }
        if case .slide = track.kind, let phase = track.slide.handleCancelled() {
            actions.slide(track.key, phase)
        }
        trail.cancel(from: track.trailToken)
        release(track)
        recycle(track)
        flushPending(at: timers.now)
    }

    private func recycle(_ track: PointerTrack) {
        track.reset()
        if pool.count < Self.maxPointers { pool.append(track) }
    }
}

/// The layout inputs the hit map is built from — everything but the size,
/// which only the surface knows.
struct GridGeometry: Sendable, Equatable {
    var cells: [SolvedCell]
    var columns: Int
    var rowHeight: CGFloat
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat
    var cellAspectRatio: CGFloat
}

extension KeyHitMap {
    init(geometry: GridGeometry, size: CGSize) {
        self.init(
            cells: geometry.cells,
            columns: geometry.columns,
            size: size,
            rowHeight: geometry.rowHeight,
            horizontalSpacing: geometry.horizontalSpacing,
            verticalSpacing: geometry.verticalSpacing,
            cellAspectRatio: geometry.cellAspectRatio
        )
    }
}

/// A completed gesture waiting for its turn.
private struct PendingCommit {
    enum Kind {
        case gesture(GestureClassification)
        case slide(SlidePhase)
    }

    let sequence: UInt64
    let key: KeyDefinition
    let kind: Kind
}

/// The commits waiting for an earlier finger, kept in press order.
///
/// At most one per finger down, so it never holds more than
/// `TouchEngine.maxPointers` entries; the storage is reserved once and the
/// ordered insert is a scan of a handful of elements.
private struct CommitQueue {
    private var commits: [PendingCommit] = []

    init() {
        commits.reserveCapacity(TouchEngine.maxPointers)
    }

    var first: PendingCommit? { commits.first }
    var count: Int { commits.count }

    /// Inserts by press order (`sequence`), after any commit of an earlier
    /// finger and before any of a later one.
    mutating func insert(_ commit: PendingCommit) {
        let index = commits.firstIndex { $0.sequence > commit.sequence } ?? commits.endIndex
        commits.insert(commit, at: index)
    }

    mutating func removeFirst() {
        commits.removeFirst()
    }
}

/// One finger's state, from touch-down to release. A class so the engine's
/// timer can read the live state at fire time, and pooled by the engine so a
/// touch allocates nothing: the sample buffer and the trail token are created
/// once per slot and reset between fingers.
///
/// (`~Copyable` per-finger values were considered: Swift 6.1's `Array` cannot
/// hold them and there is no inline fixed-size array yet, so a pool of them
/// would need unsafe storage. The pool of final classes already allocates
/// nothing after warm-up; the phase below is what gives the state machine its
/// guarantees.)
@MainActor
private final class PointerTrack {
    /// Which state machine the key under the finger runs.
    enum Kind: Equatable {
        case flick
        case slide(SlideGestureConfiguration)
    }

    /// The gesture a flick finger is heading for, as last published.
    struct Candidate: Equatable {
        var gesture: GestureType
        var isReturn: Bool
        /// Letting go now would fire a long swipe rather than the key's own
        /// binding; the direction alone does not say so.
        var isLongSwipe: Bool
    }

    /// Where the finger is in its life on the key. Transitions:
    ///
    /// ```
    /// resting ──speculation finds a direction──▶ heading(candidate) ──direction lost──▶ resting
    ///    │                                            │
    ///    ├──slide latched (slide keys)──▶ sliding     │
    ///    │                                            │
    ///    └──long press handled─────────▶ longPressed ◀┘
    /// ```
    ///
    /// `sliding` and `longPressed` are terminal until release. A finger in
    /// `resting` or `heading` is *undecided* and holds back later keystrokes
    /// for the rollover hold; the other two have already decided (a slide
    /// types nothing on release, a long press has typed) and hold nothing.
    enum Phase: Equatable {
        case resting
        case heading(Candidate)
        case sliding
        case longPressed
    }

    private(set) var id: PointerID = 0
    private(set) var keyId = ""
    var key = KeyDefinition.idle
    private(set) var origin: CGPoint = .zero
    private(set) var aspectRatio: CGFloat = 1
    private(set) var keySize: CGSize = .zero
    private(set) var sequence: UInt64 = 0
    private(set) var pressTime: TimeInterval = 0
    private(set) var kind = Kind.flick
    private(set) var phase = Phase.resting

    var flick = KeyGestureSequence()
    var slide = SlideGestureState()
    let trailToken = GestureTrailToken()
    /// When this finger's long press fires (touch-clock time), while one is
    /// armed; the engine's single timer serves it (see `TouchEngine.timer`).
    var longPressDeadline: TimeInterval?

    func start(
        id: PointerID, key: KeyDefinition, origin: CGPoint, aspectRatio: CGFloat, keySize: CGSize,
        sequence: UInt64, time: TimeInterval
    ) {
        self.id = id
        self.key = key
        keyId = key.id
        self.origin = origin
        self.aspectRatio = aspectRatio
        self.keySize = keySize
        self.sequence = sequence
        pressTime = time
        kind = key.slideType == .none ? .flick : .slide(.for(key.slideType))
        phase = .resting
    }

    @inline(__always)
    func translation(to location: CGPoint) -> CGPoint {
        CGPoint(x: location.x - origin.x, y: location.y - origin.y)
    }

    /// Feeds one sample (relative to touch-down) to a flick key's sequence.
    @inline(__always)
    func recordFlick(_ translation: CGPoint, at time: TimeInterval) {
        // WP-A: the time lets the classifier tell a quick short flick from a
        // slow drift (`GestureFeatures.isFastSwipe`).
        _ = flick.handleChanged(
            translation: CGSize(width: translation.x, height: translation.y), elapsed: time - pressTime
        )
    }

    /// Feeds one sample to a slide key's state machine; the caller dispatches
    /// what it reports.
    @inline(__always)
    func recordSlide(_ translation: CGPoint, configuration: SlideGestureConfiguration) -> SlideGestureState.Update {
        slide.handleChanged(
            translation: CGSize(width: translation.x, height: translation.y), configuration: configuration
        )
    }

    /// The published candidate, if the finger is heading somewhere.
    var candidate: Candidate? {
        if case let .heading(candidate) = phase { return candidate }
        return nil
    }

    /// Moves between `resting` and `heading`. Returns whether anything
    /// changed, so the caller publishes only on a change; a finger that has
    /// slid or long-pressed is past speculating and ignores the call.
    func setCandidate(_ candidate: Candidate?) -> Bool {
        switch phase {
        case .sliding, .longPressed:
            return false
        case .resting, .heading:
            let next: Phase = candidate.map(Phase.heading) ?? .resting
            guard next != phase else { return false }
            phase = next
            return true
        }
    }

    /// The slide latched. Only a resting slide finger can latch.
    func markSliding() {
        if phase == .resting { phase = .sliding }
    }

    /// A long press typed; the release types nothing.
    func markLongPressed() {
        phase = .longPressed
    }

    /// Still close enough to its touch-down for a long press.
    func isResting(within tolerance: CGFloat) -> Bool {
        switch kind {
        case .flick:
            flick.isTracking && flick.maxDisplacement <= tolerance
        case .slide:
            phase != .sliding && slide.dragStarted && slide.maxDisplacement <= tolerance
        }
    }

    /// When this finger's hold on later commits runs out (touch-clock time).
    ///
    /// The one expression both the timer's deadline and `holdsBack` use: had
    /// the check been `time - pressTime < rolloverHold`, then at the deadline
    /// `(pressTime + 0.25) - pressTime` can round to 0.2499…, the hold would
    /// still stand at the moment it was armed to end, and the timer would
    /// re-arm for that same moment forever (the fuzz suite hung on it).
    var holdDeadline: TimeInterval {
        pressTime + TouchEngine.rolloverHold
    }

    /// Whether this finger holds back a completed gesture pressed after it:
    /// only an undecided finger, and only within the hold.
    @inline(__always)
    func holdsBack(_ laterSequence: UInt64, at time: TimeInterval) -> Bool {
        guard sequence < laterSequence, time < holdDeadline else { return false }
        switch phase {
        case .resting, .heading: return true
        case .sliding, .longPressed: return false
        }
    }

    func reset() {
        flick.handleCancelled()
        _ = slide.handleCancelled()
        longPressDeadline = nil
        phase = .resting
        key = .idle
        keyId = ""
    }
}

private extension SlidePhase {
    /// A release that types something (the space bar's tap, up- and down-swipe), as
    /// opposed to the end of a cursor or delete slide.
    var producesText: Bool {
        switch self {
        case .tap, .swipeUp, .swipeDown: true
        default: false
        }
    }
}

private extension KeyDefinition {
    /// What an idle pooled track holds between fingers.
    static let idle = KeyDefinition(
        id: "", bindings: [:], swipeMode: .none, slideType: .none, style: .utility, tapCycleActions: nil
    )
}

extension GestureCandidate {
    /// The feel layer's view of a track's published candidate.
    fileprivate init(_ candidate: PointerTrack.Candidate?) {
        self.init(
            gesture: candidate?.gesture,
            isReturn: candidate?.isReturn ?? false,
            isLongSwipe: candidate?.isLongSwipe ?? false
        )
    }
}
