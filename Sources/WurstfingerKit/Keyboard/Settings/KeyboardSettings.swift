//
//  KeyboardSettings.swift
//  Wurstfinger
//
//  Extracted from KeyboardViewModel to reduce code duplication
//  and improve separation of concerns.
//

import CoreGraphics
import Foundation
import Observation

// MARK: - Settings Keys

/// Centralized storage for all UserDefaults keys used by the keyboard.
/// Using an enum prevents typos and makes refactoring easier.
/// The rawValues are persisted storage keys. A case name may be brought in
/// line with the glossary, but only together with an explicit rawValue that
/// keeps the string already on disk — renaming a case that relies on the
/// implicit rawValue silently resets that setting on every installed device.
enum SettingsKey: String, CaseIterable, Sendable {
    case hapticIntensityTap
    case hapticIntensityDrag
    /// Legacy master toggle — only read to migrate an explicit "off" into
    /// intensity 0, then removed.
    case hapticEnabled
    case utilityColumnLeading
    case keyAspectRatio
    /// Legacy fraction-of-screen-width size. Read once to migrate into
    /// `keyboardWidthPoints`; the stored value is kept for downgrade safety
    /// but no longer consulted afterwards.
    case keyboardScale
    /// Keyboard width wish in points (density- and orientation-independent).
    case keyboardWidthPoints
    case keyboardHorizontalPosition
    case numpadStyle
    case selectedLanguageId
    case enabledLanguageIds
    case pinnedLanguageId
    case autoCapitalizeEnabled
    case expertModeEnabled
    case keyboardStyle
    case keyboardFullAccess
    case cursorMovementStyle
    /// The three label-visibility flags and the long-press flag below carry
    /// an explicit rawValue: the case name reads as an assertion, while the
    /// string stays the one every installed device already has the setting
    /// written under. The strings are the persisted keys and must not change.
    case areLetterLabelsHidden = "hideLetters"
    case areStandardSymbolLabelsHidden = "hideStandardSymbols"
    case areExtraSymbolLabelsHidden = "hideExtraSymbols"
    /// Legacy: holding a letter key types the digit that key carries in
    /// numeric mode, without switching to it. Replaced by `longPressBehaviour`;
    /// only read to migrate (`LongPressType.migrateLegacyIfNeeded`) and kept in
    /// the store for downgrade safety.
    case isLongPressDigitEnabled = "longPressNumbersEnabled"
    /// What holding a key does: nothing, the key's digit, or its capital
    /// (`LongPressType` raw value, issue #308).
    case longPressBehaviour
    /// What a circle on a letter key types, per direction (Expert,
    /// `CircleType` raw value).
    case clockwiseCircleBehaviour, counterclockwiseCircleBehaviour
    /// Typing a second consecutive space inserts a period followed by a
    /// space (the iOS "." Shortcut), when the character before the pending
    /// space is a letter or digit.
    case doubleSpacePeriodEnabled
    /// Circling the clipboard key cuts the text around the cursor.
    /// Opt-in: the action is destructive and unaided by undo, so it stays off
    /// until asked for rather than surprising anyone who circles the key.
    case cutAllEnabled
    /// Draws a fading trail under the finger while it swipes.
    /// Opt-in: it is a learning and demonstration aid, and continuous
    /// redrawing costs battery, so experienced users are not made to pay for
    /// it. Off also keeps the keyboard visually identical to before.
    case gestureTrailEnabled
    /// Long swipes (Expert): a flick past `longSwipeThreshold` key sizes fires
    /// a global action chosen per direction instead of the key's own swipe.
    /// Off by default.
    case isLongSwipeEnabled
    /// Distance, in key sizes, past which a flick is a long swipe.
    case longSwipeThreshold
    /// The `LongSwipeAction` raw value chosen for each of the eight directions.
    case longSwipeUp, longSwipeDown, longSwipeLeft, longSwipeRight
    case longSwipeUpLeft, longSwipeUpRight, longSwipeDownLeft, longSwipeDownRight
    /// Where the compact numpad column sits beside the letter grid:
    /// a `NumpadColumnPlacement` raw value ("off", "leading", "trailing").
    /// Off by default, which leaves the keyboard exactly as it was.
    case numpadColumn
    /// The gap between keys in points (`KeyboardConstants.Layout.minKeySpacing`
    /// ... `maxKeySpacing`); unset means the shipped spacing.
    case keySpacing
    /// Splits the keyboard on wide landscape screens: the letter grid on one
    /// side, the utility (and numpad) columns on the other, the middle empty.
    /// Off by default.
    case isSplitLayoutEnabled = "splitLayoutEnabled"
    /// The user's text-replacement shortcuts, a JSON array of
    /// `{shortcut, phrase}` objects (see `TextReplacementTable`).
    case textReplacements
    /// Opaque token the host app rewrites whenever the set of custom layouts
    /// changes (add, edit, delete, import). The keyboard extension compares it
    /// with the one its layouts were loaded for, and re-reads the layout files
    /// only when it differs, so a settings reload costs one string read.
    case customLayoutsRevision
    /// Core Haptics patterns (a distinct feel per gesture, direction detents,
    /// the long-press swell) instead of the plain UIKit clicks. On by default;
    /// the switch is the escape hatch for a device or process where Core
    /// Haptics starts but stays silent.
    case detailedHapticsEnabled
    /// The keys' press, release and commit animations and the light effects
    /// on them. On by default; Reduce Motion is honoured either way.
    case keyAnimationsEnabled
    /// The system keyboard's click on every touch-down. Off by default; plays
    /// only with Full Access and follows the ring / silent switch.
    case keyClicksEnabled
    /// Under VoiceOver, the keyboard takes flicks directly (a direct-touch
    /// area) and speaks the character a flick would type, instead of VoiceOver
    /// reading each key. Off by default (`SpokenFeedback`).
    case voiceOverGestureTyping
    /// Up to three completions of the word before the cursor in a row above the
    /// keys (`WordCompletions`). Off by default: the row takes height from the
    /// keys, and a flick keyboard's key size is its muscle memory.
    case wordCompletionsEnabled
    /// Remember words the system dictionary does not know (names, jargon) and
    /// offer them once typed twice. On by default, inside the row's own switch;
    /// the words never leave the keyboard's container (`LearnedWordStore`).
    case learnsWords
    /// Opaque token the host app rewrites when the user clears the learned
    /// words. The keyboard owns the list (the app cannot reach its container),
    /// so it wipes it when the token it last saw differs.
    case learnedWordsClearToken
    // EMOJI MODE: the recent key's nine emoji, newest first (`EmojiRecents`).
    // Read when settings reload, written when the emoji mode is left.
    case emojiRecents
    /// EMOJI MODE: the skin tone of the hands and people, 0 (default) to 5
    /// (`EmojiSkinTone`). Read when settings reload.
    case emojiSkinTone
}

