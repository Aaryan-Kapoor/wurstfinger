//
//  FeelVoice.swift
//  Wurstfinger
//
//  One model for what every touch moment sounds and feels like, derived from
//  the key (its role and where it sits) and the gesture (its kind, direction
//  and reach). Haptics and sound both render it, so they always agree.
//

import CoreGraphics
import Foundation

// MARK: - The key

/// What a key is for, as far as its voice is concerned.
enum KeyRole: Hashable, Sendable, CaseIterable {
    case letter
    case digit
    /// Punctuation, symbols and dead keys.
    case punctuation
    case space
    case delete
    /// Return.
    case enter
    /// Shift, 123, the globe, dismiss: keys that change the keyboard rather
    /// than the text.
    case modifier

    /// Derived from the key's slide behaviour and what its tap does.
    init(key: KeyDefinition) {
        switch key.slideType {
        case .moveCursor:
            self = .space
            return
        case .delete:
            self = .delete
            return
        case .none:
            break
        }
        switch key.bindings[.tap]?.action {
        case let .commitText(text)?:
            self = KeyRole(typing: text)
        case .compose?, .cycleAccents?:
            self = .punctuation
        case .space?:
            self = .space
        case .deleteBackward?, .deleteWordBackward?, .deleteForward?, .deleteWordForward?:
            self = .delete
        case .newline?:
            self = .enter
        default:
            self = .modifier
        }
    }

    /// The role of a key that types `text`.
    init(typing text: String) {
        guard let first = text.unicodeScalars.first else {
            self = .punctuation
            return
        }
        if first.properties.isAlphabetic {
            self = .letter
        } else if first.properties.numericType != nil {
            self = .digit
        } else if first.properties.isWhitespace {
            self = .space
        } else {
            self = .punctuation
        }
    }

    /// The instrument a key of this role is played on.
    var timbre: FeelTimbre {
        switch self {
        case .letter: .wood
        case .digit: .bell
        case .punctuation: .glass
        case .space: .thump
        case .delete: .dull
        case .enter, .modifier: .felt
        }
    }

    /// Semitones the role shifts the key's position pitch: the keys that
    /// change or remove text sit below the ones that add it, space an octave
    /// below everything.
    var pitchOffset: Float {
        switch self {
        case .letter, .digit, .punctuation: 0
        case .enter: -3
        case .modifier: -5
        case .delete: -8
        case .space: -12
        }
    }

    /// How firmly the key answers (0…1, before the user's strength).
    var weight: Float {
        switch self {
        case .letter: 0.62
        case .digit: 0.58
        case .punctuation: 0.52
        case .space: 0.7
        case .delete: 0.64
        case .enter: 0.6
        case .modifier: 0.5
        }
    }
}

/// The instruments of the keyboard. Each is a timbre for the sound and a
/// sharpness and strength bias for the haptics, so the same hit feels like it
/// sounds: a glassy tick is crisp under the finger, a felt key is soft.
enum FeelTimbre: Int, Hashable, Sendable, CaseIterable {
    /// Letters: a short wooden tock.
    case wood
    /// Punctuation and symbols: a brighter, glassy tick.
    case glass
    /// Digits: a small bell, rounder than glass.
    case bell
    /// Modifiers and return: a muted felt tap.
    case felt
    /// Space: a low, wide thump.
    case thump
    /// Delete: a dark, dry click.
    case dull
    /// Detents and slide steps: the finest tick there is.
    case tick

    /// Added to the hit's pitch-derived sharpness.
    var sharpnessBias: Float {
        switch self {
        case .wood: 0
        case .glass: 0.16
        case .bell: 0.1
        case .felt: -0.12
        case .thump: -0.1
        case .dull: -0.14
        case .tick: 0.22
        }
    }

    /// Multiplies the hit's weight for the Taptic Engine.
    var hapticStrength: Float {
        switch self {
        case .wood: 1
        case .glass: 0.86
        case .bell: 0.9
        case .felt: 0.82
        case .thump: 1.08
        case .dull: 1
        case .tick: 0.62
        }
    }

    /// Multiplies the hit's weight for the speaker.
    var loudness: Float {
        switch self {
        case .wood: 1
        case .glass: 0.72
        case .bell: 0.7
        case .felt: 0.9
        case .thump: 1
        case .dull: 0.95
        case .tick: 0.5
        }
    }
}

/// A key's own voice: the note it plays, how firmly, on which instrument.
/// Computed per touch from the key's role and the centre of its touch frame
/// relative to the whole grid — arithmetic only, no lookup table to rebuild
/// when the layout changes.
struct KeyVoice: Equatable, Sendable {
    /// Semitones above the keyboard's base note.
    var pitch: Float
    var weight: Float
    var timbre: FeelTimbre
}

