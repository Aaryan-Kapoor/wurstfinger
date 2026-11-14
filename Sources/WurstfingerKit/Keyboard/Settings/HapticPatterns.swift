//
//  HapticPatterns.swift
//  Wurstfinger
//
//  The keyboard's haptic vocabulary: every moment a finger should feel, and
//  the pattern designed for it. Pure data — the players (`CoreHapticsPlayer`,
//  the UIKit generators) only render what is described here.
//

import CoreGraphics
import Foundation

// MARK: - Cues

/// How a released gesture committed, for the commit click (the closed set
/// of commit variants, hence `…Type`).
///
/// Each kind gets its own transient so the hand learns the difference without
/// looking: a tap releases softly, a flick snaps, a return swipe bounces, a
/// circle rolls, a long swipe or long press lands with weight.
enum CommitType: Hashable, Sendable, CaseIterable {
    case tap
    case swipe
    case returnSwipe
    case circle
    case longSwipe
    case longPress
}

/// How fast a slide (cursor or delete) is stepping, measured from the gap
/// between two steps. Fast scrubbing gets lighter, softer ticks so it reads as
/// a fine texture instead of a buzz; slow, deliberate steps get full detents.
enum SlidePace: Int, Hashable, Sendable, CaseIterable, Comparable {
    /// More than 90 ms between steps: placing the caret character by character.
    case deliberate
    /// 45–90 ms.
    case steady
    /// 22–45 ms.
    case brisk
    /// Under 22 ms: a fling across a word.
    case rapid

    /// Classifies the gap since the previous step (nil for the first step).
    static func forStepGap(_ gap: TimeInterval?) -> SlidePace {
        guard let gap else { return .deliberate }
        switch gap {
        case ..<0.022: return .rapid
        case ..<0.045: return .brisk
        case ..<0.09: return .steady
        default: return .deliberate
        }
    }

    static func < (lhs: SlidePace, rhs: SlidePace) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A moment the keyboard confirms through touch. One cue, one pattern
/// (`HapticPatternSpec.pattern(for:)`); the player renders it.
enum HapticCue: Hashable, Sendable {
    /// A finger landed on a key.
    case touchDown
    /// A gesture was released and will type or do something.
    case commit(CommitType)
    /// The flick's speculative target moved to another of the eight directions.
    case directionDetent
    /// The flick came back to the key's centre: releasing now is a tap again.
    case centerDetent
    /// The flick turned back toward its origin: releasing now is a return swipe.
    case returnDetent
    /// The loop closed: releasing now types the circle's binding.
    case circleClosed
    /// The flick crossed the long-swipe threshold.
    case longSwipeArmed
    /// The flick came back under the long-swipe threshold.
    case longSwipeDisarmed
    /// The build-up while a finger rests toward a long press; scheduled ahead
    /// and cancelled when the finger moves or lifts.
    case longPressRamp
    /// One character deleted by sliding on the delete key.
    case deleteTick
    /// One caret step while sliding on the space bar.
    case cursorTick(SlidePace)
    /// The keyboard mode changed (shift, numeric, symbols) or labels toggled.
    case modeSwitch
    /// The keyboard language (or the system input mode) changed.
    case languageSwitch
    /// The keyboard is being dismissed.
    case dismiss
    /// Copy, cut or paste actually did something.
    case clipboardSuccess

    /// Every cue, for building all players ahead of time.
    static let allCases: [HapticCue] =
        [.touchDown]
            + CommitType.allCases.map(HapticCue.commit)
            + [
                .directionDetent, .centerDetent, .returnDetent, .circleClosed,
                .longSwipeArmed, .longSwipeDisarmed, .longPressRamp, .deleteTick,
            ]
            + SlidePace.allCases.map(HapticCue.cursorTick)
            + [.modeSwitch, .languageSwitch, .dismiss, .clipboardSuccess]

    /// Which of the user's two intensity settings scales this cue.
    var channel: HapticChannel {
        switch self {
        case .deleteTick, .cursorTick: .slide
        default: .touch
        }
    }