// MARK: - Haptic Settings

/// Encapsulates all haptic-related settings with built-in persistence.
/// Eliminates duplicate didSet handlers by using a unified approach.
///
/// `@Observable` rather than `ObservableObject`: a view that reads only
/// `tapIntensity` is invalidated only when `tapIntensity` changes, where the
/// old `objectWillChange` (forwarded by the view model) re-rendered the whole
/// keyboard for any haptic slider movement. Main-actor, because the settings
/// are read by the haptic player and bound by SwiftUI controls.
@MainActor
@Observable
final class HapticSettings {
    /// Default intensity values (0.0 - 1.0). Both map to a discrete
    /// `HapticIntensityLevel`; level `.off` (intensity 0) disables the
    /// respective feedback, so there is no separate master switch.
    /// Defaults mirror the iOS system keyboard's subtle feel: a soft tap
    /// per keystroke, detent ticks for drags.
    static let defaultTapIntensity: CGFloat = HapticIntensityLevel.soft.storedIntensity
    static let defaultDragIntensity: CGFloat = HapticIntensityLevel.tick.storedIntensity

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let shouldPersist: Bool

    var tapIntensity: CGFloat {
        didSet {
            let clamped = Self.clamp(tapIntensity)
            if clamped != tapIntensity {
                tapIntensity = clamped
                return
            }
            persistIfNeeded(Double(clamped), forKey: .hapticIntensityTap)
        }
    }