// MARK: - The moment

/// One click or note: when it lands after the moment that caused it, how high,
/// how firm, on which instrument.
struct FeelHit: Equatable, Sendable {
    var delay: Float
    var pitch: Float
    var weight: Float
    var timbre: FeelTimbre

    init(delay: Float = 0, pitch: Float, weight: Float, timbre: FeelTimbre) {
        self.delay = delay
        self.pitch = pitch
        self.weight = weight
        self.timbre = timbre
    }

    /// The haptic sharpness this hit maps to (before the user's level shifts
    /// it): higher notes feel crisper, the instrument adds its bias. Never
    /// below 0.12: a fully dull transient is a mushy rumble, not a key.
    var sharpness: Float {
        min(max(0.34 + pitch * 0.021 + timbre.sharpnessBias, 0.12), 1)
    }

    /// The haptic intensity this hit maps to (before the user's gain).
    var intensity: Float {
        min(max(weight * timbre.hapticStrength, 0), 1)
    }

    /// The playback rate of the instrument's sample for this note.
    var rate: Float {
        Float(exp2(Double(pitch) / 12))
    }
}

/// What a touch moment sounds and feels like: up to three hits. A value with
/// fixed storage (no array), so deriving and playing one allocates nothing.
struct FeelStroke: Equatable, Sendable {
    private(set) var first: FeelHit
    private(set) var second: FeelHit?
    private(set) var third: FeelHit?
    /// How loud the stroke is relative to a touch-down (0: felt, not heard).
    var soundGain: Float

    init(_ first: FeelHit, _ second: FeelHit? = nil, _ third: FeelHit? = nil, soundGain: Float = 1) {
        self.first = first
        self.second = second
        self.third = third
        self.soundGain = soundGain
    }

    var count: Int { 1 + (second == nil ? 0 : 1) + (third == nil ? 0 : 1) }

    /// Calls `body` with each hit in order. The closure is non-escaping, so
    /// iterating allocates nothing.
    func forEach(_ body: (FeelHit) -> Void) {
        body(first)
        if let second { body(second) }
        if let third { body(third) }
    }

    var hits: [FeelHit] {
        var hits: [FeelHit] = []
        forEach { hits.append($0) }
        return hits
    }

    var isAudible: Bool { soundGain > 0 }
}

// MARK: - The mapping

/// The derivation, as pure functions. One rule set for every moment, so the
/// keyboard is learnable as an instrument:
///
/// - **Where a key sits sets its note.** Up is higher, right is a little
///   higher: `16·(1 − y) + 10·x` semitones across the grid, snapped to a
///   major pentatonic scale so any two keys sound consonant together (the
///   nine letter keys of a 3×3 grid land on seven notes).
/// - **What a key is sets its instrument** (`KeyRole.timbre`) and shifts its
///   note: keys that change or remove text sit below those that add it.
/// - **The mode sets the register:** numbers a fourth up, symbols a fifth;
///   capitals play the same note, firmer.
/// - **The gesture sets the rhythm and the interval:** a flick plays the
///   key's note moved by its direction (up a fifth, down a fifth, right a
///   third, left down a third, diagonals between); a return swipe plays out
///   and home; a circle an arpeggio up (clockwise) or down; a long press the
///   octave above; a tap's release is a soft, low echo.
/// - **What gets typed sets the release's instrument:** a flick that types
///   punctuation sounds glassy even on a letter key.
///
/// Haptics map pitch to sharpness and weight to intensity (`FeelHit`), sound
/// plays the instrument at the pitch, so a hit feels the way it sounds.
enum FeelVoiceModel {
    /// The scale every key's note is snapped to: major pentatonic from an
    /// octave below the base to three above.
    static let scale: [Float] = (-1 ... 2).flatMap { octave in [0, 2, 4, 7, 9].map { Float($0 + 12 * octave) } } + [36]

    /// The note of `scale` nearest to `semitones`.
    static func snapped(_ semitones: Float) -> Float {
        var best = scale[0]
        var distance = Float.greatestFiniteMagnitude
        for note in scale {
            let d = abs(note - semitones)
            if d < distance {
                distance = d
                best = note
            }
        }
        return best
    }

    /// The pitch a position in the grid plays (0…1 on both axes, y down).
    static func positionPitch(x: CGFloat, y: CGFloat) -> Float {
        let u = Float(min(max(x, 0), 1))
        let v = Float(min(max(y, 0), 1))
        return snapped(16 * (1 - v) + 10 * u)
    }

    /// Semitones the active mode moves the whole keyboard.
    static func modeOffset(_ mode: String) -> Float {
        switch mode {
        case ModeNames.numeric: 5
        case ModeNames.symbols, ModeNames.emoji: 7
        default: 0
        }
    }

