//
//  KeyDefinition+Accessibility.swift
//  Wurstfinger
//
//  What a key offers to assistive technologies, derived from its bindings.
//

import Foundation

/// One named action a key offers to assistive technologies.
struct KeyAccessibilityAction: Hashable, Sendable {
    /// What the action is called in the rotor, e.g. "Delete word" or
    /// "ä, swipe down". Unique per key.
    let name: String
    let gesture: GestureType
    /// Dispatch as the return swipe (out and back) rather than the gesture.
    var isReturn = false
    /// The character this action types, when it is a character action. The
    /// view speaks it spelled out, so VoiceOver names a lone mark ("period",
    /// "Punkt") in the user's own language instead of skipping it.
    var glyph: String? = nil
    /// The spoken gesture following the glyph, e.g. "swipe down".
    var gestureName: String? = nil
}

extension KeyDefinition {
    /// Gesture that must replace the synthesized tap when an assistive
    /// technology activates this key, or nil when the tap already does
    /// something — VoiceOver activation reaches the recognizer as a plain
    /// tap, so those keys need no override and keep one code path.
    var accessibilityActivationOverride: GestureType? {
        // Annotated so `.none` reads as the key action, not `Optional.none`.
        let tapAction: KeyAction = bindings[.tap]?.action ?? .none
        guard tapAction == .none else { return nil }
        guard let gesture = accessibilityActivationGesture,
              let binding = bindings[gesture], binding.action != .none
        else { return nil }
        return gesture
    }

    /// Order the custom actions are offered in. Fixed because dictionary
    /// iteration is seeded per process and the rotor order must not change
    /// between launches; a `static let` for the same reason
    /// `KeyView.hintGestureOrder` is one — `allCases` rebuilds its array on
    /// every access, and this list is walked per key on every render. `.tap`
    /// drops out: it is the element's own activation.
    static let accessibilityActionGestures: [GestureType] = GestureType.allCases.filter { $0 != .tap }

    /// Every action a key offers, in two tiers (#231).
    ///
    /// 1. **Named actions** — the curated bindings that carry an
    ///    `accessibilityLabel` (the utility keys, `, . ?`, shift), first,
    ///    because they are the ones a user reaches for most. The activation
    ///    override is excluded alongside `.tap`: it is already reachable by
    ///    activating the key. `CommonKeys.defaultSlotBindings` documents which
    ///    bindings are named and `NamedAccessibilityBindingTests` pins the set.
    /// 2. **Character actions** — every other binding that types something,
    ///    named by its character and gesture ("ä, swipe down"), including the
    ///    text a return swipe types ("÷, swipe right, and back"). Without these
    ///    the letters on a key's eight directions are unreachable without
    ///    gestures. A character the key's tap already types is skipped: it is
    ///    the key's own activation.
    ///
    /// Names are deduplicated — cut-all is bound to both circle directions
    /// with one label, and two identical rotor entries read as a bug.
    var accessibilityActions: [KeyAccessibilityAction] {
        let skipped = accessibilityActivationOverride
        var seen: Set<String> = []
        var actions: [KeyAccessibilityAction] = []
        for gesture in Self.accessibilityActionGestures where gesture != skipped {
            guard let binding = bindings[gesture], binding.action != .none,
                  let name = binding.accessibilityLabel, !name.isEmpty,
                  seen.insert(name).inserted
            else { continue }
            actions.append(KeyAccessibilityAction(name: name, gesture: gesture))
        }

        let tapAction = bindings[.tap]?.action
        var typed: Set<String> = []
        if let tapText = tapAction?.typedText { typed.insert(tapText) }
        for gesture in Self.accessibilityActionGestures where gesture != skipped {
            guard let binding = bindings[gesture] else { continue }
            let gestureName = gesture.spokenName
            if binding.accessibilityLabel == nil,
               let action = Self.characterAction(binding.action, label: binding.label, gesture: gesture,
                                                  gestureName: gestureName, isReturn: false, typed: &typed),
               seen.insert(action.name).inserted {
                actions.append(action)
            }
            if let returnAction = binding.returnAction,
               let action = Self.characterAction(returnAction, label: nil, gesture: gesture,
                                                  gestureName: gestureName + ", " + GestureType.spokenReturn,
                                                  isReturn: true, typed: &typed),
               seen.insert(action.name).inserted {
                actions.append(action)
            }
        }
        return actions
    }

    /// The rotor entry for one character binding, or nil when it types
    /// nothing or a character already offered on this key.
    private static func characterAction(
        _ action: KeyAction, label: String?, gesture: GestureType, gestureName: String,
        isReturn: Bool, typed: inout Set<String>
    ) -> KeyAccessibilityAction? {
        let glyph: String
        switch action {
        case let .commitText(text):
            glyph = text
        case let .compose(trigger):
            // A dead key shows its accent; the trigger may be a spacing
            // variant ("ˋ" for "`"), and the label is what the user sees.
            glyph = label ?? trigger
        case .cycleAccents:
            glyph = String(localized: "Cycle accents")
        default:
            return nil
        }
        guard !glyph.isEmpty, typed.insert(glyph).inserted else { return nil }
        return KeyAccessibilityAction(
            name: glyph + ", " + gestureName,
            gesture: gesture,
            isReturn: isReturn,
            // An emoji is no glyph to spell out: left whole, VoiceOver names it in
            // the user's language, and a ZWJ sequence is not read piece by piece.
            glyph: action == .cycleAccents || EmojiText.isEmoji(glyph) ? nil : glyph,
            gestureName: gestureName
        )
    }
}

extension KeyAction {
    /// The text this action types, for actions that type a fixed text.
    var typedText: String? {
        if case let .commitText(text) = self { text } else { nil }
    }
}

extension GestureType {
    /// How a character action names the gesture that types it.
    var spokenName: String {
        switch self {
        case .tap: String(localized: "spokenName.tap")
        case .swipeUp: String(localized: "swipe up")
        case .swipeDown: String(localized: "swipe down")
        case .swipeLeft: String(localized: "swipe left")
        case .swipeRight: String(localized: "swipe right")
        case .swipeUpLeft: String(localized: "swipe up left")
        case .swipeUpRight: String(localized: "swipe up right")
        case .swipeDownLeft: String(localized: "swipe down left")
        case .swipeDownRight: String(localized: "swipe down right")
        case .circularClockwise: String(localized: "circle clockwise")
        case .circularCounterclockwise: String(localized: "circle counterclockwise")
        case .longPress: String(localized: "spokenName.longPress")
        }
    }

    /// Appended to a gesture's name for the return swipe (out and back).
    static var spokenReturn: String { String(localized: "and back") }
}
