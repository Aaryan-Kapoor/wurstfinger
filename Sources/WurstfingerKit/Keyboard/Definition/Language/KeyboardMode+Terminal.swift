//
//  KeyboardMode+Terminal.swift
//  Wurstfinger
//
//  The one-shot Ctrl and Alt modes, generated from the main mode.
//

import Foundation

/// A modifier a terminal understands as a byte sequence.
///
/// A keyboard extension cannot send key events, so Ctrl and Alt cannot be
/// held down the way Flickboard's toggles do. What terminal emulators and SSH
/// clients read from a text proxy is what a terminal would receive, which is
/// how the long swipes already send Escape (`ESC`) and Shift-Tab (`ESC [ Z`):
/// Ctrl+letter is the letter's control code (`ctrl-C` is `U+0003`), and Alt+key
/// is the key preceded by `ESC` (the "meta sends escape" convention). A plain
/// text field shows these as control characters, which is why the modes are
/// entered by a deliberate gesture and leave again after one key.
enum TerminalModifier: CaseIterable, Sendable {
    case control
    case alt

    /// The mode name this modifier's generated mode carries.
    var modeName: String {
        switch self {
        case .control: ModeNames.control
        case .alt: ModeNames.alt
        }
    }

    /// Label of the key that leaves the mode (it replaces "123"): the macOS
    /// glyphs for the Control and Option keys.
    var backLabel: String {
        switch self {
        case .control: "⌃"
        case .alt: "⌥"
        }
    }

    /// What typing `text` while this modifier is down inserts, or `nil` when
    /// the modifier has no meaning for it (the key then does nothing).
    func transformed(_ text: String) -> String? {
        switch self {
        case .control:
            guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first,
                  scalar.isASCII
            else { return nil }
            return Self.controlCharacter(for: scalar).map { String(Character($0)) }
        case .alt:
            // Alt+Tab, Alt+Return and the like are not ESC-prefixed text.
            guard text.count == 1, let first = text.unicodeScalars.first,
                  first.value >= 0x20, first.value != 0x7F
            else { return nil }
            return "\u{1B}" + text
        }
    }

    /// The control code a terminal sends for Ctrl plus an ASCII character:
    /// letters (either case) map to 1–26 and `[ \ ] ^ _` to 27–31, `?` is DEL.
    /// `@` and space would be NUL, which text fields drop, so they stay unbound.
    static func controlCharacter(for scalar: Unicode.Scalar) -> Unicode.Scalar? {
        switch scalar {
        case "a" ... "z": Unicode.Scalar(scalar.value - 0x60)
        case "A" ... "Z": Unicode.Scalar(scalar.value - 0x40)
        case "[": Unicode.Scalar(0x1B)
        case "\\": Unicode.Scalar(0x1C)
        case "]": Unicode.Scalar(0x1D)
        case "^": Unicode.Scalar(0x1E)
        case "_": Unicode.Scalar(0x1F)
        case "?": Unicode.Scalar(0x7F)
        default: nil
        }
    }
}