    var dragIntensity: CGFloat {
        didSet {
            let clamped = Self.clamp(dragIntensity)
            if clamped != dragIntensity {
                dragIntensity = clamped
                return
            }
            persistIfNeeded(Double(clamped), forKey: .hapticIntensityDrag)
        }
    }

    /// Core Haptics patterns on (see `SettingsKey.detailedHapticsEnabled`).
    var isDetailedEnabled: Bool {
        didSet { persistIfNeeded(isDetailedEnabled, forKey: .detailedHapticsEnabled) }
    }

    init(defaults: UserDefaults = SharedDefaults.store, shouldPersist: Bool = true) {
        self.defaults = defaults
        self.shouldPersist = shouldPersist
        isDetailedEnabled = Self.loadDetailed(from: defaults)

        // Load values with clamping
        tapIntensity = Self.loadIntensity(from: defaults, key: .hapticIntensityTap, default: Self.defaultTapIntensity)
        dragIntensity = Self.loadIntensity(from: defaults, key: .hapticIntensityDrag, default: Self.defaultDragIntensity)

        // Migrate the removed master toggle: an explicit "off" becomes level
        // `.off` on both sliders, so users who had haptics disabled stay
        // silent after the update.
        if defaults.object(forKey: SettingsKey.hapticEnabled.rawValue) as? Bool == false {
            tapIntensity = 0
            dragIntensity = 0
            if shouldPersist {
                defaults.set(0.0, forKey: SettingsKey.hapticIntensityTap.rawValue)
                defaults.set(0.0, forKey: SettingsKey.hapticIntensityDrag.rawValue)
            }
        }
        if shouldPersist {
            defaults.removeObject(forKey: SettingsKey.hapticEnabled.rawValue)
        }
    }

    /// Reload settings from UserDefaults (e.g., after changes from host app)
    func reload() {
        let newTap = Self.loadIntensity(from: defaults, key: .hapticIntensityTap, default: Self.defaultTapIntensity)
        if abs(tapIntensity - newTap) > 0.0001 { tapIntensity = newTap }

        let newDrag = Self.loadIntensity(from: defaults, key: .hapticIntensityDrag, default: Self.defaultDragIntensity)
        if abs(dragIntensity - newDrag) > 0.0001 { dragIntensity = newDrag }

        let newDetailed = Self.loadDetailed(from: defaults)
        if isDetailedEnabled != newDetailed { isDetailedEnabled = newDetailed }
    }

    /// The slider a haptic cue follows (see `HapticCue.channel`).
    func intensity(for channel: HapticChannel) -> CGFloat {
        switch channel {
        case .touch: tapIntensity
        case .slide: dragIntensity
        }
    }

    private static func loadDetailed(from defaults: UserDefaults) -> Bool {
        defaults.object(forKey: SettingsKey.detailedHapticsEnabled.rawValue) as? Bool ?? true
    }

    /// Returns the intensity for a given haptic event type
    func intensity(for event: KeyboardHapticEvent) -> CGFloat {
        switch event {
        case .tap, .stateChange: tapIntensity
        case .drag: dragIntensity
        }
    }

    // MARK: - Private Helpers

    private static func loadIntensity(from defaults: UserDefaults, key: SettingsKey, default defaultValue: CGFloat) -> CGFloat {
        guard let stored = defaults.object(forKey: key.rawValue) as? NSNumber else {
            return defaultValue
        }
        return clamp(CGFloat(stored.doubleValue))
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }

