//
//  LanguageDefinitions+ThumbKey.swift
//  Wurstfinger
//
//  The English layout of the open-source Thumb-Key keyboard, on Wurstfinger's
//  3x3 grid.
//

import Foundation

extension LanguageDefinitions {
    // MARK: - English (Thumb-Key)

    /// Thumb-Key's English arrangement (dessalines/thumb-key, "EN Thumb-Key"):
    /// the frequent letters sit on the nine tap positions, the rest hang off
    /// them as swipes.
    ///
    /// ```
    ///  s  r  o        s: ↘ w      r: ↓ g       o: ↙ u
    ///  n  h  a        n: → m      h: all eight a: ← l, ↑ ⇧, ↓ ⇩
    ///  t  i  e        t: ↗ c      i: ↑ f ↗ ' → z ↘ - ↓ . ↙ *      e: ↖ d
    /// ```
    ///
    /// **Mapping decisions.** Thumb-Key's eight swipe directions are
    /// Wurstfinger's eight swipe gestures one to one (its `top` is a swipe up,
    /// its `bottomRight` a swipe down-right, ...), so every letter keeps the
    /// direction it has there. The shift swipes on `a` (up: shift, down:
    /// unshift) are Wurstfinger's own midRight shift bindings, which already
    /// sit exactly there, and their return swipe is the same
    /// capitalise-the-word action. The shifted mode is the generated
    /// uppercase of the main one, as Thumb-Key's is.
    ///
    /// Thumb-Key's other keys map onto the standard utility column:
    /// backspace, return, space (with its cursor slide) and the numeric key
    /// ("123"). What Thumb-Key puts on its numeric and symbol pages is what
    /// the numeric mode already offers, and what its space bar cycles through
    /// on repeated taps (`, . ? ! : ;`) is not expressible here, so those
    /// punctuation marks are reached from the numeric mode instead. The emoji
    /// key has no counterpart and is left out; the globe takes its column.
    /// The letter keys carry none of the shared MessagEase punctuation
    /// (`slotDefaults`): they hold exactly what Thumb-Key puts on them.
    static let thumbKeyEnglish = LanguageDescriptor(
        id: "en_US_thumbkey",
        title: "English (Thumb-Key)",
        localeIdentifier: "en_US",
        family: .thumbKey
    ) { meta in
        GridKeyboardFactory.layout(
            id: meta.id,
            title: meta.title,
            localeIdentifier: meta.localeIdentifier,
            centerCharacters: [
                ["s", "r", "o"],
                ["n", "h", "a"],
                ["t", "i", "e"],
            ],
            directionalOverrides: [
                GridSlot.topLeft: [.swipeDownRight: "w"],
                GridSlot.topCenter: [.swipeDown: "g"],
                GridSlot.topRight: [.swipeDownLeft: "u"],
                GridSlot.midLeft: [.swipeRight: "m"],
                GridSlot.center: [
                    .swipeUpLeft: "j", .swipeUp: "q", .swipeUpRight: "b",
                    .swipeRight: "p", .swipeDownRight: "y", .swipeDown: "x",
                    .swipeDownLeft: "v", .swipeLeft: "k",
                ],
                GridSlot.midRight: [.swipeLeft: "l"],
                GridSlot.bottomLeft: [.swipeUpRight: "c"],
                GridSlot.bottomCenter: [
                    .swipeUp: "f", .swipeUpRight: "'", .swipeRight: "z",
                    .swipeDownRight: "-", .swipeDown: ".", .swipeDownLeft: "*",
                ],
                GridSlot.bottomRight: [.swipeUpLeft: "d"],
            ],
            slotDefaults: CommonKeys.essentialSlotBindings
        )
    }
}
