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

/// The sound a key makes on touch-down when key clicks are on, matching the
/// system keyboard's three: letters, delete, and the keys that change mode
/// or move around (space, return, shift, 123, globe).
enum KeyClick: Equatable, Sendable {
    case character
    case delete
    case modifier

    init(for key: KeyDefinition) {
        switch key.bindings[.tap]?.action {
        case .deleteBackward?, .deleteWordBackward?, .deleteForward?, .deleteWordForward?:
            self = .delete
        case .space?, .newline?, .switchMode?, .advanceToNextInputMode?, .dismissKeyboard?,
             .switchToNextLanguage?, .switchToPreviousLanguage?, .none?:
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

/// Plays key clicks. A value of a closure so a test can count them.
@MainActor
struct KeyClickPlayer {
    var play: (KeyClick) -> Void

    /// The system's keyboard sounds. They play only with Full Access, and
    /// follow the ring / silent switch like every system sound.
    static let system = KeyClickPlayer { click in
        #if os(iOS)
        AudioServicesPlaySystemSound(SystemSoundID(click.systemSoundID))
        #endif
    }

    static let silent = KeyClickPlayer { _ in }
}
