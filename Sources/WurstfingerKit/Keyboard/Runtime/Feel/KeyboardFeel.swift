//
//  KeyboardFeel.swift
//  Wurstfinger
//
//  Decides what each touch moment should feel and look like: the haptic cue
//  it plays and the transient visuals that confirm it.
//

import CoreGraphics
import Foundation
import Observation

/// The feel layer of one keyboard.
///
/// Fed by the input engine's feel hooks (`TouchEngineActions.candidateChanged`,
/// `.released`, `.longPressPhase`) and the view model's slide and state
/// changes, through `KeyboardViewModel+Feel.swift`. Everything is decided and
/// issued synchronously inside the call that reports the moment: a haptic is
/// one `start` per hit on a prebuilt player, a visual is one write to `board`.
/// It never decides what gets typed and nothing waits for it.
///
/// Every moment arrives as a `FeelStroke` the view model derived from the key
/// and the gesture (`FeelVoiceModel`); the methods that play one return it,
/// so the view model can sound the same stroke when key clicks are on —
/// haptics and sound from one value, so they cannot disagree.
///
/// The few decisions that are not a lookup live here so they can be tested
/// with a clock: which detent a target change is, how often detents and slide
/// ticks may fire, and how fast a slide is stepping.
@MainActor
final class KeyboardFeel {
    let haptics: HapticFeedbackPlayer
    /// The transient visuals the grid's feel overlay draws.
    let board = FeelBoard()
    /// Keeps a ProMotion display at full rate while a finger is busy.
    let boost: FrameRateBoost

    /// Shortest gap between two detents. Speculation can flip between two
    /// neighbouring sectors on consecutive samples while the finger sits on
    /// their border; past ~30 ms such flips stop reading as separate ticks
    /// and start reading as a rattle.
    static let detentSpacing: TimeInterval = 0.03

    /// Shortest gap between two slide ticks. A drag update can owe several
    /// caret steps at once; the Taptic Engine cannot render transients closer
    /// than ~10 ms apart as separate clicks, so the extra ones are dropped (the
    /// visual ratchet still counts every step).
    static let slideTickSpacing: TimeInterval = 0.012

    private let now: () -> TimeInterval
    private var lastDetent: TimeInterval = -.infinity
    private var lastSlideTick: TimeInterval = -.infinity
    private var lastSlideStep: TimeInterval?
    /// The key whose long press the swell and the ring currently belong to.
    private var longPressKeyId: String?
    /// The voice of the key a slide runs on, and its step count.
    private var slideVoice: KeyVoice?
    private var slideSteps = 0
    /// The mode the keyboard was in at the latest touch-down: the "from" of a
    /// mode change, which is reported after the switch.
    private(set) var modeAtTouchDown = ModeNames.main

    init(haptics: HapticFeedbackPlayer, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.haptics = haptics
        self.now = now
        boost = FrameRateBoost(now: now)
    }

    // MARK: - Touch-down

    /// A finger landed on a key in `mode`: its own voice.
    func touchDown(_ stroke: FeelStroke, mode: String) {
        boost.engage()
        modeAtTouchDown = mode
        haptics.prepareIfNeeded()
        haptics.play(stroke, as: .touchDown)
    }

    // MARK: - Flicks

    /// The haptic a target change earns, or nil for none. Pure, so the order
    /// of precedence is testable on its own: the long-swipe threshold beats a
    /// circle closing, which beats a return turn, which beats a plain detent.
    static func cue(from old: GestureCandidate, to new: GestureCandidate) -> HapticCue? {
        if new.isLongSwipe != old.isLongSwipe {
            return new.isLongSwipe ? .longSwipeArmed : .longSwipeDisarmed
        }
        if new.isCircle, !old.isCircle { return .circleClosed }
        if new.gesture == nil { return old.gesture == nil ? nil : .centerDetent }
        if new.isReturn, !old.isReturn, new.gesture == old.gesture { return .returnDetent }
        if new.gesture != old.gesture || new.isReturn != old.isReturn { return .directionDetent }
        return nil
    }

    /// A moving flick's target changed on a key with `voice`: the detent is
    /// the sector's own note (`FeelVoiceModel.detent`), so the eight
    /// directions of a key feel different from each other.
    func candidateChanged(from old: GestureCandidate, to new: GestureCandidate, voice: KeyVoice) {
        boost.engage()
        guard let cue = Self.cue(from: old, to: new) else { return }
        switch cue {
        case .directionDetent, .centerDetent, .returnDetent:
            let time = now()
            guard time - lastDetent >= Self.detentSpacing else { return }
            lastDetent = time
            haptics.play(FeelVoiceModel.detent(cue, voice: voice, direction: new.gesture), as: cue)
        case .circleClosed:
            lastDetent = now()
            haptics.play(FeelVoiceModel.detent(cue, voice: voice, direction: new.gesture), as: cue)
        default:
            // The long-swipe thresholds are designed patterns (a thunk with a
            // tail), the same on every key: they mean the same everywhere.
            // Never swallowed by the detent spacing.
            lastDetent = now()
            haptics.play(cue)
        }
    }

