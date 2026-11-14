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
/// map is rebuilt only when the layout changes, and finger tracks come from a
/// pool, so a touch allocates no bookkeeping of its own.
///
/// **Speculation.** While a finger moves, the engine classifies the path so far
/// on every event (a couple of microseconds) and publishes the gesture it is
/// heading for: the key emphasizes that hint and the guide card above the key
/// shows what releasing now would type (`KeyPressRegistry`, `TouchGuideOverlay`). The user sees the result before
/// lifting; the release only confirms it. Updates are change-driven, so a
/// steady flick costs no rendering after its direction settles.
///
/// **Rollover order.** With several fingers down, a gesture that completes
/// while an earlier-pressed finger is still undecided waits for that finger,
/// so text comes out in the order the keys were *pressed* — a fast "th" typed
/// with overlapping thumbs stays "th" even if the h-thumb lifts first. The wait
/// is bounded (`rolloverHold`): a thumb resting on the keyboard for longer than
/// that no longer holds the other thumb's typing back.
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
    static let rolloverHold: TimeInterval = 0.25

    /// Most fingers tracked at once; more are ignored, as on the system keyboard.
    static let maxPointers = 10

    private(set) var hitMap = KeyHitMap.empty
    private(set) var tuning = GestureTuning.default
    private var geometry: GridGeometry?
    private var size: CGSize = .zero
    private var keys: [String: KeyDefinition] = [:]
    private var actions = TouchEngineActions()
    private var isLongPressEnabled = false

    /// Fingers currently down, in press order.
    private var tracks: [PointerTrack] = []
    /// Released tracks, reused for the next touches.
    private var pool: [PointerTrack] = []
    /// Completed gestures waiting for an earlier finger (see "Rollover order").
    private var pending: [PendingCommit] = []
    private var flushTask: Task<Void, Never>?
    private var nextSequence: UInt64 = 0
    private let now: () -> TimeInterval

    /// - Parameter now: The clock touch timestamps are measured on (system
    ///   uptime, like `UITouch.timestamp` and `NSEvent.timestamp`).
    init(
        trail: GestureTrailRecorder = GestureTrailRecorder(),
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.trail = trail
        self.now = now
        pool.reserveCapacity(Self.maxPointers)
        tracks.reserveCapacity(Self.maxPointers)
        pending.reserveCapacity(Self.maxPointers)
    }

    // MARK: - Configuration

    /// Hands the engine the keyboard it is driving. Called by the view layer on
    /// every update; cheap when nothing changed. Keys that disappear from the
    /// layout (a mode or language switch) abandon their fingers, as a key view
    /// torn down mid-gesture used to.
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
            if let key = keys[track.keyId] {
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

        press.setPressed(true, keyId: key.id)
        if key.slideType == .none {
            press.setGuide(TouchGuide(keyId: key.id, keyFrame: hit.frame, touchID: track.sequence))
        }
        trail.begin(at: location, from: track.trailToken)
        actions.touchDown(key)
        track.record(.zero, slideActions: nil)
        scheduleLongPress(for: track)
    }

    /// A finger moved. `samples` are every position since the last event, in
    /// order (the coalesced touches); `predicted` are where the system expects
    /// it next, used for display only.
    func moved(_ id: PointerID, samples: [TouchSample], predicted: [CGPoint] = []) {
        guard let track = track(for: id), !track.longPress.consumedTouch else { return }
        for sample in samples {
            trail.extend(to: sample.location, from: track.trailToken)
            track.record(track.translation(to: sample.location)) { [actions] key, phase in
                actions.slide(key, phase)
            }
        }
        trail.predict(predicted, from: track.trailToken)
        // Long swipes: the trail takes the accent colour while letting go
        // would fire one. No work at all while they are off.
        if tuning.longSwipe.isEnabled, case .flick = track.kind, let last = samples.last {
            let translation = track.translation(to: last.location)
            trail.setLongSwipeArmed(
                tuning.longSwipe.isArmed(
                    translation: CGSize(width: translation.x, height: translation.y), keySize: track.keySize
                ),
                from: track.trailToken
            )
        }
        if track.longPress.isScheduled, !track.isResting(within: tuning.longPressMovementTolerance) {
            track.longPress.cancel()
        }
        speculate(track)
    }

    /// A finger lifted at `location`.
    func ended(_ id: PointerID, at location: CGPoint, time: TimeInterval) {
        guard let track = track(for: id) else { return }
        remove(track)
        track.longPress.cancel()
        release(track)

        if track.longPress.consumedTouch {
            // The long press already typed; the release types nothing.
            track.longPress.clearConsumed()
            recycle(track)
            flushPending(at: time)
            return
        }

        let translation = track.translation(to: location)
        switch track.kind {
        case .flick:
            let signposter = InputSignposts.signposter
            let interval = signposter.beginInterval(InputSignposts.classify)
            let classification = track.flick.handleEnded(
                translation: CGSize(width: translation.x, height: translation.y),
                aspectRatio: track.aspectRatio,
                tuning: tuning,
                keySize: track.keySize
            )
            signposter.endInterval(InputSignposts.classify, interval)
            trail.finish(from: track.trailToken)
            enqueue(PendingCommit(sequence: track.sequence, key: track.key, kind: .gesture(classification)), at: time)
        case let .slide(configuration):
            // Feed the release position as a final move first, as the drag
            // gesture did, so travel in the last frame is not lost.
            track.record(translation) { [actions] key, phase in actions.slide(key, phase) }
            let phase = track.slide.handleEnded(
                translation: CGSize(width: translation.x, height: translation.y),
                configuration: configuration
            )
            trail.finish(from: track.trailToken)
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
    }

    /// Fingers currently down.
    var activePointerCount: Int { tracks.count }

    /// Released tracks waiting for reuse.
    var pooledTrackCount: Int { pool.count }

    // MARK: - Speculation

    private func speculate(_ track: PointerTrack) {
        guard case .flick = track.kind else { return }
        let classification = KeyGestureRecognizer.classify(
            positions: track.flick.path, aspectRatio: track.aspectRatio, tuning: tuning, keySize: track.keySize
        )
        let candidate: GestureType? = classification.gesture == .tap ? nil : classification.gesture
        // A swipe that crosses the long-swipe threshold keeps its direction but
        // changes what it does, so that counts as a new target too.
        let isLongSwipe = tuning.longSwipe.isEnabled && tuning.longSwipe.action(for: classification) != nil
        guard candidate != track.candidate
            || classification.isReturn != track.candidateIsReturn
            || isLongSwipe != track.candidateIsLongSwipe
        else { return }
        track.candidate = candidate
        track.candidateIsReturn = classification.isReturn
        track.candidateIsLongSwipe = isLongSwipe
        press.setCandidate(candidate, isReturn: classification.isReturn, keyId: track.keyId)
        let label = candidate == nil ? nil : actions.previewLabel(track.key, classification)
        press.updateGuide(touchID: track.sequence) { guide in
            guide.candidate = candidate
            guide.isReturn = classification.isReturn
            guide.label = label
        }
    }

    // MARK: - Long press

    private func scheduleLongPress(for track: PointerTrack) {
        guard isLongPressEnabled else { return }
        let sequence = track.sequence
        track.longPress.schedule(after: tuning.longPressDuration) { [weak self, weak track] in
            guard let self, let track else { return false }
            return self.longPressFired(track, sequence: sequence)
        }
    }

    /// The fire guard: the finger is still the one that armed the timer and
    /// still resting, and a long-press binding resolved.
    private func longPressFired(_ track: PointerTrack, sequence: UInt64) -> Bool {
        guard track.sequence == sequence,
              tracks.contains(where: { $0 === track }),
              track.isResting(within: tuning.longPressMovementTolerance),
              actions.longPress(track.key)
        else { return false }
        trail.finish(from: track.trailToken)
        press.setCandidate(nil, isReturn: false, keyId: track.keyId)
        press.clearGuide(touchID: track.sequence)
        // A consumed finger no longer holds back later keystrokes.
        flushPending(at: now())
        return true
    }

    /// Runs the long-press timer for `id` now instead of after the delay —
    /// what the scenario harness uses to type a long press without waiting.
    func fireLongPressTimer(for id: PointerID) {
        guard isLongPressEnabled, let track = track(for: id) else { return }
        let sequence = track.sequence
        track.longPress.cancel()
        track.longPress.runFire { [weak self] in
            self?.longPressFired(track, sequence: sequence) ?? false
        }
    }

    // MARK: - Ordered commits

    private func enqueue(_ commit: PendingCommit, at time: TimeInterval) {
        let index = pending.firstIndex { $0.sequence > commit.sequence } ?? pending.endIndex
        pending.insert(commit, at: index)
        flushPending(at: time)
    }

    /// Dispatches waiting gestures in press order, stopping at the first one
    /// an earlier finger still holds back.
    private func flushPending(at time: TimeInterval) {
        while let head = pending.first {
            if let blocker = tracks.first(where: { $0.holdsBack(head.sequence, at: time) }) {
                scheduleFlush(at: blocker.pressTime + Self.rolloverHold)
                return
            }
            pending.removeFirst()
            switch head.kind {
            case let .gesture(classification): actions.gesture(head.key, classification)
            case let .slide(phase): actions.slide(head.key, phase)
            }
        }
        flushTask?.cancel()
        flushTask = nil
    }

    private func scheduleFlush(at deadline: TimeInterval) {
        flushTask?.cancel()
        let delay = max(deadline - now(), 0)
        flushTask = Task { [weak self] in
            do {
                try await Task.sleepWithoutLeeway(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            flushPending(at: now())
        }
    }

    /// Re-checks the waiting gestures at `time` (for tests driving a clock).
    func flushPendingCommits(at time: TimeInterval) {
        flushPending(at: time)
    }

    var pendingCommitCount: Int { pending.count }

    // MARK: - Track bookkeeping

    private func track(for id: PointerID) -> PointerTrack? {
        tracks.first { $0.id == id }
    }

    private func remove(_ track: PointerTrack) {
        tracks.removeAll { $0 === track }
    }

    private func release(_ track: PointerTrack) {
        // Another finger may still hold the same key.
        if !tracks.contains(where: { $0.keyId == track.keyId }) {
            press.setPressed(false, keyId: track.keyId)
        }
        press.clearGuide(touchID: track.sequence)
    }

    /// Drops a finger without a gesture: no text, a cancelled phase for a
    /// slide in flight, the trail cleared at once.
    private func abandon(_ track: PointerTrack) {
        remove(track)
        track.longPress.abandon()
        if case .slide = track.kind, let phase = track.slide.handleCancelled() {
            actions.slide(track.key, phase)
        }
        trail.cancel(from: track.trailToken)
        release(track)
        recycle(track)
        flushPending(at: now())
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

/// One finger's state, from touch-down to release. A class so the long-press
/// timer can read the live state at fire time, and pooled by the engine so a
/// touch allocates nothing: the sample buffer, the timer and the trail token
/// are created once per slot and reset between fingers.
@MainActor
private final class PointerTrack {
    enum Kind {
        case flick
        case slide(SlideGestureConfiguration)
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

    var flick = KeyGestureSequence()
    var slide = SlideGestureState()
    let longPress = LongPressScheduler()
    let trailToken = GestureTrailToken()

    var candidate: GestureType?
    var candidateIsReturn = false
    var candidateIsLongSwipe = false

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
    }

    func translation(to location: CGPoint) -> CGPoint {
        CGPoint(x: location.x - origin.x, y: location.y - origin.y)
    }

    /// Feeds one sample (relative to touch-down) to this finger's state
    /// machine; a slide key reports its phases through `slideActions`.
    func record(_ translation: CGPoint, slideActions: ((KeyDefinition, SlidePhase) -> Void)?) {
        let size = CGSize(width: translation.x, height: translation.y)
        switch kind {
        case .flick:
            _ = flick.handleChanged(translation: size)
        case let .slide(configuration):
            let update = slide.handleChanged(translation: size, configuration: configuration)
            if let slideActions {
                for phase in update.phases { slideActions(key, phase) }
            }
        }
    }

    /// Still close enough to its touch-down for a long press.
    func isResting(within tolerance: CGFloat) -> Bool {
        switch kind {
        case .flick:
            flick.isTracking && flick.maxDisplacement <= tolerance
        case .slide:
            slide.dragStarted && !slide.isSliding && slide.maxDisplacement <= tolerance
        }
    }

    /// Whether this finger holds back a completed gesture pressed after it.
    /// Only an undecided finger does: a fired long press has typed already,
    /// and a sliding space or delete key types nothing on release.
    func holdsBack(_ laterSequence: UInt64, at time: TimeInterval) -> Bool {
        guard sequence < laterSequence,
              time - pressTime < TouchEngine.rolloverHold,
              !longPress.consumedTouch
        else { return false }
        if case .slide = kind, slide.isSliding { return false }
        return true
    }

    func reset() {
        flick.handleCancelled()
        _ = slide.handleCancelled()
        longPress.abandon()
        longPress.clearConsumed()
        candidate = nil
        candidateIsReturn = false
        candidateIsLongSwipe = false
        key = .idle
        keyId = ""
    }
}

private extension SlidePhase {
    /// A release that types something (the space bar's tap and up-swipe), as
    /// opposed to the end of a cursor or delete slide.
    var producesText: Bool {
        switch self {
        case .tap, .swipeUp: true
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