    /// Extra firmness in the capital modes.
    static func modeWeight(_ mode: String) -> Float {
        switch mode {
        case ModeNames.shifted, ModeNames.capsLock: 0.08
        default: 0
        }
    }

    /// A key's voice: its role's instrument, the note of its centre in the
    /// grid (`keyFrame` within `gridSize`) moved by the role, snapped to the
    /// scale, then moved by the mode (which transposes the whole keyboard,
    /// so it stays in tune with itself).
    static func voice(role: KeyRole, keyFrame: CGRect, gridSize: CGSize, mode: String) -> KeyVoice {
        let x = gridSize.width > 0 ? keyFrame.midX / gridSize.width : 0.5
        let y = gridSize.height > 0 ? keyFrame.midY / gridSize.height : 0.5
        // Space and delete keep their instrument's own register: their place
        // in the grid would otherwise make a wide space bar sing across it.
        let position: Float = switch role {
        case .space: 0
        case .delete: 12
        default: 16 * (1 - Float(min(max(y, 0), 1))) + 10 * Float(min(max(x, 0), 1))
        }
        return KeyVoice(
            pitch: snapped(position + role.pitchOffset) + modeOffset(mode),
            weight: min(role.weight + modeWeight(mode), 1),
            timbre: role.timbre
        )
    }

    /// The interval a flick in `direction` adds to its key's note.
    static func interval(of direction: GestureType) -> Float {
        switch direction {
        case .swipeUp: 7
        case .swipeUpRight: 9
        case .swipeRight: 4
        case .swipeDownRight: -3
        case .swipeDown: -7
        case .swipeDownLeft: -9
        case .swipeLeft: -4
        case .swipeUpLeft: 5
        default: 0
        }
    }

    /// The instrument for what a release types: its own role's, or the key's
    /// when it types nothing visible.
    static func timbre(typing action: KeyAction?, keyTimbre: FeelTimbre) -> FeelTimbre {
        switch action {
        case let .commitText(text)?: KeyRole(typing: text).timbre
        case .compose?, .cycleAccents?: .glass
        default: keyTimbre
        }
    }

    // MARK: Strokes

    /// A finger lands on the key.
    static func touchDown(_ voice: KeyVoice) -> FeelStroke {
        FeelStroke(FeelHit(pitch: voice.pitch, weight: voice.weight, timbre: voice.timbre))
    }

    /// A gesture is released and commits. `reach` is how far the finger
    /// travelled, in key sizes (`GestureClassification.displacementInKeys`).
    static func commit(
        _ commitType: CommitType, voice: KeyVoice, direction: GestureType, isReturn: Bool,
        reach: CGFloat, typing action: KeyAction?
    ) -> FeelStroke {
        let timbre = timbre(typing: action, keyTimbre: voice.timbre)
        let interval = interval(of: direction)
        // A flick that went further lands a little firmer, within reason.
        let reachWeight = voice.weight * (0.78 + 0.18 * Float(min(max(reach, 0), 1.2)))
        switch commitType {
        case .tap:
            // The key coming back up: a soft, low echo, felt rather than heard.
            return FeelStroke(
                FeelHit(pitch: voice.pitch - 5, weight: voice.weight * 0.48, timbre: voice.timbre),
                soundGain: 0
            )
        case .swipe:
            return FeelStroke(
                FeelHit(pitch: voice.pitch + interval, weight: reachWeight, timbre: timbre),
                soundGain: 0.75
            )
        case .returnSwipe:
            // Out to the direction's note and home to the key's.
            return FeelStroke(
                FeelHit(pitch: voice.pitch + interval, weight: reachWeight * 0.9, timbre: timbre),
                FeelHit(delay: 0.034, pitch: voice.pitch, weight: reachWeight * 0.62, timbre: timbre),
                soundGain: 0.75
            )
        case .circle:
            // An arpeggio, up for clockwise and down for counter-clockwise.
            let steps: (Float, Float, Float) = direction == .circularCounterclockwise ? (7, 4, 0) : (0, 4, 7)
            return FeelStroke(
                FeelHit(pitch: voice.pitch + steps.0, weight: voice.weight * 0.5, timbre: timbre),
                FeelHit(delay: 0.026, pitch: voice.pitch + steps.1, weight: voice.weight * 0.62, timbre: timbre),
                FeelHit(delay: 0.052, pitch: voice.pitch + steps.2, weight: voice.weight * 0.8, timbre: timbre),
                soundGain: 0.7
            )
        case .longSwipe:
            // A global action: a low, heavy landing in the direction's colour.
            return FeelStroke(
                FeelHit(pitch: voice.pitch - 12 + interval / 2, weight: 0.82, timbre: .thump),
                soundGain: 0.8
            )
        case .longPress:
            // The hidden character behind the key: the octave above.
            return FeelStroke(
                FeelHit(pitch: voice.pitch + 12, weight: min(voice.weight * 1.15, 1), timbre: timbre),
                soundGain: 0.8
            )
        }
    }