    /// The confirmation for an action flowing through the pipeline, or nil
    /// for silence. Text actions are silent here: they are confirmed at
    /// touch-down and on release. Clipboard actions are silent too: whether
    /// they did anything is only known inside `AdvancedTextMiddleware`, which
    /// confirms its own successes (`clipboardSuccess`).
    static func forPipelineAction(_ action: KeyAction) -> HapticCue? {
        switch action {
        case .switchMode: .modeSwitch
        case .switchToNextLanguage, .advanceToNextInputMode: .languageSwitch
        case .dismissKeyboard: .dismiss
        default: nil
        }
    }
}

/// The user setting a cue's strength follows.
enum HapticChannel: Hashable, Sendable {
    /// "Tap Feedback": everything a finger does on a key.
    case touch
    /// "Drag Feedback": the per-step ticks of the space and delete slides.
    case slide
}

// MARK: - Patterns

/// A designed haptic pattern, as plain data: transient clicks and continuous
/// buzzes on a timeline, plus optional control curves. Mirrors what
/// `CHHapticPattern` takes, so the Core Haptics player is a direct
/// translation and the vocabulary can be unit-tested without a Taptic Engine.
struct HapticPatternSpec: Equatable, Sendable {
    struct Event: Equatable, Sendable {
        enum EventType: Equatable, Sendable {
            /// A click. Core Haptics fixes its length (a few ms, shorter the
            /// sharper it is).
            case transient
            /// A buzz of the given length.
            case continuous(duration: TimeInterval)
        }

        var eventType: EventType
        /// Seconds from the start of the pattern.
        var time: TimeInterval
        /// 0...1, before the user's gain.
        var intensity: Float
        /// 0...1: 0 is a dull thud, 1 a crisp tick.
        var sharpness: Float
        /// Envelope of a continuous event (seconds); ignored for transients.
        var attack: Float = 0
        var release: Float = 0

        static func click(at time: TimeInterval = 0, _ intensity: Float, sharpness: Float) -> Event {
            Event(eventType: .transient, time: time, intensity: intensity, sharpness: sharpness)
        }

        static func buzz(
            at time: TimeInterval = 0, for duration: TimeInterval, _ intensity: Float, sharpness: Float,
            attack: Float = 0, release: Float = 0
        ) -> Event {
            Event(
                eventType: .continuous(duration: duration), time: time, intensity: intensity, sharpness: sharpness,
                attack: attack, release: release
            )
        }

        /// When the event ends (a transient is counted as instantaneous).
        var end: TimeInterval {
            switch eventType {
            case .transient: time
            case let .continuous(duration): time + duration
            }
        }
    }

    /// A control curve: multiplies the events' intensity or sharpness over
    /// time (Core Haptics' `hapticIntensityControl` / `hapticSharpnessControl`).
    struct Curve: Equatable, Sendable {
        enum Parameter: Equatable, Sendable { case intensity, sharpness }
        struct Point: Equatable, Sendable {
            var time: TimeInterval
            var value: Float
        }

        var parameter: Parameter
        var points: [Point]
    }

    var events: [Event]
    var curves: [Curve] = []

    /// Length of the pattern (the last event's end).
    var duration: TimeInterval { events.map(\.end).max() ?? 0 }

    /// The strongest event, before curves.
    var peakIntensity: Float { events.map(\.intensity).max() ?? 0 }

