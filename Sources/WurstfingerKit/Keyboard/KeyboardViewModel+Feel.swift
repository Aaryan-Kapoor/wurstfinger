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
    /// What the release does, for the instrument of its stroke (a flick that
    /// types punctuation sounds glassy on a letter key).
    var action: KeyAction?
}

extension KeyboardViewModel {
    // MARK: - Voices

    /// A key's voice in the current layout and mode: its role, the centre of
    /// its touch frame within the grid, the active mode
    /// (`FeelVoiceModel.voice`). Arithmetic and two lookups (the key's tap
    /// binding, its frame by id) — cheap enough for every touch, and nothing
    /// to rebuild when the layout changes.
    func keyVoice(for key: KeyDefinition) -> KeyVoice {
        let hitMap = touchEngine.hitMap
        let frame = hitMap.key(withId: key.id)?.frame ?? .zero
        return FeelVoiceModel.voice(role: KeyRole(key: key), keyFrame: frame, gridSize: hitMap.size, mode: activeModeName)
    }

    /// Plays `stroke` as a key sound when key clicks are on (`KeyClickPlayer`).
    private func sound(_ stroke: FeelStroke?, as click: KeyClick) {
        guard let stroke, stroke.isAudible, typingBehavior.areKeyClicksEnabled else { return }
        keyClicks.play(click, stroke)
    }

    // MARK: - Engine hooks

    /// A finger landed on `key`: its own voice, felt and (with key clicks
    /// on) heard — one stroke for both, so they agree.
    func feelTouchDown(_ key: KeyDefinition) {
        let stroke = FeelVoiceModel.touchDown(keyVoice(for: key))
        feel.touchDown(stroke, mode: activeModeName)
        sound(stroke, as: KeyClick(for: key))
    }

    /// The speculative target of a flick changed.
    func feelCandidateChanged(on key: KeyDefinition, from old: GestureCandidate, to new: GestureCandidate) {
        feel.candidateChanged(from: old, to: new, voice: keyVoice(for: key))
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
        let displacement = classification.displacementInKeys
        let stroke = FeelVoiceModel.commit(
            commit.commitType, voice: keyVoice(for: key), direction: classification.gesture,
            isReturn: classification.isReturn, reach: hypot(displacement.dx, displacement.dy),
            typing: commit.action
        )
        feel.released(
            commit.commitType, stroke: stroke, clicks: commit.clicks,
            pop: pop(commit, key: key, gesture: classification.gesture)
        )
        feel.releaseClick = KeyClick(typing: commit.action)
    }

    /// The release recorded by `feelReleased` has been handed on: its click,
    /// pop and sound go out now, after the text.
    func feelFlushRelease() {
        sound(feel.flushRelease(), as: feel.releaseClick)
    }

    // MARK: - Lifecycle

    /// Starts the key sounds' audio graph when the keyboard appears, if key
    /// clicks are on (in the background; nothing waits for it).
    func prepareKeySounds() {
        if typingBehavior.areKeyClicksEnabled { KeySoundEngine.shared.prepare() }
    }

    /// The keyboard went away: stop the audio graph and the frame-rate boost.
    func suspendFeel() {
        KeySoundEngine.shared.suspend()
        feel.boost.stop()
    }

    /// A long press was armed, cancelled or fired on `key`.
    func feelLongPress(_ key: KeyDefinition, phase: LongPressFeelPhase) {
        switch phase {
        case let .armed(keyFrame, delay):
            // Only keys whose hold would type something get the swell and the
            // ring; on the others a rest is just a slow tap.
            guard isTyping(.longPress, keyId: key.id) else { return }
            feel.longPressArmed(keyId: key.id, keyFrame: keyFrame, delay: delay)
        case .cancelled:
            feel.longPressCancelled(keyId: key.id)
        case .fired:
            // An inert hold (nothing was armed for it) has nothing to confirm.
            guard isTyping(.longPress, keyId: key.id) else { return }
            let text = previewLabel(for: .longPress, keyId: key.id, isReturn: false)
            let commit = text.map { CommitFeel(commitType: .longPress, popText: $0) }
            let typed = resolvedAction(for: .longPress, keyId: key.id, isReturn: false)
            let stroke = FeelVoiceModel.commit(
                .longPress, voice: keyVoice(for: key), direction: .longPress, isReturn: false, reach: 0, typing: typed
            )
            let played = feel.longPressFired(
                keyId: key.id, stroke: stroke,
                pop: commit.flatMap { pop($0, key: key, gesture: .tap) }
            )
            sound(played, as: KeyClick(typing: typed))
        }
    }

