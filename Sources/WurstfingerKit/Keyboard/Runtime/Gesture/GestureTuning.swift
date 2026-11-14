//
//  GestureTuning.swift
//  Wurstfinger
//
//  The user's gesture-recognition settings, resolved once into an immutable
//  value so the touch path never reads UserDefaults.
//

import CoreGraphics
import Foundation

/// Everything gesture classification and long-press detection need from the
/// user's settings, captured as one immutable, `Sendable` snapshot.
///
/// **Why a snapshot.** Classifying a completed touch used to rebuild the
/// preprocessor configuration and the classification thresholds from
/// `UserDefaults` on every key release — about a dozen keyed lookups, each a
/// dictionary read behind the defaults machinery, on the main thread, between
/// the finger lifting and the character appearing. None of those values can
/// change *during* a gesture, and they change rarely at all, so the view model
/// resolves them once (`KeyboardViewModel.gestureTuning`), rebuilds the
/// snapshot only when a settings signal arrives, and threads the value down to
/// the recognizers. The per-keystroke path then does arithmetic only.
///
/// A snapshot is a plain value: it can be handed to any isolation domain, and
/// two snapshots compare equal exactly when they would classify identically,
/// which lets a reload that changed nothing be recognised as such.
struct GestureTuning: Sendable, Equatable {
    /// Preprocessor settings (jitter, outlier distance, smoothing window). The
    /// aspect ratio is a per-key property and is applied at classification time.
    var config: GesturePreprocessorConfiguration

    /// Tap / swipe / return / circle decision thresholds.
    var thresholds: GestureClassificationThresholds

    /// How long a finger must rest before a long press fires.
    var longPressDuration: TimeInterval

    /// Travel from touch-down that cancels a pending long press.
    var longPressMovementTolerance: CGFloat

    /// Whether the swipe trail is drawn. Read on every touch-down by the trail
    /// recorder, so it belongs in the snapshot with the other touch-path
    /// settings instead of costing the touch a defaults lookup.
    var isTrailEnabled: Bool

    /// Stock settings: what an untouched installation (or expert mode off)
    /// classifies with.
    static let `default` = GestureTuning(
        config: .default,
        thresholds: .default,
        longPressDuration: KeyboardConstants.LongPress.duration,
        longPressMovementTolerance: KeyboardConstants.LongPress.movementTolerance,
        isTrailEnabled: false
    )

    /// Resolves the snapshot from a defaults store. The only place the
    /// per-gesture settings are read; call it when settings change, never per
    /// touch.
    static func load(from store: UserDefaults = SharedDefaults.store) -> GestureTuning {
        GestureTuning(
            config: .fromUserDefaults(store: store),
            thresholds: .fromUserDefaults(store: store),
            longPressDuration: KeyboardConstants.LongPress.duration,
            longPressMovementTolerance: KeyboardConstants.LongPress.movementTolerance,
            isTrailEnabled: store.bool(forKey: SettingsKey.gestureTrailEnabled.rawValue)
        )
    }
}

/// The typing-behaviour toggles the action pipeline consults while handling a
/// keystroke, resolved once like `GestureTuning`.
///
/// Auto-capitalization, the double-space period and cut-all each used to do a
/// `UserDefaults.bool(forKey:)` inside the middleware chain — one lookup per
/// keystroke per feature, on the main thread, for values that change only when
/// the user visits Settings. They now read this snapshot, which the view model
/// refreshes in `reloadSettings()`.
struct TypingBehavior: Sendable, Equatable {
    /// Capitalize the first letter of a sentence automatically.
    var autoCapitalizeEnabled = false
    /// Two spaces in a row type the sentence terminator plus a space.
    var doubleSpacePeriodEnabled = false
    /// Circling the clipboard key cuts everything around the cursor.
    var cutAllEnabled = false
    /// How the space bar moves the cursor.
    var cursorMovement: CursorMovementType = .continuous

    /// Resolves the toggles from a defaults store. Call when settings change,
    /// never per keystroke.
    static func load(from store: UserDefaults = SharedDefaults.store) -> TypingBehavior {
        TypingBehavior(
            autoCapitalizeEnabled: store.bool(forKey: SettingsKey.autoCapitalizeEnabled.rawValue),
            doubleSpacePeriodEnabled: store.bool(forKey: SettingsKey.doubleSpacePeriodEnabled.rawValue),
            cutAllEnabled: store.bool(forKey: SettingsKey.cutAllEnabled.rawValue),
            cursorMovement: store.string(forKey: SettingsKey.cursorMovementStyle.rawValue)
                .flatMap(CursorMovementType.init(rawValue:)) ?? .continuous
        )
    }
}
