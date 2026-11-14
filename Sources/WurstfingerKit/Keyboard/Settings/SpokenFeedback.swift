//
//  SpokenFeedback.swift
//  Wurstfinger
//
//  VoiceOver announcements for gesture typing, and the key click sound.
//

import Accessibility
import Foundation
#if os(iOS)
import AudioToolbox
import UIKit
#else
import AppKit
#endif

/// Speech for gesture typing under VoiceOver.
///
/// With "Gesture Typing with VoiceOver" on, the keyboard is a direct-touch
/// area: VoiceOver hands it the raw touches instead of reading the key under
/// the finger, so the keyboard says what it would type itself — the key's
/// character on touch-down, then each new target as a flick heads for it —
/// and lifting the finger types it, which VoiceOver echoes as usual.
///
/// A value of closures so a test can stand in for the screen reader.
@MainActor
struct SpokenFeedback {
    /// Whether a screen reader is listening (checked per announcement, so
    /// turning VoiceOver off mid-session silences it at once).
    var isActive: () -> Bool
    /// Speaks a target, interrupting whatever the previous announcement was
    /// still saying: only the newest target matters.
    var announce: (SpokenTarget) -> Void

    static let voiceOver = SpokenFeedback(
        isActive: {
            #if os(iOS)
            UIAccessibility.isVoiceOverRunning
            #else
            NSWorkspace.shared.isVoiceOverEnabled
            #endif
        },
        announce: { target in
            var speech: AttributedString
            switch target {
            case let .glyph(text):
                speech = AttributedString(text)
                // A lone mark is read by name ("period"), in VoiceOver's language.
                speech.accessibilitySpeechSpellsOutCharacters = true
            case let .name(name):
                speech = AttributedString(name)
            }
            speech.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(speech).post()
        }
    )

    /// Never speaks (tests and tools).
    static let silent = SpokenFeedback(isActive: { false }, announce: { _ in })
}

/// What gesture typing says for a target.
enum SpokenTarget: Equatable, Sendable {
    /// What the gesture types, spelled out ("ä", "period").
    case glyph(String)
    /// The binding's name, read as words ("Delete word").
    case name(String)
}

/// The family of a key sound, matching the system keyboard's three: letters,
/// delete, and the keys that change mode or move around (space, return,
/// shift, 123, globe). The keyboard's own sounds are derived per key and
/// gesture (`FeelStroke`); the family is what the system-sound fallback plays
/// and what tests check.
enum KeyClick: Equatable, Sendable {
    case character
    case delete
    case modifier

    init(for key: KeyDefinition) {
        if key.slideType == .delete {
            self = .delete
            return
        }
        self.init(typing: key.bindings[.tap]?.action)
    }

    /// The family of a sound for what `action` does.
    init(typing action: KeyAction?) {
        switch action {
        case .deleteBackward?, .deleteWordBackward?, .deleteForward?, .deleteWordForward?:
            self = .delete
        case .space?, .newline?, .switchMode?, .advanceToNextInputMode?, .dismissKeyboard?,
             .switchToNextLanguage?, .switchToPreviousLanguage?, .none?, nil:
            self = .modifier
        default:
            self = .character
        }
    }

    /// The system sound the iOS keyboard plays for it.
    var systemSoundID: UInt32 {
        switch self {
        case .character: 1104
        case .delete: 1155
        case .modifier: 1156
        }
    }
}

/// Plays key sounds. A value of a closure so a test can count them: it gets
/// the family and the derived stroke of each sound.
@MainActor
struct KeyClickPlayer {
    var play: (KeyClick, FeelStroke) -> Void

    /// The keyboard's own instruments (`KeySoundEngine`), at the pitch each
    /// moment derives — falling back to the system's keyboard sound for the
    /// family while the audio graph is starting or could not start. Both need
    /// Full Access in a keyboard extension; without it the controller marks
    /// the engine as such and nothing plays.
    static let synthesized = KeyClickPlayer { click, stroke in
        let engine = KeySoundEngine.shared
        guard engine.isAccessGranted else { return }
        if !engine.play(stroke) {
            KeyClickPlayer.system.play(click, stroke)
        }
    }

    /// The system's keyboard sounds. They play only with Full Access, and
    /// follow the ring / silent switch like every system sound.
    static let system = KeyClickPlayer { click, _ in
        #if os(iOS)
        AudioServicesPlaySystemSound(SystemSoundID(click.systemSoundID))
        #endif
    }

    static let silent = KeyClickPlayer { _, _ in }
}
