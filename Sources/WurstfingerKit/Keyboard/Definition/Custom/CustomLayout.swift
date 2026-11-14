//
//  CustomLayout.swift
//  Wurstfinger
//
//  A keyboard layout the user made: the 3x3 letter grid and what each swipe
//  on it types.
//

import Foundation

/// What one gesture on a custom key types.
struct CustomBinding: Sendable, Equatable {
    /// The text the gesture commits (also its label). Empty means "nothing":
    /// the gesture is left unbound even where the shared punctuation would put
    /// something.
    var text: String

    /// What a swipe out and back types instead; `nil` leaves it to the default
    /// (the uppercase of `text` for a letter, `text` otherwise).
    var returnText: String?

    init(_ text: String, returnText: String? = nil) {
        self.text = text
        self.returnText = returnText
    }
}

/// A keyboard layout the user made or imported: the nine letter keys of the
/// grid and what every gesture on them types.
///
/// This is the *authoring* form of a layout, deliberately smaller than
/// `KeyboardDefinition`: the shift, delete, space, return, globe and numeric
/// keys, the shifted and caps-lock modes and the numeric mode are the same in
/// every layout, so a document names only what differs — the way
/// `GridKeyboardFactory.layout` is called for a shipped language.
/// `makeDefinition(basedOn:)` runs exactly that factory, so a custom layout
/// is built, validated, cached and rendered by the same code as a shipped one.
///
/// A `Sendable` value: it is decoded once, when the set of layouts changes, and
/// the registry keeps it until the definition is first built.
struct CustomLayout: Sendable, Equatable, Identifiable {
    /// Longest display name accepted.
    static let maxTitleLength = 40
    /// Longest text one gesture may commit, in characters.
    static let maxTextLength = 8

    /// Stable identifier, also the file name and the id the language settings
    /// store. Never a shipped layout's id.
    var id: String

    /// Display name in the language list and on the settings screens.
    var title: String

    /// Locale for uppercasing and auto-capitalisation (`en_US`, `tr_TR`).
    var localeIdentifier: String

    /// Id of the shipped layout this was started from. Its settings that a
    /// grid of letters cannot express (input method, compose rules, the digit
    /// set) carry over; `nil`, or an id that no longer ships, means defaults.
    var basedOn: String?

    /// Whether the script has letter case. `false` drops the shifted and
    /// caps-lock modes, as for Hebrew.
    var supportsCapitalization: Bool

    /// Whether the keys also carry the shared MessagEase punctuation
    /// (`CommonKeys.defaultSlotBindings`) wherever the layout does not say
    /// otherwise. `false` keeps only the shift affordance and the period, like
    /// Thumb-Key (see `CommonKeys.essentialSlotBindings`).
    var usesSharedSymbols: Bool

    /// What the layout binds: slot id, then gesture. A gesture absent from a
    /// key inherits the shared punctuation (when `usesSharedSymbols`), an empty
    /// `CustomBinding.text` removes it. Every slot's `.tap` is required.
    var keys: [String: [GestureType: CustomBinding]]

    init(
        id: String,
        title: String,
        localeIdentifier: String,
        basedOn: String? = nil,
        supportsCapitalization: Bool = true,
        usesSharedSymbols: Bool = true,
        keys: [String: [GestureType: CustomBinding]]
    ) {
        self.id = id
        self.title = title
        self.localeIdentifier = localeIdentifier
        self.basedOn = basedOn
        self.supportsCapitalization = supportsCapitalization
        self.usesSharedSymbols = usesSharedSymbols
        self.keys = keys
    }

    // MARK: - Grid

    /// The nine slot ids in reading order.
    static let slots: [String] = GridSlot.allSlots.flatMap { $0 }

    /// The gestures a custom key can bind, in the order the editor lists them.
    static let editableGestures: [GestureType] = [
        .tap,
        .swipeUpLeft, .swipeUp, .swipeUpRight,
        .swipeLeft, .swipeRight,
        .swipeDownLeft, .swipeDown, .swipeDownRight,
        .circularClockwise, .circularCounterclockwise,
        .longPress,
    ]

    /// The character a key types on a tap, or an empty string when unset.
    func tapText(of slot: String) -> String {
        keys[slot]?[.tap]?.text ?? ""
    }

    /// A fresh identifier for a new layout: a lowercase UUID behind a prefix
    /// that no shipped id uses.
    static func makeID() -> String {
        "custom-" + UUID().uuidString.lowercased()
    }
}