    private func persistIfNeeded(_ value: some Any, forKey key: SettingsKey) {
        guard shouldPersist else { return }
        defaults.set(value, forKey: key.rawValue)
    }
}

// MARK: - Layout Settings

/// Encapsulates keyboard layout settings (position, scale, aspect ratio).
/// `@Observable` for the same reason as `HapticSettings`: the grid re-renders
/// for the layout property it reads, not for every setting in the object.
@MainActor
@Observable
final class LayoutSettings {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let shouldPersist: Bool

    var utilityColumnLeading: Bool {
        didSet { persistIfNeeded(utilityColumnLeading, forKey: .utilityColumnLeading) }
    }

    /// Key aspect ratio (width/height). Range: 1.0 (square) to 1.62 (golden ratio)
    var keyAspectRatio: Double {
        didSet {
            let clamped = Self.clampAspectRatio(keyAspectRatio)
            if clamped != keyAspectRatio {
                keyAspectRatio = clamped
                return
            }
            persistIfNeeded(clamped, forKey: .keyAspectRatio)
        }
    }

    /// Keyboard width wish in points. Range: 90 to 600.
    ///
    /// This is the *wish*: what the user asked for, independent of device
    /// and orientation. The rendered *result* may be smaller (fit-clamped by
    /// `KeyboardLayoutMetrics.resolve`), but the clamp is never written back.
    var keyboardWidth: Double {
        didSet {
            let clamped = Self.clampWidth(keyboardWidth)
            if clamped != keyboardWidth {
                keyboardWidth = clamped
                return
            }
            persistIfNeeded(clamped, forKey: .keyboardWidthPoints)
        }
    }

    /// Gap between keys in points, `minKeySpacing`...`maxKeySpacing`. The same
    /// value across and down, in every mode, orientation and language.
    var keySpacing: Double {
        didSet {
            let clamped = Self.clampSpacing(keySpacing)
            if clamped != keySpacing {
                keySpacing = clamped
                return
            }
            persistIfNeeded(clamped, forKey: .keySpacing)
        }
    }

    /// Where the numpad column sits (or `.off`).
    var numpadColumn: NumpadColumnPlacement {
        didSet { persistIfNeeded(numpadColumn.rawValue, forKey: .numpadColumn) }
    }

    /// Whether wide landscape screens get the split layout.
    var isSplitLayoutEnabled: Bool {
        didSet { persistIfNeeded(isSplitLayoutEnabled, forKey: .isSplitLayoutEnabled) }
    }

    /// Horizontal position (0.0 = left, 0.5 = center, 1.0 = right)
    var keyboardHorizontalPosition: Double {
        didSet {
            let clamped = Self.clampPosition(keyboardHorizontalPosition)
            if clamped != keyboardHorizontalPosition {
                keyboardHorizontalPosition = clamped
                return
            }
            persistIfNeeded(clamped, forKey: .keyboardHorizontalPosition)
        }
    }

    init(defaults: UserDefaults = SharedDefaults.store, shouldPersist: Bool = true) {
        self.defaults = defaults
        self.shouldPersist = shouldPersist

        utilityColumnLeading = defaults.object(forKey: SettingsKey.utilityColumnLeading.rawValue) as? Bool ?? false

        let savedRatio = defaults.object(forKey: SettingsKey.keyAspectRatio.rawValue) as? Double
            ?? DeviceLayout.defaultKeyAspectRatio
        keyAspectRatio = Self.clampAspectRatio(savedRatio)

        keyboardWidth = Self.loadWishWidth(from: defaults, shouldPersist: shouldPersist)

        let savedPosition = defaults.object(forKey: SettingsKey.keyboardHorizontalPosition.rawValue) as? Double
            ?? DeviceLayout.defaultKeyboardPosition
        keyboardHorizontalPosition = Self.clampPosition(savedPosition)

        keySpacing = Self.loadSpacing(from: defaults)
        numpadColumn = Self.loadNumpadColumn(from: defaults)
        isSplitLayoutEnabled = defaults.object(forKey: SettingsKey.isSplitLayoutEnabled.rawValue) as? Bool ?? false
    }