    /// A finger lifted and its gesture will commit as `commitType`, sounding
    /// and feeling like `stroke`. `pop` is the glyph lifting off the guide
    /// card (nil for none); `clicks` is false when the committed action
    /// confirms itself with its own cue.
    ///
    /// Only recorded here: the input engine reports the release before it
    /// hands the keystroke on, and `flushRelease` issues the click and the pop
    /// after, so feedback never goes out ahead of the text.
    func released(_ commitType: CommitType, stroke: FeelStroke, clicks: Bool = true, pop: FeelBoard.Pop?) {
        pendingRelease = PendingRelease(commitType: commitType, stroke: stroke, clicks: clicks, pop: pop)
    }

    /// Issues the release recorded by `released`, if any. Returns the stroke
    /// it played, for the key sound.
    @discardableResult
    func flushRelease() -> FeelStroke? {
        guard let release = pendingRelease else { return nil }
        pendingRelease = nil
        boost.engage()
        if let pop = release.pop { board.add(pop) }
        guard release.clicks else { return nil }
        if release.commitType == .longSwipe {
            // A designed pattern with a continuous tail; the stroke still
            // gives the sound.
            haptics.play(.commit(.longSwipe))
        } else {
            haptics.play(release.stroke, as: .commit(release.commitType))
        }
        return release.stroke
    }

    private struct PendingRelease {
        var commitType: CommitType
        var stroke: FeelStroke
        var clicks: Bool
        var pop: FeelBoard.Pop?
    }

    private var pendingRelease: PendingRelease?

    /// The key-sound family of the pending release (set by the view model,
    /// which knows what it types).
    var releaseClick = KeyClick.character

    // MARK: - Long press

    /// A long press was armed on a key that can long-press: schedule the
    /// swell to end where the press fires, and show the ring.
    func longPressArmed(keyId: String, keyFrame: CGRect, delay: TimeInterval) {
        boost.engage()
        if longPressKeyId != nil { haptics.stop(.longPressRamp) }
        longPressKeyId = keyId
        haptics.play(.longPressRamp, after: max(delay - LongPressFeel.rampDuration, 0))
        board.showRing(keyId: keyId, keyFrame: keyFrame, duration: delay)
    }

    func longPressCancelled(keyId: String) {
        guard longPressKeyId == keyId else { return }
        longPressKeyId = nil
        haptics.stop(.longPressRamp)
        board.hideRing(keyId: keyId)
    }

    /// The long press fired: the swell resolves into the stroke (the octave
    /// above the key). Returns it, for the key sound.
    @discardableResult
    func longPressFired(keyId: String, stroke: FeelStroke, pop: FeelBoard.Pop?) -> FeelStroke {
        boost.engage()
        if longPressKeyId == keyId {
            longPressKeyId = nil
            haptics.stop(.longPressRamp)
            board.fireRing(keyId: keyId)
        }
        haptics.play(stroke, as: .commit(.longPress))
        if let pop { board.add(pop) }
        return stroke
    }

    // MARK: - Slides

    func slideBegan(_ slideType: SlideType, keyId: String, keyFrame: CGRect?, voice: KeyVoice) {
        lastSlideStep = nil
        slideVoice = voice
        slideSteps = 0
        boost.engage()
        guard let keyFrame else { return }
        board.beginRatchet(slideType, keyId: keyId, keyFrame: keyFrame)
    }

    /// One step of a slide: `direction` is -1 (caret left / delete backward)
    /// or +1. The tick's strength follows the slide's pace, its note the
    /// direction (`FeelVoiceModel.slideStep`). Returns the stroke when one
    /// played (steps in one burst share a tick), for the key sound.
    @discardableResult
    func slideStep(_ slideType: SlideType, direction: Int) -> FeelStroke? {
        let time = now()
        let pace = SlidePace.forStepGap(lastSlideStep.map { time - $0 })
        lastSlideStep = time
        slideSteps &+= 1
        boost.engage()
        board.stepRatchet(by: direction)
        guard time - lastSlideTick >= Self.slideTickSpacing else { return nil }
        lastSlideTick = time
        let cue: HapticCue = slideType == .delete ? .deleteTick : .cursorTick(pace)
        guard let voice = slideVoice else {
            haptics.play(cue)
            return nil
        }
        let stroke = FeelVoiceModel.slideStep(slideType, voice: voice, direction: direction, pace: pace, step: slideSteps)
        haptics.play(stroke, as: cue)
        return stroke
    }

    func slideEnded() {
        lastSlideStep = nil
        slideVoice = nil
        board.endRatchet()
    }

    // MARK: - State changes

    /// The keyboard switched to `mode` (from the mode of the latest
    /// touch-down): two notes, up into it or down out of it. Returns the
    /// stroke, for the key sound.
    @discardableResult
    func modeChanged(to mode: String) -> FeelStroke {
        let stroke = FeelVoiceModel.modeChange(from: modeAtTouchDown, to: mode)
        modeAtTouchDown = mode
        haptics.play(stroke, as: .modeSwitch)
        return stroke
    }

