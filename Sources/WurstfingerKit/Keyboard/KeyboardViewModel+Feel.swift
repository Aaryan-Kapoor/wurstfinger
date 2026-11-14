//
//  KeyboardViewModel+Feel.swift
//  Wurstfinger
//
//  The view model's side of the feel layer: resolves what a touch moment
//  means for this keyboard (would the release type something, and what?) and
//  hands it to `KeyboardFeel`.
//

import CoreGraphics
import Foundation

/// What a release is about to commit, for its click and its pop.
struct CommitFeel: Equatable, Sendable {
    var commitType: CommitType
    /// The glyph that lifts off the key, or nil for none (spaces, deletions,
    /// cursor moves and other actions that type nothing visible).
    var popText: String?
    /// The pop shows an action glyph (a long swipe) rather than typed text.
    var isAction = false
    /// Whether the release clicks. False for a long swipe whose action the
    /// pipeline confirms with its own cue (dismissal, a mode or language
    /// switch), so one release never plays two patterns.
    var clicks = true
}

extension KeyboardViewModel {
    // MARK: - Engine hooks

    /// The speculative target of a flick changed.
    func feelCandidateChanged(on _: KeyDefinition, from old: GestureCandidate, to new: GestureCandidate) {
        feel.candidateChanged(from: old, to: new)
    }

    /// A finger lifted: resolves the click and pop for what it will commit,
    /// before the keystroke is dispatched (which can change the mode — a
    /// shifted letter releases shift). They are issued by
    /// `KeyboardFeel.flushRelease` once the keystroke has gone out, in the
    /// same touch event — even when rollover ordering holds the keystroke
    /// itself back for an earlier finger, so the release is felt when it
    /// happens.
    func feelReleased(_ key: KeyDefinition, classification: GestureClassification) {
        guard let commit = commitFeel(for: classification, keyId: key.id) else { return }
        feel.released(commit.commitType, clicks: commit.clicks, pop: pop(commit, key: key, gesture: classification.gesture))
    }

    /// A long press was armed, cancelled or fired on `key`.
    func feelLongPress(_ key: KeyDefinition, phase: LongPressFeelPhase) {
        switch phase {
        case let .armed(keyFrame, delay):
            // Only keys whose hold would type something get the swell and the
            // ring; on the others a rest is just a slow tap.
            guard previewLabel(for: .longPress, keyId: key.id, isReturn: false) != nil else { return }
            feel.longPressArmed(keyId: key.id, keyFrame: keyFrame, delay: delay)
        case .cancelled:
            feel.longPressCancelled(keyId: key.id)
        case .fired:
            let text = previewLabel(for: .longPress, keyId: key.id, isReturn: false)
            let commit = text.map { CommitFeel(commitType: .longPress, popText: $0) }
            feel.longPressFired(
                keyId: key.id,
                pop: commit.flatMap { pop($0, key: key, gesture: .tap) }
            )
        }
    }

    // MARK: - Slides and state changes

    /// A space or delete slide started moving.
    func feelSlideBegan(_ slideType: SlideType, key: KeyDefinition) {
        feel.slideBegan(slideType, keyId: key.id, keyFrame: touchEngine.hitMap.key(withId: key.id)?.frame)
    }

    /// One caret step or one deleted character.
    func feelSlideStep(_ slideType: SlideType, direction: Int) {
        feel.slideStep(slideType, direction: direction)
    }

    func feelSlideEnded() {
        feel.slideEnded()
    }

    /// A state change the user should feel (mode, language, dismissal,
    /// clipboard).
    func feel(_ cue: HapticCue) {
        feel.play(cue)
    }

    // MARK: - Resolution

    /// What releasing with `classification` on `keyId` commits, resolved
    /// exactly as `handleClassification` will resolve it, without dispatching
    /// anything. Nil when the release does nothing (an unbound direction) or
    /// when the action confirms itself with its own cue (mode and language
    /// switches, dismissal), so a keystroke never plays two patterns at once.
    func commitFeel(for classification: GestureClassification, keyId: String) -> CommitFeel? {
        if let action = gestureTuning.longSwipe.action(for: classification) {
            return CommitFeel(
                commitType: .longSwipe, popText: action.previewGlyph, isAction: true,
                clicks: HapticCue.forPipelineAction(action) == nil
            )
        }
        let gesture = classification.gesture
        guard let action = resolvedAction(for: gesture, keyId: keyId, isReturn: classification.isReturn) else {
            return nil
        }
        let commitType: CommitType = switch gesture {
        case .tap: .tap
        case .circularClockwise, .circularCounterclockwise: .circle
        case .longPress: .longPress
        default: classification.isReturn ? .returnSwipe : .swipe
        }
        switch action {
        case .switchMode, .switchToNextLanguage, .advanceToNextInputMode, .dismissKeyboard:
            return nil
        case let .commitText(text):
            return CommitFeel(commitType: commitType, popText: text.isEmpty || text == " " ? nil : text)
        case let .compose(trigger):
            return CommitFeel(commitType: commitType, popText: trigger)
        default:
            return CommitFeel(commitType: commitType, popText: nil)
        }
    }

    /// The action `gesture` on `keyId` resolves to in the active mode, as
    /// `performGesture` resolves it (circles included).
    private func resolvedAction(for gesture: GestureType, keyId: String, isReturn: Bool) -> KeyAction? {
        guard let mode = activeModeFromDefinition else { return nil }
        if gesture == .circularClockwise || gesture == .circularCounterclockwise {
            guard let key = mode.key(for: keyId) else { return nil }
            if let binding = key.bindings[gesture] { return binding.action }
            if let tap = key.bindings[.tap], case let .commitText(text) = tap.action, text.first?.isLetter == true {
                return .commitText(text.keyboardUppercased(with: pipelineLocale ?? Locale.current))
            }
            let opposite: GestureType = gesture == .circularClockwise ? .circularCounterclockwise : .circularClockwise
            return key.bindings[opposite]?.action
        }
        let chain = isReturn ? returnSwipeResolverChain : resolverChain
        return chain?.resolve(keyId: keyId, gesture: gesture, in: mode)?.action
    }

    /// The glyph lifting off the guide card for `commit`, from the cell the
    /// card lit for it. Taps get none: their glyph is the key's own label
    /// (see `CommitPopView`).
    private func pop(_ commit: CommitFeel, key: KeyDefinition, gesture: GestureType) -> FeelBoard.Pop? {
        guard commit.commitType != .tap,
              let text = commit.popText,
              let frame = touchEngine.hitMap.key(withId: key.id)?.frame
        else { return nil }
        // The card lights the direction's cell for swipes, return swipes and
        // long swipes, and the centre for circles and long presses.
        let cell: GestureType = gesture.isSwipe ? gesture : .tap
        return FeelBoard.Pop(text: text, keyFrame: frame, gesture: cell, isAction: commit.isAction)
    }
}
