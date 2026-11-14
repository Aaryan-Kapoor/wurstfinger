//
//  CapitalsLongPressResolver.swift
//  Wurstfinger
//
//  Resolver for the "Capitals" long press (issue #308): holding a letter key
//  types its capital.
//

/// Resolves a long press on a letter key to the capital the shifted mode
/// types for it.
///
/// The capital is the *shifted mode's own tap binding*, not an uppercasing
/// done here, so whatever the layout defines is what a hold types: Turkish
/// `i` → `İ`, German `ß` → `ẞ`, a manual override in the shifted mode, a
/// two-letter digraph. (`KeyboardMode.generateShifted` builds that mode with the
/// definition's locale and its overrides.)
///
/// Exactly where the shifted mode would type something *different* from the
/// key's tap does the hold resolve: in the shifted and caps-lock modes the
/// tap is already the capital, so a hold there stays a hold with nothing to
/// do and the touch keeps its normal tap on release — as it does on
/// non-letter keys (digits, punctuation, the utility keys) and in caseless
/// scripts, which have no shifted mode at all.
///
/// A key's own explicit long-press binding wins, unless it is a digit: those are
/// the "type numbers by holding" bindings (the space bar's zero), which belong
/// to the Digits behaviour and would otherwise leak into this one. Anything
/// else a layout declares for a hold (a custom layout's `longPress` field) is
/// the layout's deliberate choice and stays.
///
/// Part of the policy `CompiledMode` is compiled from (its Capitals table);
/// not called per keystroke.
struct CapitalsLongPressResolver: GestureResolver {
    let shiftedMode: KeyboardMode

    func resolve(keyId: String, gesture: GestureType, in mode: KeyboardMode) -> KeyBinding? {
        guard gesture == .longPress, let key = mode.key(for: keyId) else { return nil }
        if let explicit = key.bindings[.longPress], explicit.category != .digit {
            return explicit
        }
        guard let tap = key.bindings[.tap],
              tap.resolvedCategory == .letter,
              case let .commitText(text) = tap.action,
              let shifted = shiftedMode.key(for: keyId)?.bindings[.tap],
              case let .commitText(capital) = shifted.action,
              capital != text
        else { return nil }
        return shifted
    }
}

/// Resolves the digit a key carries in the numeric mode: what the Digits long
/// press types and what a circle set to "Digit" types.
///
/// The same lookup `GhostKeyResolver` makes for a hold with no explicit
/// binding — the fallback key's tap, when it is a digit — but without
/// deferring to the key's own long-press binding, so a circle gets the key's
/// digit even on a key whose hold does something else.
struct NumericDigitResolver: Sendable {
    let numericMode: KeyboardMode

    func digit(forKeyId keyId: String) -> KeyBinding? {
        guard let tap = numericMode.key(for: keyId)?.bindings[.tap], tap.category == .digit else {
            return nil
        }
        return tap
    }
}