    /// Reload settings from UserDefaults
    func reload() {
        let newUtility = defaults.object(forKey: SettingsKey.utilityColumnLeading.rawValue) as? Bool ?? false
        if utilityColumnLeading != newUtility { utilityColumnLeading = newUtility }

        let savedRatio = defaults.object(forKey: SettingsKey.keyAspectRatio.rawValue) as? Double
            ?? DeviceLayout.defaultKeyAspectRatio
        let newRatio = Self.clampAspectRatio(savedRatio)
        if keyAspectRatio != newRatio { keyAspectRatio = newRatio }

        let newWidth = Self.loadWishWidth(from: defaults, shouldPersist: shouldPersist)
        if keyboardWidth != newWidth { keyboardWidth = newWidth }

        let savedPosition = defaults.object(forKey: SettingsKey.keyboardHorizontalPosition.rawValue) as? Double
            ?? DeviceLayout.defaultKeyboardPosition
        let newPosition = Self.clampPosition(savedPosition)
        if keyboardHorizontalPosition != newPosition { keyboardHorizontalPosition = newPosition }

        let newSpacing = Self.loadSpacing(from: defaults)
        if keySpacing != newSpacing { keySpacing = newSpacing }

        let newNumpadColumn = Self.loadNumpadColumn(from: defaults)
        if numpadColumn != newNumpadColumn { numpadColumn = newNumpadColumn }

        let newSplit = defaults.object(forKey: SettingsKey.isSplitLayoutEnabled.rawValue) as? Bool ?? false
        if isSplitLayoutEnabled != newSplit { isSplitLayoutEnabled = newSplit }
    }

    // MARK: - Layout Metrics

    /// Resolves the persisted wish (width + aspect ratio) into concrete
    /// metrics for a render context. Pure: fit-clamps shrink the result but
    /// never write back to the store.
    func resolveMetrics(
        columns: Int,
        wishColumns: Int? = nil,
        rows: Int = KeyboardConstants.KeyDimensions.totalRows,
        availableWidth: CGFloat,
        screenHeight: CGFloat
    ) -> KeyboardLayoutMetrics {
        KeyboardLayoutMetrics.resolve(
            wishWidth: keyboardWidth,
            aspectRatio: keyAspectRatio,
            columns: columns,
            wishColumns: wishColumns,
            rows: rows,
            availableWidth: availableWidth,
            screenHeight: screenHeight,
            spacing: CGFloat(keySpacing)
        )
    }

    // MARK: - Migration

    /// Performs the one-time legacy `keyboardScale` → `keyboardWidthPoints`
    /// migration without constructing a settings instance. The host app calls
    /// this at launch **before** registering defaults (a registered width
    /// would make the key appear present and mask a pending migration); the
    /// extension migrates in `init`/`reload`.
    static func migrateLegacyScaleIfNeeded(in defaults: UserDefaults) {
        _ = loadWishWidth(from: defaults, shouldPersist: true)
    }

    /// Loads the wish width, migrating a legacy `keyboardScale` exactly once.
    ///
    /// - A stored `keyboardWidthPoints` always wins (clamped on load).
    /// - Otherwise a user-persisted legacy scale (fraction of screen width)
    ///   is converted against the orientation-stable shortest screen side —
    ///   on iPhone this preserves the rendered width existing users see —
    ///   and persisted once. The legacy key stays in the store for downgrade
    ///   safety; it is simply no longer read afterwards.
    /// - With neither present, the device-class default applies and is NOT
    ///   persisted (fallback only, like the other layout defaults).
    private static func loadWishWidth(from defaults: UserDefaults, shouldPersist: Bool) -> Double {
        if let stored = defaults.object(forKey: SettingsKey.keyboardWidthPoints.rawValue) as? Double {
            return clampWidth(stored)
        }
        if let legacyScale = defaults.object(forKey: SettingsKey.keyboardScale.rawValue) as? Double {
            let bounds = DeviceLayout.screenBounds
            let shortestSide = min(bounds.width, bounds.height)
            let clampedScale = min(1.0, max(0.25, legacyScale))
            let width = clampWidth(clampedScale * shortestSide)
            if shouldPersist {
                defaults.set(width, forKey: SettingsKey.keyboardWidthPoints.rawValue)
            }
            return width
        }
        return DeviceLayout.defaultKeyboardWidth
    }