    /// Language switches, dismissal, clipboard successes (a mode change knows
    /// its modes: `modeChanged(to:)`). Returns the stroke that sounds the
    /// moment, if it has one.
    @discardableResult
    func play(_ cue: HapticCue) -> FeelStroke? {
        switch cue {
        case .languageSwitch:
            haptics.play(FeelVoiceModel.languageChange, as: cue)
            return FeelVoiceModel.languageChange
        case .clipboardSuccess:
            haptics.play(cue)
            return FeelVoiceModel.clipboard
        case .dismiss:
            haptics.play(cue)
            return FeelVoiceModel.dismiss
        default:
            haptics.play(cue)
            return nil
        }
    }
}

/// The transient visuals of the feel layer, for the grid's feel overlay.
///
/// Each property is drawn by its own overlay layer, which reads only that
/// property: a commit re-renders the pop layer, a long press the ring, a slide
/// step the ratchet — never a key. Every write is a single assignment made in
/// the call that reported the moment.
@MainActor
@Observable
final class FeelBoard {
    /// A committed glyph lifting off its key.
    struct Pop: Identifiable, Equatable, Sendable {
        var id: UInt64 = 0
        var text: String
        /// The key's touch frame, in the grid's coordinate space.
        var keyFrame: CGRect
        /// The gesture that committed it: the pop starts where that gesture's
        /// hint sits on the key (the centre for a tap, a circle or a return).
        var gesture: GestureType
        /// A long swipe's action glyph rather than typed text.
        var isAction = false
        /// When it was added (system uptime), to drop pops nobody drew.
        var time: TimeInterval = 0
    }

    /// The long-press progress ring.
    struct Ring: Equatable, Sendable {
        var id: UInt64
        var keyId: String
        var keyFrame: CGRect
        /// Time from touch-down to the long press firing.
        var duration: TimeInterval
        var hasFired = false
    }

    /// The detent strip on a sliding space or delete key.
    struct Ratchet: Equatable, Sendable {
        /// `.moveCursor` (the space bar) or `.delete`.
        var slideType: SlideType
        var keyId: String
        var keyFrame: CGRect
        /// Net steps taken, positive to the right.
        var steps = 0
        /// The direction of the last step.
        var lastDirection = 0
    }

    /// Most pops drawn at once; fast typing never stacks more than this.
    static let maxPops = 4
    /// A pop older than this is dropped on the next insertion even if its
    /// animation never reported completion (the overlay was off screen).
    static let popLifetime: TimeInterval = 1

    /// The pops on screen, oldest first. Kept in `popStorage` and mutated in
    /// place: a commit used to build a filtered copy of the array per pop,
    /// which was an allocation on every swipe keystroke.
    var pops: [Pop] {
        access(keyPath: \.pops)
        return popStorage
    }

    @ObservationIgnored private var popStorage: [Pop] = {
        var pops: [Pop] = []
        pops.reserveCapacity(FeelBoard.maxPops + 1)
        return pops
    }()

    private(set) var ring: Ring?
    private(set) var ratchet: Ratchet?

    @ObservationIgnored private var nextID: UInt64 = 0
    @ObservationIgnored private let now: () -> TimeInterval

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    func add(_ pop: Pop) {
        nextID &+= 1
        var pop = pop
        pop.id = nextID
        pop.time = now()
        withMutation(keyPath: \.pops) {
            popStorage.removeAll { pop.time - $0.time >= Self.popLifetime }
            if popStorage.count >= Self.maxPops {
                popStorage.removeFirst(popStorage.count - Self.maxPops + 1)
            }
            popStorage.append(pop)
        }
    }

    /// The overlay's pop animation finished.
    func removePop(id: UInt64) {
        guard let index = popStorage.firstIndex(where: { $0.id == id }) else { return }
        withMutation(keyPath: \.pops) {
            _ = popStorage.remove(at: index)
        }
    }

    func showRing(keyId: String, keyFrame: CGRect, duration: TimeInterval) {
        nextID &+= 1
        ring = Ring(id: nextID, keyId: keyId, keyFrame: keyFrame, duration: duration)
    }

    func hideRing(keyId: String) {
        guard ring?.keyId == keyId else { return }
        ring = nil
    }

    func fireRing(keyId: String) {
        guard var current = ring, current.keyId == keyId, !current.hasFired else { return }
        current.hasFired = true
        ring = current
    }

    /// The overlay's fired-ring flash finished.
    func clearRing(id: UInt64) {
        guard ring?.id == id else { return }
        ring = nil
    }

    func beginRatchet(_ slideType: SlideType, keyId: String, keyFrame: CGRect) {
        ratchet = Ratchet(slideType: slideType, keyId: keyId, keyFrame: keyFrame)
    }

    func stepRatchet(by direction: Int) {
        guard var current = ratchet else { return }
        current.steps += direction
        current.lastDirection = direction
        ratchet = current
    }

    func endRatchet() {
        if ratchet != nil { ratchet = nil }
    }
}
