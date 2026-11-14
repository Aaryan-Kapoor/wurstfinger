//
//  GestureTrailRecorder.swift
//  Wurstfinger
//
//  Collects touch positions for the gesture trail and tells the overlay when
//  there is something to draw.
//

import CoreGraphics
import Foundation
import Observation
import SwiftUI

/// Identity of one gesture modifier, used to decide which touch sequence owns
/// the shared trail. Each recognizer holds its own in `@State`, so it is stable
/// for as long as that key exists. It has no state and observes nothing; only
/// its object identity matters (the recorder compares tokens with `===`).
final class GestureTrailToken {}

/// Per-keyboard collector for the gesture trail.
///
/// Owned by `KeyboardGridView`, fed by the gesture modifiers with positions in
/// the shared `coordinateSpace`, and read by `GestureTrailOverlay`.
///
/// It tracks only `isVisible`, which flips at most twice per gesture. The
/// sample buffer itself is a plain, unobserved property that the overlay
/// re-reads every frame from its `TimelineView`. Observing per sample would
/// invalidate every reader at the drag sample rate — up to 120 Hz — and the
/// grid owns this object, so that would re-render all ~40 keys per sample.
/// With Observation only a view whose body *reads* `isVisible` (the overlay) is
/// invalidated by its flips; the grid never reads it, so the old
/// `GestureTrailStore` indirection (a non-publishing holder that kept the grid
/// from subscribing) is no longer needed.
///
/// Main-actor: it is fed by the gesture modifiers on the main thread and its
/// fade-out is a main-actor task.
@MainActor
@Observable
final class GestureTrailRecorder {
    /// The coordinate space every recorded point is expressed in. Registered
    /// by `KeyboardGridView` on the grid layout, which is both an ancestor of
    /// every `KeyView` and the exact bounds the overlay draws in, so recorded
    /// points need no offset correction to be drawn.
    static let coordinateSpace = NamedCoordinateSpace.named("wurstfinger.gestureTrail")

    /// Whether the overlay should be rendering. True from the moment a touch
    /// goes down with the setting on — a press that never moves is drawn as
    /// the head of the trail standing still — and false while the setting is
    /// off or once the fade-out has finished.
    private(set) var isVisible = false

    /// The trail to draw. Unobserved, so drag samples cannot invalidate the
    /// grid; the overlay re-reads it each frame.
    @ObservationIgnored private(set) var trail = GestureTrail()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> TimeInterval

    /// The trail setting as last told by the keyboard (from its
    /// `GestureTuning` snapshot), or `nil` when nobody has told it — previews
    /// and tests, which fall back to reading `defaults` once per touch. Set by
    /// `KeyboardGridView`, so in the real keyboard the touch-down path never
    /// reads `UserDefaults`.
    @ObservationIgnored private var enabledSnapshot: Bool?

    /// Hands the recorder the current trail setting. Called when the grid
    /// appears and whenever the settings snapshot changes.
    func useEnabledSetting(_ isEnabled: Bool) {
        enabledSnapshot = isEnabled
    }

    /// Whether the setting was on when the current touch went down. Sampled
    /// once per gesture so a toggle flipped mid-swipe cannot leave a
    /// half-recorded trail behind.
    @ObservationIgnored private var isRecording = false

    /// The gesture modifier whose touch sequence currently owns the trail.
    ///
    /// One recorder is shared by every key, and on a thumb keyboard two touch
    /// sequences overlap routinely. Without an owner the second thumb's touch
    /// down would restart the stroke and its release would freeze it, so the
    /// trail would jump between the fingers and vanish under the one still
    /// moving. Weak, so a key torn down mid-gesture releases the trail rather
    /// than blocking it forever.
    @ObservationIgnored private weak var owner: GestureTrailToken?

    /// The pending fade-out. A cancellable task rather than a work item: it
    /// sleeps on the main actor and then clears the trail, and cancelling it
    /// (a new touch, a cancel) is `Task.cancel()`.
    @ObservationIgnored private var fadeOut: Task<Void, Never>?

    init(
        defaults: UserDefaults = SharedDefaults.store,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.defaults = defaults
        self.now = now
    }

    /// Starts recording a new touch sequence. `token` identifies the
    /// recognizer it came from.
    func begin(at location: CGPoint, from token: GestureTrailToken) {
        // First finger down wins the trail and keeps it until its sequence
        // ends. A concurrent second touch is ignored rather than drawn as
        // a second trail: one stroke matches the system keyboard, and the
        // overlay renders a single path.
        guard owner == nil else { return }
        owner = token
        beginTouch(at: location)
    }

    /// Records one drag sample of the sequence started by `begin`.
    func extend(to location: CGPoint, from token: GestureTrailToken) {
        guard owner === token, isRecording else { return }
        trail.extend(to: location, time: now())
    }

    /// Ends the current touch: the trail freezes where the finger left it and
    /// fades out. A tap freezes as its dot, which is the only feedback this
    /// keyboard gives for a press — it has no key pop-up.
    func finish(from token: GestureTrailToken) {
        guard owner === token else { return }
        // Released before the `isRecording` check so a touch taken while the
        // setting was off still hands the trail back to the next gesture.
        owner = nil
        guard isRecording else { return }
        isRecording = false
        trail.release(at: now())
        scheduleFadeOut()
    }

    /// Discards the trail immediately, without a fade. Used for the paths that
    /// end a touch without a gesture: a system cancellation and the teardown
    /// of a key that was mid-gesture (which reaches neither `onEnded` nor the
    /// cancel path).
    func cancel(from token: GestureTrailToken) {
        // Also gates the recognizers' unconditional cancel paths: a key whose
        // gesture never started is not the owner and must not clear a trail
        // another key is drawing.
        guard owner === token else { return }
        owner = nil
        isRecording = false
        fadeOut?.cancel()
        fadeOut = nil
        trail.clear()
        setVisible(false)
    }

    // MARK: - Private

    private func beginTouch(at location: CGPoint) {
        fadeOut?.cancel()
        fadeOut = nil
        trail.clear()
        setVisible(false)
        // The setting is sampled per touch from the snapshot the grid keeps
        // current (a host-app toggle reaches it through the settings reload),
        // never observed: observing it would re-render every key for a value
        // only a touch-down consults. Without a snapshot (previews, tests) it
        // is read from the store, once per touch.
        isRecording = enabledSnapshot ?? defaults.bool(forKey: SettingsKey.gestureTrailEnabled.rawValue)
        guard isRecording else { return }
        trail.begin(at: location, time: now())
        setVisible(true)
    }

    private func scheduleFadeOut() {
        fadeOut = Task { [weak self] in
            do {
                try await Task.sleepWithoutLeeway(for: .seconds(KeyboardConstants.GestureTrail.fadeOutDuration))
            } catch {
                return // a new touch or a cancel took over the trail
            }
            // Re-checked on the main actor: a cancel that landed between the
            // sleep ending and this step must not clear the *next* trail.
            guard !Task.isCancelled, let self else { return }
            fadeOut = nil
            trail.clear()
            setVisible(false)
        }
    }

    /// Assigns only on an actual transition: the recorder is observed by the
    /// overlay, so a redundant write per drag sample would invalidate it at
    /// the drag sample rate.
    private func setVisible(_ value: Bool) {
        guard isVisible != value else { return }
        isVisible = value
    }
}