    // MARK: - Private Helpers

    /// Aspect ratio range: 1.0 (square) to 1.62 (golden ratio)
    private static func clampAspectRatio(_ value: Double) -> Double {
        min(1.62, max(1.0, value))
    }

    /// Wish-width range in points: 90 (below the old 0.25×iPhone-mini
    /// minimum) to 600 (beyond any full iPhone width, room for iPad tuning).
    private static func clampWidth(_ value: Double) -> Double {
        min(600, max(90, value))
    }

    /// Spacing range in points: `minKeySpacing` (keys touch) to `maxKeySpacing`.
    /// A non-finite stored value falls back to the shipped spacing.
    static func clampSpacing(_ value: Double) -> Double {
        guard value.isFinite else { return Double(KeyboardConstants.Layout.defaultKeySpacing) }
        return min(Double(KeyboardConstants.Layout.maxKeySpacing), max(Double(KeyboardConstants.Layout.minKeySpacing), value))
    }

    private static func loadSpacing(from defaults: UserDefaults) -> Double {
        let stored = defaults.object(forKey: SettingsKey.keySpacing.rawValue) as? Double
            ?? Double(KeyboardConstants.Layout.defaultKeySpacing)
        return clampSpacing(stored)
    }

    private static func loadNumpadColumn(from defaults: UserDefaults) -> NumpadColumnPlacement {
        defaults.string(forKey: SettingsKey.numpadColumn.rawValue)
            .flatMap(NumpadColumnPlacement.init(rawValue:)) ?? .off
    }

    /// Position range: 0.0 (left) to 1.0 (right)
    private static func clampPosition(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }

    private func persistIfNeeded(_ value: some Any, forKey key: SettingsKey) {
        guard shouldPersist else { return }
        defaults.set(value, forKey: key.rawValue)
    }
}

// MARK: - Numpad Type

enum NumpadType: String, CaseIterable, Sendable {
    case phone // 1-2-3 / 4-5-6 / 7-8-9 (default, like phone keypad)
    case classic // 7-8-9 / 4-5-6 / 1-2-3 (like calculator)
}

// MARK: - Numpad Column Placement

/// Whether the always-available numpad column is shown, and on which side of
/// the letter grid. "Leading" and "trailing" are physical (left / right, as the
/// keyboard is pinned to left-to-right), and the column sits *next to the
/// letters*: the utility column keeps the outer edge on its own side, whichever
/// way "Utility Keys on Left" is set. (Not a `…Type` or `…Style`: it is a
/// placement of a column in the layout, neither a digit order nor a look.)
enum NumpadColumnPlacement: String, CaseIterable, Sendable {
    case off
    case leading
    case trailing

    var isEnabled: Bool { self != .off }
}

// MARK: - Cursor Movement Type

/// Space bar cursor movement type
enum CursorMovementType: String, CaseIterable, Sendable {
    case continuous // Joystick-style: drag distance controls cursor position
    case discrete // MessagEase-style: one swipe = one character, return-swipe = one word
}

// MARK: - Keyboard Style

/// Visual style for the keyboard appearance
enum KeyboardStyle: String, CaseIterable, Sendable {
    case classic // Traditional opaque key backgrounds
    case liquidGlass // iOS 26+ Liquid Glass effect (renders as a simplified translucent style on older iOS)
}
