//
//  KeyAccessibilityActions.swift
//  Wurstfinger
//
//  Exposes a key's non-tap gestures to assistive technologies.
//

import SwiftUI

/// Makes a key operable without gestures.
///
/// VoiceOver activates an element by synthesizing a touch, which reaches the
/// gesture recognizer as a plain tap — so every swipe-only binding is out of
/// reach, including the globe's input-method switch, whose tap is inert by
/// design. Each labelled binding becomes a named custom action, and a key
/// with an inert tap additionally overrides the element's default activation
/// with the gesture it declares. Every character on the key's other gestures
/// is offered too, named by character and gesture (#231). All of them
/// dispatch through the same `onGesture` callback as a real touch, so they
/// share the resolver chain and pipeline.
struct KeyAccessibilityActions: ViewModifier {
    let key: KeyDefinition
    let onGesture: (KeyDefinition, GestureType, Bool) -> Void

    func body(content: Content) -> some View {
        withActivation(content)
            .accessibilityActions {
                ForEach(key.accessibilityActions, id: \.name) { action in
                    Button { onGesture(key, action.gesture, action.isReturn) } label: { label(for: action) }
                }
            }
    }

    /// A character action spells its glyph out, so VoiceOver reads "ä, swipe
    /// down" and names a lone mark ("period") in the user's language instead
    /// of passing over it; named actions read as written.
    private func label(for action: KeyAccessibilityAction) -> Text {
        guard let glyph = action.glyph, let gestureName = action.gestureName else {
            return Text(verbatim: action.name)
        }
        return Text(verbatim: glyph).speechSpellsOutCharacters() + Text(verbatim: ", " + gestureName)
    }

    /// Applied only where it is needed: a key whose tap already acts keeps the
    /// synthesized tap, so activation and touch stay one code path.
    @ViewBuilder
    private func withActivation(_ content: Content) -> some View {
        if let gesture = key.accessibilityActivationOverride {
            content.accessibilityAction { onGesture(key, gesture, false) }
        } else {
            content
        }
    }
}