    /// A moving flick's target changed (`KeyboardFeel.cue(from:to:)` decides
    /// which detent). Felt, not heard: the sector's note, very light.
    static func detent(_ cue: HapticCue, voice: KeyVoice, direction: GestureType?) -> FeelStroke {
        let note = voice.pitch + (direction.map(interval(of:)) ?? 0)
        switch cue {
        case .centerDetent:
            return FeelStroke(FeelHit(pitch: voice.pitch - 3, weight: 0.24, timbre: .tick), soundGain: 0)
        case .returnDetent:
            return FeelStroke(FeelHit(pitch: voice.pitch + 2, weight: 0.36, timbre: .tick), soundGain: 0)
        case .circleClosed:
            return FeelStroke(
                FeelHit(pitch: voice.pitch + 4, weight: 0.36, timbre: .tick),
                FeelHit(delay: 0.024, pitch: voice.pitch + 7, weight: 0.3, timbre: .tick),
                soundGain: 0
            )
        default:
            return FeelStroke(FeelHit(pitch: note, weight: 0.32, timbre: .tick), soundGain: 0)
        }
    }

    /// One step of a slide: the caret's tick rises a tone to the right and
    /// falls to the left and lightens as the slide speeds up; each deleted
    /// character is a dry click that walks down a little (`step` counts them).
    static func slideStep(_ slideType: SlideType, voice: KeyVoice, direction: Int, pace: SlidePace, step: Int) -> FeelStroke {
        let paceWeight: Float = switch pace {
        case .deliberate: 0.52
        case .steady: 0.44
        case .brisk: 0.36
        case .rapid: 0.28
        }
        if slideType == .delete {
            let walk = Float(step % 4)
            return FeelStroke(
                FeelHit(pitch: voice.pitch - walk, weight: paceWeight + 0.06, timbre: .dull),
                soundGain: 0.45
            )
        }
        return FeelStroke(
            FeelHit(pitch: voice.pitch + 19 + (direction < 0 ? -2 : 2), weight: paceWeight, timbre: .tick),
            soundGain: 0.4
        )
    }

    /// Where a mode sits among the others: letters, then capitals and the
    /// one-shot modifiers, then caps lock, numbers, symbols, emoji.
    static func modeRank(_ mode: String) -> Int {
        switch mode {
        case ModeNames.shifted, ModeNames.control, ModeNames.alt: 1
        case ModeNames.capsLock: 2
        case ModeNames.numeric: 3
        case ModeNames.symbols: 4
        case ModeNames.emoji: 5
        default: 0
        }
    }

    /// The keyboard changed mode: two notes, rising into a mode further from
    /// letters and falling back toward them — a fourth for a neighbouring
    /// mode, a fifth for a jump.
    static func modeChange(from old: String, to new: String) -> FeelStroke {
        let delta = modeRank(new) - modeRank(old)
        let interval: Float = abs(delta) >= 2 ? 7 : 5
        let rising = delta >= 0
        return FeelStroke(
            FeelHit(pitch: rising ? 0 : interval, weight: 0.52, timbre: .felt),
            FeelHit(delay: 0.04, pitch: rising ? interval : 0, weight: 0.38, timbre: .felt),
            soundGain: 0.7
        )
    }

    /// Copy, cut or paste did something: a bright rising fifth.
    static let clipboard = FeelStroke(
        FeelHit(pitch: 12, weight: 0.4, timbre: .glass),
        FeelHit(delay: 0.055, pitch: 19, weight: 0.5, timbre: .glass),
        soundGain: 0.6
    )

    /// The keyboard is dismissed: a falling fourth, muted.
    static let dismiss = FeelStroke(
        FeelHit(pitch: 5, weight: 0.46, timbre: .felt),
        FeelHit(delay: 0.045, pitch: 0, weight: 0.3, timbre: .felt),
        soundGain: 0.6
    )

    /// The language changed: a short rising triad.
    static let languageChange = FeelStroke(
        FeelHit(pitch: 0, weight: 0.46, timbre: .felt),
        FeelHit(delay: 0.045, pitch: 4, weight: 0.36, timbre: .felt),
        FeelHit(delay: 0.09, pitch: 7, weight: 0.42, timbre: .glass),
        soundGain: 0.7
    )
}
