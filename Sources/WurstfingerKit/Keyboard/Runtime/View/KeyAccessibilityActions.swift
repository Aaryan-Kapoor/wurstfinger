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
///
/// The custom actions exist only while VoiceOver or Switch Control runs, the
/// assistive technologies that offer them: SwiftUI builds a view for every
/// action of every key, about 4.9 MB of heap per keyboard (the bench's row
/// 9c, `docs/performance.md`), which nobody else would ever use. Turning one
/// on mid-session re-renders the keys with their actions. The activation
/// override stays on always: it is one action, and it is what makes a key
/// with an inert tap work under any assistive input.
struct KeyAccessibilityActions: ViewModifier {
    let key: KeyDefinition
    let onGesture: (KeyDefinition, GestureType, Bool) -> Void

    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled
    @Environment(\.accessibilitySwitchControlEnabled) private var isSwitchControlEnabled

    /// Offers the custom actions whatever runs: for the benchmark's row that
    /// prices them, and for anything that inspects the actions off a device.
    @MainActor static var offersActionsAlways = false

    private var offersActions: Bool {
        isVoiceOverEnabled || isSwitchControlEnabled || Self.offersActionsAlways
    }

    /// Whether the word completion row is on (`offersCompletionAction`): the
    /// space bar's "Accept suggestion" is only worth a rotor entry then.
    @Environment(\.offersCompletionAction) private var offersCompletionAction

    private var actions: [KeyAccessibilityAction] {
        Self.actions(for: key, offersCompletionAction: offersCompletionAction)
    }

    /// The key's actions, without the ones that do nothing right now.
    static func actions(for key: KeyDefinition, offersCompletionAction: Bool) -> [KeyAccessibilityAction] {
        key.accessibilityActions.filter {
            offersCompletionAction || key.bindings[$0.gesture]?.action != .acceptCompletion
        }
    }

    func body(content: Content) -> some View {
        if offersActions {
            withActivation(content)
                .accessibilityActions {
                    ForEach(actions, id: \.name) { action in
                        Button { onGesture(key, action.gesture, action.isReturn) } label: { label(for: action) }
                    }
                }
        } else {
            withActivation(content)
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