    // MARK: - Slides and state changes

    /// A space or delete slide started moving.
    func feelSlideBegan(_ slideType: SlideType, key: KeyDefinition) {
        feel.slideBegan(
            slideType, keyId: key.id, keyFrame: touchEngine.hitMap.key(withId: key.id)?.frame,
            voice: keyVoice(for: key)
        )
    }

    /// One caret step or one deleted character.
    func feelSlideStep(_ slideType: SlideType, direction: Int) {
        sound(feel.slideStep(slideType, direction: direction), as: slideType == .delete ? .delete : .modifier)
    }

    func feelSlideEnded() {
        feel.slideEnded()
    }

    /// A state change the user should feel (mode, language, dismissal,
    /// clipboard). A mode change plays the step from the mode of the latest
    /// touch-down into the one now active.
    func feel(_ cue: HapticCue) {
        if cue == .modeSwitch {
            sound(feel.modeChanged(to: activeModeName), as: .modifier)
        } else {
            sound(feel.play(cue), as: .modifier)
        }
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
                clicks: HapticCue.forPipelineAction(action) == nil, action: action
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
        case .none:
            // An inert binding (the globe's tap, a key the one-shot Ctrl mode
            // has no use for) types nothing, so its release clicks for nothing.
            return nil
        case let .commitText(text):
            return CommitFeel(commitType: commitType, popText: text.isEmpty || text == " " ? nil : text, action: action)
        case let .compose(trigger):
            return CommitFeel(commitType: commitType, popText: trigger, action: action)
        default:
            return CommitFeel(commitType: commitType, popText: nil, action: action)
        }
    }

    /// Whether `gesture` on `keyId` is bound to something that does anything:
    /// a binding is there and it is not the inert `.none`.
    private func isTyping(_ gesture: GestureType, keyId: String) -> Bool {
        guard let action = resolvedAction(for: gesture, keyId: keyId, isReturn: false) else { return false }
        return action != .none
    }

    /// The action `gesture` on `keyId` resolves to in the active mode, as
    /// `performGesture` resolves it (circles included) — a lookup in the
    /// compiled tables, like the guide's preview.
    func resolvedAction(for gesture: GestureType, keyId: String, isReturn: Bool) -> KeyAction? {
        guard let compiled = activeCompiledMode,
              let slot = compiled.slot(for: keyId)
        else { return nil }
        if gesture.isCircular {
            switch resolvedCircle(in: compiled, slot: slot, gesture: gesture) {
            case let .binding(index): return compiled.binding(at: index).action
            case let .commitUppercase(text): return .commitText(text)
            case .capitalizeWord: return .capitalizeWord(uppercased: true)
            case .none: return nil
            }
        }
        return resolvedBinding(in: compiled, slot: slot, gesture: gesture, isReturn: isReturn)?.action
    }

    /// The glyph lifting off the guide card for `commit`, from the cell the
    /// card lit for it. Taps get none: their glyph is the key's own label
    /// (see `CommitPopView`); nor does a sensitive field (`FieldTraits`).
    private func pop(_ commit: CommitFeel, key: KeyDefinition, gesture: GestureType) -> FeelBoard.Pop? {
        guard commit.commitType != .tap,
              !fieldTraits.isSensitive,
              let text = commit.popText,
              let frame = touchEngine.hitMap.key(withId: key.id)?.frame
        else { return nil }
        // The card lights the direction's cell for swipes, return swipes and
        // long swipes, and the centre for circles and long presses.
        let cell: GestureType = gesture.isSwipe ? gesture : .tap
        return FeelBoard.Pop(text: text, keyFrame: frame, gesture: cell, isAction: commit.isAction)
    }
}