    /// The pattern at the user's strength: every event's intensity times
    /// `gain`, every sharpness shifted by `sharpnessShift`, both clamped to
    /// 0...1. Curves are relative multipliers and stay as they are.
    func scaled(by gain: Float, sharpnessShift: Float = 0) -> HapticPatternSpec {
        var copy = self
        copy.events = events.map { event in
            var event = event
            event.intensity = min(max(event.intensity * gain, 0), 1)
            event.sharpness = min(max(event.sharpness + sharpnessShift, 0), 1)
            return event
        }
        return copy
    }
}

extension HapticPatternSpec {
    /// The vocabulary. Intensities are authored for a gain of 1 ("Strong");
    /// the user's level scales them down (`HapticGain`). Every number here is
    /// a starting point tuned by reasoning, not on a device — see
    /// `docs/feel.md` for the rationale per cue.
    static func pattern(for cue: HapticCue) -> HapticPatternSpec {
        switch cue {
        case .touchDown:
            // The key's tactile bump: crisp enough to register under a fast
            // thumb, not so sharp that 8 keystrokes a second become a rattle.
            HapticPatternSpec(events: [.click(0.62, sharpness: 0.6)])

        case .commit(.tap):
            // The key coming back up: softer and duller than the press, so
            // press + release read as one physical keystroke, not two clicks.
            HapticPatternSpec(events: [.click(0.3, sharpness: 0.22)])
        case .commit(.swipe):
            // A flick snapping off the key: sharper than the press.
            HapticPatternSpec(events: [.click(0.5, sharpness: 0.82)])
        case .commit(.returnSwipe):
            // There and back: a click and a lighter, crisper echo 34 ms later.
            HapticPatternSpec(events: [
                .click(0.46, sharpness: 0.7),
                .click(at: 0.034, 0.3, sharpness: 0.95),
            ])
        case .commit(.circle):
            // A roll: three clicks rising in strength and sharpness, like a
            // dial turning past its detents.
            HapticPatternSpec(events: [
                .click(0.26, sharpness: 0.4),
                .click(at: 0.026, 0.36, sharpness: 0.56),
                .click(at: 0.052, 0.5, sharpness: 0.76),
            ])
        case .commit(.longSwipe):
            // A global action fired: a heavy, dull landing with a short tail.
            HapticPatternSpec(events: [
                .click(0.78, sharpness: 0.32),
                .buzz(at: 0.012, for: 0.06, 0.3, sharpness: 0.18, attack: 0, release: 0.05),
            ])
        case .commit(.longPress):
            // The ramp's resolution: a firm click.
            HapticPatternSpec(events: [.click(0.8, sharpness: 0.66)])

        case .directionDetent:
            // The lightest tick in the set: you feel the sector edges pass
            // without it competing with the press or the commit.
            HapticPatternSpec(events: [.click(0.3, sharpness: 0.96)])
        case .centerDetent:
            // Back to the tap: a touch softer and duller than a direction.
            HapticPatternSpec(events: [.click(0.22, sharpness: 0.6)])
        case .returnDetent:
            // The turn-around registers as its own crisp tick.
            HapticPatternSpec(events: [.click(0.34, sharpness: 1.0)])
        case .circleClosed:
            // The loop closing: a quick two-step.
            HapticPatternSpec(events: [
                .click(0.36, sharpness: 0.62),
                .click(at: 0.024, 0.28, sharpness: 0.92),
            ])
        case .longSwipeArmed:
            // Crossing into "do something else": a thunk with a short dull
            // buzz, unmistakably heavier than a detent.
            HapticPatternSpec(events: [
                .click(0.66, sharpness: 0.24),
                .buzz(at: 0.008, for: 0.05, 0.26, sharpness: 0.12, attack: 0, release: 0.04),
            ])
        case .longSwipeDisarmed:
            HapticPatternSpec(events: [.click(0.28, sharpness: 0.5)])

        case .longPressRamp:
            // A soft swell over the last quarter second of the hold, rising in
            // strength and sharpness, so the long press is felt approaching
            // and the click that fires it lands as the resolution.
            HapticPatternSpec(
                events: [
                    .buzz(for: LongPressFeel.rampDuration, 0.55, sharpness: 0.3, attack: 0.04, release: 0.02),
                ],
                curves: [
                    Curve(parameter: .intensity, points: [
                        .init(time: 0, value: 0.12),
                        .init(time: LongPressFeel.rampDuration * 0.6, value: 0.5),
                        .init(time: LongPressFeel.rampDuration, value: 1),
                    ]),
                    Curve(parameter: .sharpness, points: [
                        .init(time: 0, value: 0.3),
                        .init(time: LongPressFeel.rampDuration, value: 1),
                    ]),
                ]
            )

        case .deleteTick:
            // Each character eaten: a slightly dull, firm tick.
            HapticPatternSpec(events: [.click(0.5, sharpness: 0.45)])
        case let .cursorTick(pace):
            // Caret steps: crisp detents when slow; lighter and softer as the
            // slide speeds up, so a fling is a fine texture, not a buzz.
            switch pace {
            case .deliberate: HapticPatternSpec(events: [.click(0.52, sharpness: 0.86)])
            case .steady: HapticPatternSpec(events: [.click(0.44, sharpness: 0.8)])
            case .brisk: HapticPatternSpec(events: [.click(0.36, sharpness: 0.72)])
            case .rapid: HapticPatternSpec(events: [.click(0.28, sharpness: 0.64)])
            }

        case .modeSwitch:
            // Shift/numeric: a firm click and a crisp echo — the keys change.
            HapticPatternSpec(events: [
                .click(0.52, sharpness: 0.52),
                .click(at: 0.04, 0.34, sharpness: 0.9),
            ])
        case .languageSwitch:
            // A slide-over: click, a short soft swell, a crisp landing.
            HapticPatternSpec(events: [
                .click(0.46, sharpness: 0.42),
                .buzz(at: 0.02, for: 0.06, 0.2, sharpness: 0.2, attack: 0.02, release: 0.03),
                .click(at: 0.09, 0.4, sharpness: 0.82),
            ])
        case .dismiss:
            // Going away: a click falling off into a dull one.
            HapticPatternSpec(events: [
                .click(0.46, sharpness: 0.6),
                .click(at: 0.045, 0.3, sharpness: 0.2),
            ])
        case .clipboardSuccess:
            // "Got it": two rising pops.
            HapticPatternSpec(events: [
                .click(0.4, sharpness: 0.58),
                .click(at: 0.055, 0.6, sharpness: 0.9),
            ])
        }
    }
}

// MARK: - Strength

/// Turns the user's stored intensity (one of `HapticIntensityLevel`'s levels)
/// into a gain on the designed patterns.
///
/// The slider keeps its six detents. Off silences the channel; the five
/// audible levels spread from 0.4 to 1.0 rather than from ~0 so the lowest
/// level is still felt (Core Haptics' low end is very faint), and the
/// sharpness drifts slightly with the level — crisper when light, rounder when
/// strong — mirroring the UIKit ladder the levels were named after (a
/// selection tick at the bottom, a heavy impact at the top).
enum HapticGain {
    static func gain(for intensity: CGFloat) -> Float {
        guard intensity > 0 else { return 0 }
        let level = HapticIntensityLevel(storedIntensity: intensity)
        return switch level {
        case .off: 0
        case .tick: 0.4
        case .soft: 0.58
        case .light: 0.72
        case .medium: 0.86
        case .heavy: 1.0
        }
    }

