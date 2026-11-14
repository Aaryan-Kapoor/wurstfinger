//
//  FieldTraits.swift
//  Wurstfinger
//
//  What the host's text field says about itself, as far as it changes what
//  the keyboard may show while typing into it.
//

import SwiftUI

/// The host field's traits that matter to the keyboard, read from the text
/// document proxy whenever the field changes (`KeyboardViewController`).
struct FieldTraits: Equatable, Sendable {
    /// The field holds something not to be seen over the user's shoulder or
    /// in a screen recording: a password shown in clear, a one-time code, a
    /// card number. (A true secure-entry field never reaches a custom
    /// keyboard — iOS swaps in its own — but the flag counts if a host sets it.)
    ///
    /// Nothing typed lingers on screen there: no gesture trail, no guide card
    /// naming the character, no glyph lifting off the key. The key's own hint
    /// still lights as the finger heads for it, like the system keyboard's key
    /// pop-up, so flicking stays as easy as anywhere else.
    var isSensitive = false

    /// The host says suggestions have no place in the field: a URL, an email
    /// address, a number, a username, or autocorrection switched off
    /// (`CompletionFieldPolicy`).
    var suppressesCompletions = false

    /// Whether word completions may show here. A sensitive field never gets
    /// them: the row would spell the beginning of a secret across the
    /// screen, and the words typed there must not be learned.
    var allowsCompletions: Bool { !isSensitive && !suppressesCompletions }

    static let standard = FieldTraits()
}

extension GestureTuning {
    /// The tuning as it applies in a field with `traits`: the trail is drawn
    /// only where what it traces may be seen.
    func applying(_ traits: FieldTraits) -> GestureTuning {
        guard traits.isSensitive, isTrailEnabled else { return self }
        var tuning = self
        tuning.isTrailEnabled = false
        return tuning
    }
}

private struct ShowsTypedCharactersKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether the keyboard may show the character a gesture is about to type
    /// (the guide card); false in a sensitive field (`FieldTraits`).
    var showsTypedCharacters: Bool {
        get { self[ShowsTypedCharactersKey.self] }
        set { self[ShowsTypedCharactersKey.self] = newValue }
    }
}
