//
//  GestureBehaviours.swift
//  Wurstfinger
//
//  What a hold and a circle do: the user's choices (issue #308 and the circle
//  behaviours), resolved once into the `TypingBehavior` snapshot.
//

import Foundation

/// What holding a key does. Stored under `SettingsKey.longPressBehaviour` by
/// raw value, so cases are never renamed once shipped.
///
/// Replaces the old on/off "Numbers on long press" switch
/// (`SettingsKey.isLongPressDigitEnabled`, stored as `longPressNumbersEnabled`):
/// `off` and `digits` are exactly its two states.
enum LongPressType: String, CaseIterable, Sendable {
    /// A hold is just a slow tap: no timer runs, nothing swells.
    case off
    /// A hold types the digit the key carries in the numeric mode (the space
    /// bar types zero). Today's behaviour.
    case digits
    /// A hold on a letter key types its capital, taken from the shifted
    /// mode's tap binding so the layout's own casing applies (Turkish i → İ,
    /// ß → ẞ).
    case capitals

    /// Whether the touch engine arms its hold timer at all.
    var isEnabled: Bool {
        self != .off
    }

    /// What an untouched installation does.
    static let `default` = LongPressType.off

    /// Reads the choice from a defaults store: the stored value, or — on a
    /// store the migration has not reached yet — what the legacy boolean
    /// implies. Never writes.
    static func load(from store: UserDefaults = SharedDefaults.store) -> LongPressType {
        if let stored = store.string(forKey: SettingsKey.longPressBehaviour.rawValue),
           let type = LongPressType(rawValue: stored) {
            return type
        }
        return legacyChoice(in: store) ?? .default
    }

    /// The choice the old boolean encoded, or nil when it was never written.
    private static func legacyChoice(in store: UserDefaults) -> LongPressType? {
        guard let legacy = store.object(forKey: SettingsKey.isLongPressDigitEnabled.rawValue) as? Bool else {
            return nil
        }
        return legacy ? .digits : .off
    }

    /// Carries the old "Numbers on long press" switch over to the picker,
    /// exactly once: `true` becomes Digits, `false` Off. Once the picker's own
    /// key exists the switch is never consulted again, so a later toggle of
    /// the (downgraded) old build cannot undo a choice made here.
    ///
    /// The legacy value stays in the store for downgrade safety, like
    /// `keyboardScale` does. A store that never held the switch is left
    /// untouched: the default needs no stored value.
    ///
    /// The host app calls this at launch and the keyboard on load, whichever
    /// runs first; the second finds the key and does nothing.
    static func migrateLegacyIfNeeded(in store: UserDefaults) {
        guard store.object(forKey: SettingsKey.longPressBehaviour.rawValue) == nil,
              let migrated = legacyChoice(in: store)
        else { return }
        store.set(migrated.rawValue, forKey: SettingsKey.longPressBehaviour.rawValue)
    }
}

/// What a circle on a letter key types, per direction. Expert setting; stored
/// under `SettingsKey.clockwiseCircleBehaviour` / `counterclockwiseCircleBehaviour`.
///
/// Only the circle's *fallback* is configurable: a key that declares its own
/// binding for the direction (the clipboard key's cut-all, the numeric mode's
/// superscripts) keeps it, whatever is chosen here.
enum CircleType: String, CaseIterable, Sendable {
    /// The key's capital letter. Today's behaviour for both directions.
    case uppercase
    /// The digit the key carries in the numeric mode (what a hold types with
    /// the Digits long press). Flickboard users pair this with a capital on
    /// the other direction.
    case digit
    /// Capitalizes the word before the cursor (`capitalizeWord`), typing
    /// nothing of its own.
    case uppercaseWord

    static let `default` = CircleType.uppercase

    /// The stored choice for a direction, or the default for a missing or
    /// unknown value. Like the other Expert tuning, it only applies while
    /// expert mode is on; the stored value is kept for when it is switched on
    /// again.
    static func load(_ key: SettingsKey, from store: UserDefaults = SharedDefaults.store) -> CircleType {
        guard store.bool(forKey: SettingsKey.expertModeEnabled.rawValue),
              let stored = store.string(forKey: key.rawValue),
              let type = CircleType(rawValue: stored)
        else { return .default }
        return type
    }
}