    static func sharpnessShift(for intensity: CGFloat) -> Float {
        guard intensity > 0 else { return 0 }
        return switch HapticIntensityLevel(storedIntensity: intensity) {
        case .off: 0
        case .tick: 0.08
        case .soft: 0.04
        case .light: 0
        case .medium: -0.04
        case .heavy: -0.08
        }
    }
}

// MARK: - Fallback

extension HapticCue {
    /// What the UIKit feedback generators play for this cue when Core Haptics
    /// is unavailable (or "Detailed Haptics" is off), given the cue's channel
    /// intensity. Nil is silence.
    ///
    /// The generators cannot shape a pattern, so the fallback keeps the
    /// keyboard's original feel — an impact scaled by the slider on
    /// touch-down and per slide step, a selection tick for state changes — and
    /// adds only what a selection tick expresses well: the flick's detents and
    /// the long-swipe and long-press moments. Release clicks and the ramp stay
    /// silent there; a second impact per keystroke from the generators reads
    /// as a double buzz.
    func fallbackPulse(intensity: CGFloat) -> HapticPulse? {
        guard intensity > 0 else { return nil }
        switch self {
        case .touchDown, .deleteTick, .cursorTick:
            return .pulse(for: intensity)
        case .directionDetent, .centerDetent, .returnDetent, .circleClosed,
             .longSwipeArmed, .longSwipeDisarmed,
             .commit(.longSwipe), .commit(.longPress),
             .modeSwitch, .languageSwitch, .dismiss, .clipboardSuccess:
            return .selectionTick
        case .commit, .longPressRamp:
            return nil
        }
    }
}

// MARK: - Long press timing

/// Timing shared by the long-press haptic ramp and the progress ring.
enum LongPressFeel {
    /// How long before the long press fires the haptic ramp starts. Short:
    /// most holds are taps that have not lifted yet, and the swell must not
    /// start under a finger that is about to lift anyway.
    static let rampDuration: TimeInterval = 0.26

    /// How long a finger must rest before the progress ring shows at all,
    /// so ordinary taps (80–200 ms) never flash it.
    static let ringLeadIn: TimeInterval = 0.22
}
