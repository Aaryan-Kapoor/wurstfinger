//
//  CustomLayout+Editing.swift
//  Wurstfinger
//
//  What a key shows and holds while it is being edited.
//

import Foundation

/// How one gesture of a key stands in a layout being edited.
enum CustomBindingState: Equatable, Sendable {
    /// The layout does not mention it; the shared punctuation, if any, applies
    /// (`label` is what that shows, `nil` when nothing is bound).
    case inherited(label: String?)

    /// The layout types `text` here.
    case custom(text: String)

    /// The layout removes whatever the shared punctuation would put here.
    case removed
}

extension CustomLayout {
    /// The shared binding a gesture on `slot` would carry if the layout left it
    /// alone, or `nil` when there is none (or the layout keeps no shared symbols).
    func inheritedBinding(slot: String, gesture: GestureType) -> KeyBinding? {
        let shared = usesSharedSymbols ? CommonKeys.defaultSlotBindings : CommonKeys.essentialSlotBindings
        return shared[slot]?[gesture]
    }

    /// The state of `gesture` on `slot`.
    func state(slot: String, gesture: GestureType) -> CustomBindingState {
        guard let binding = keys[slot]?[gesture] else {
            let label = inheritedBinding(slot: slot, gesture: gesture)?.label
            return .inherited(label: label?.isEmpty == false ? label : nil)
        }
        return binding.text.isEmpty ? .removed : .custom(text: binding.text)
    }

    /// What the key shows for `gesture`: its own text, the shared symbol it
    /// inherits, or an empty string.
    func displayedText(slot: String, gesture: GestureType) -> String {
        switch state(slot: slot, gesture: gesture) {
        case let .custom(text): text
        case let .inherited(label): label ?? ""
        case .removed: ""
        }
    }

    /// Sets the text `gesture` types on `slot`. Empty text makes the layout
    /// inherit again (the way a field the user clears behaves); use
    /// `removeBinding` to unbind a shared symbol on purpose. Text beyond
    /// `maxTextLength` characters is cut. A return-swipe output already set on
    /// the gesture is kept.
    mutating func setText(_ text: String, slot: String, gesture: GestureType) {
        let clipped = String(text.prefix(Self.maxTextLength))
        if clipped.isEmpty, gesture != .tap {
            keys[slot]?[gesture] = nil
            return
        }
        var binding = keys[slot]?[gesture] ?? CustomBinding(clipped)
        binding.text = clipped
        keys[slot, default: [:]][gesture] = binding
    }

    /// Unbinds `gesture` on `slot`, shared symbol included.
    mutating func removeBinding(slot: String, gesture: GestureType) {
        keys[slot, default: [:]][gesture] = CustomBinding("")
    }

    /// Makes `gesture` on `slot` inherit again.
    mutating func restoreBinding(slot: String, gesture: GestureType) {
        keys[slot]?[gesture] = nil
    }
}
