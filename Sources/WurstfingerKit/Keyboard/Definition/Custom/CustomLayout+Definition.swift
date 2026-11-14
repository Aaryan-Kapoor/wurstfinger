//
//  CustomLayout+Definition.swift
//  Wurstfinger
//
//  Turning a custom layout into a keyboard, and a shipped keyboard back into
//  a custom layout to start from.
//

import Foundation

extension CustomLayout {
    // MARK: - Layout → keyboard

    /// Builds the keyboard this layout describes, with the same factory the
    /// shipped languages use.
    ///
    /// - Parameter base: The definition of the shipped layout `basedOn` names.
    ///   Only its *settings* are read — input method, compose and combine
    ///   rules, the numeric digit set — because a grid of letters cannot
    ///   express them; `nil` builds with plain defaults.
    ///
    /// Call `validate()` first: the factory traps on a layout that violates its
    /// preconditions (a missing tap, a return swipe with no binding).
    func makeDefinition(basedOn base: KeyboardDefinition?) -> KeyboardDefinition {
        var slotDefaults = usesSharedSymbols
            ? CommonKeys.defaultSlotBindings
            : CommonKeys.essentialSlotBindings
        var directionalOverrides: [String: [GestureType: String]] = [:]
        var returnOverrides: [String: [GestureType: String]] = [:]

        for slot in Self.slots {
            for (gesture, binding) in keys[slot] ?? [:] where gesture != .tap {
                if binding.text.isEmpty {
                    // An empty text unbinds the gesture, shared punctuation included.
                    slotDefaults[slot]?[gesture] = nil
                    continue
                }
                directionalOverrides[slot, default: [:]][gesture] = binding.text
                if let returnText = binding.returnText {
                    returnOverrides[slot, default: [:]][gesture] = returnText
                }
            }
        }

        let centers = GridSlot.allSlots.map { row in row.map { tapText(of: $0) } }
        return GridKeyboardFactory.layout(
            id: id,
            title: title,
            localeIdentifier: localeIdentifier,
            centerCharacters: centers,
            directionalOverrides: directionalOverrides,
            returnOverrides: returnOverrides,
            composeRuleOverrides: base?.settings.composeRuleOverrides,
            supportsCapitalization: supportsCapitalization,
            slotDefaults: slotDefaults,
            numericBackToAlphaLabel: base?.numericBackToAlphaLabel ?? NumericLayouts.defaultBackToAlphaLabel,
            numericDigits: base?.numericDigits ?? NumericLayouts.westernDigits,
            inputMethod: base?.settings.inputMethod ?? .direct,
            combineRuleSet: base?.settings.combineRuleSet
        )
    }

    // MARK: - Keyboard → layout

    /// A custom layout that types exactly what `definition` types: the
    /// starting point of "Duplicate".
    ///
    /// Reads the main mode back into the document's terms: a tap character per
    /// key, and a binding for every gesture that differs from what the shared
    /// punctuation would put there (an override, or an explicit removal). The
    /// keys then keep their shared symbols — or, for a layout like Thumb-Key
    /// that carries none, the document turns `usesSharedSymbols` off, whichever
    /// reading needs fewer entries.
    ///
    /// Only plain-text bindings can be expressed; a shipped definition
    /// contains no other kind outside the shared set, which the document
    /// inherits unchanged.
    init(duplicating definition: KeyboardDefinition, id: String, title: String) {
        let main = definition.modes[ModeNames.main]
        let supportsCapitalization = definition.modes[ModeNames.shifted] != nil
        let locale = definition.locale

        func derive(shared: [String: [GestureType: KeyBinding]]) -> [String: [GestureType: CustomBinding]] {
            var result: [String: [GestureType: CustomBinding]] = [:]
            for slot in Self.slots {
                let bindings = main?.keys[slot]?.bindings ?? [:]
                var entries: [GestureType: CustomBinding] = [:]
                for gesture in Self.editableGestures {
                    let actual = bindings[gesture]
                    let inherited = shared[slot]?[gesture]
                    if gesture == .tap {
                        entries[.tap] = CustomBinding(Self.plainText(of: actual) ?? "")
                        continue
                    }
                    if actual == inherited { continue }
                    guard let actual else {
                        // The shift affordance is stripped from a main mode (⇩)
                        // or a caseless layout (⇧) by the factory itself, which
                        // a document must not repeat as an explicit removal.
                        if case .switchMode? = inherited?.action { continue }
                        entries[gesture] = CustomBinding("")
                        continue
                    }
                    guard let text = Self.plainText(of: actual) else { continue }
                    entries[gesture] = CustomBinding(
                        text, returnText: gesture.isSwipe ? Self.customReturn(of: actual, text: text, locale: locale) : nil
                    )
                }
                result[slot] = entries
            }
            return result
        }

        let sharedReading = derive(shared: CommonKeys.defaultSlotBindings)
        let bareReading = derive(shared: CommonKeys.essentialSlotBindings)
        func size(_ reading: [String: [GestureType: CustomBinding]]) -> Int {
            reading.values.reduce(0) { $0 + $1.count }
        }
        let bare = size(bareReading) < size(sharedReading)

        self.init(
            id: id,
            title: title,
            localeIdentifier: definition.localeIdentifier,
            basedOn: definition.id,
            supportsCapitalization: supportsCapitalization,
            usesSharedSymbols: !bare,
            keys: bare ? bareReading : sharedReading
        )
    }

    /// The text of a binding that simply commits its own label.
    private static func plainText(of binding: KeyBinding?) -> String? {
        guard let binding, case let .commitText(text) = binding.action,
              !text.isEmpty, binding.label == text
        else { return nil }
        return text
    }

    /// The return-swipe output of `binding`, when it is not the one the factory
    /// derives on its own (the uppercase of a letter).
    private static func customReturn(of binding: KeyBinding, text: String, locale: Locale) -> String? {
        guard case let .commitText(returned)? = binding.returnAction else { return nil }
        let isLetter = text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        let uppercased = text.keyboardUppercased(with: locale)
        let derived = isLetter && uppercased != text ? uppercased : nil
        return returned == derived ? nil : returned
    }
}