extension KeyboardMode {
    /// Generates the one-shot Ctrl or Alt mode from this (main) mode.
    ///
    /// - The nine grid keys keep their gestures; every text output goes through
    ///   `TerminalModifier.transformed`. Text the modifier has no code for is
    ///   typed as it is; what has no meaning at all (an accent trigger) becomes
    ///   an inert binding (an empty `.none`, not a missing one: a missing
    ///   binding would fall through to the numeric mode and type a digit or a
    ///   different symbol).
    /// - Transformed bindings carry the `.letter` category whatever they were,
    ///   so the mode's `.letter → main` transition returns to the letters after
    ///   one key, the way a held modifier is released with the key.
    /// - Other bindings that move the cursor (the line jumps) are left alone;
    ///   accent compose/cycle, case and shift bindings go inert: a dead key
    ///   under Ctrl is meaningless.
    /// - A gesture the main mode leaves unbound would fall through to the
    ///   numeric mode's ghost keys (a hold types the key's digit, a swipe the
    ///   `≤`/`≥` of the top corners), which are neither control codes nor
    ///   category `.letter`: the digit would be typed raw and the mode would
    ///   stay armed. So every swipe the key does not bind is inert here, and a
    ///   hold does what a tap does (the way the numeric mode mirrors its taps).
    /// - Letter labels show uppercase under Ctrl (the `^A` convention); Alt
    ///   keeps them as they are.
    /// - The numeric-mode key becomes the key that leaves the mode.
    func generateTerminalModifier(_ modifier: TerminalModifier, locale: Locale) -> KeyboardMode {
        var generated: [String: KeyDefinition] = [:]
        let gridSlots = Set(GridSlot.allSlots.flatMap { $0 })
        for (keyId, key) in keys {
            if gridSlots.contains(keyId) {
                var copy = key
                copy.bindings = key.bindings.mapValues { Self.terminalBinding($0, modifier: modifier, locale: locale) }
                // Close the ghost fallback (see above): every gesture the key
                // does not bind gets an answer of its own.
                for gesture in GestureType.allCases where copy.bindings[gesture] == nil && !gesture.isCircular {
                    if gesture == .longPress, let tap = copy.bindings[.tap] {
                        copy.bindings[gesture] = tap
                    } else if gesture.isSwipe || gesture == .longPress {
                        copy.bindings[gesture] = Self.inertBinding
                    }
                }
                generated[keyId] = copy
            } else if keyId == UtilitySlot.symbols {
                generated[keyId] = KeyDefinition.utility(
                    UtilitySlot.symbols, label: modifier.backLabel, action: .switchMode(ModeNames.main),
                    swipeMode: .eightWay, swipes: CommonKeys.clipboardBindings,
                    accessibilityLabel: String(localized: "Letters")
                )
            } else {
                generated[keyId] = key
            }
        }
        return KeyboardMode(
            name: modifier.modeName,
            keys: generated,
            arrangements: arrangements,
            autoTransitions: [.letter: ModeNames.main]
        )
    }

    /// A binding that types nothing and leaves the mode armed. Present rather
    /// than absent so the numeric mode's ghost keys cannot answer for it.
    private static let inertBinding = KeyBinding(
        label: "", action: .none, category: .utility,
        returnAction: nil, accessibilityLabel: nil
    )

    private static func terminalBinding(
        _ binding: KeyBinding, modifier: TerminalModifier, locale: Locale
    ) -> KeyBinding {
        let inert = inertBinding
        switch binding.action {
        case let .commitText(text):
            // Text the modifier has no code for (ä, a digit, a full stop) is typed
            // as it is: the key still works, and the mode still ends with it. A
            // layout may put such a letter on a tap (the optimized Finnish layout
            // puts ä there), and a tap that does nothing would strand the key.
            guard let output = modifier.transformed(text) else {
                return KeyBinding(
                    label: binding.label, action: .commitText(text), category: .letter,
                    returnAction: nil, accessibilityLabel: nil
                )
            }
            let isLetter = text.first?.isLetter == true
            return KeyBinding(
                label: modifier == .control && isLetter ? binding.label.keyboardUppercased(with: locale) : binding.label,
                action: .commitText(output), category: .letter,
                // The uppercase return swipe types the same thing under either
                // modifier's shifted partner (Ctrl-A is Ctrl-Shift-A), so a
                // return swipe adds nothing: fall back to the plain swipe.
                returnAction: nil,
                accessibilityLabel: nil
            )
        case let .compose(trigger):
            // `^` is also the control code RS under Ctrl. Every other accent
            // trigger is inert, and Alt has no use for any of them.
            guard modifier == .control, trigger == "^", let output = modifier.transformed("^") else { return inert }
            return KeyBinding(
                label: binding.label, action: .commitText(output), category: .letter,
                returnAction: nil, accessibilityLabel: nil
            )
        case .cycleAccents, .switchMode, .capitalizeWord, .cycleWordCase:
            // Accents and case changes mean nothing under a modifier, and the
            // shift and lowercase keys would leave the mode half-way: the mode
            // ends with one key, or with the key that replaces "123".
            return inert
        default:
            return KeyBinding(
                label: binding.label, action: binding.action, category: binding.category,
                returnAction: nil, accessibilityLabel: binding.accessibilityLabel
            )
        }
    }
}
