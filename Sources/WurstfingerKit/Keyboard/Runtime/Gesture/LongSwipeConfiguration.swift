//
//  LongSwipeConfiguration.swift
//  Wurstfinger
//
//  Long swipes: a flick that travels well past the key it started on fires a
//  global action chosen per direction instead of the key's own swipe binding.
//  Flickboard (Android MessagEase) calls them "long swipes" and defaults them
//  to the actions below; here they are an opt-in Expert setting (issue #79).
//

import CoreGraphics
import Foundation

/// What a long swipe in one direction can be set to. The raw value is what the
/// settings screen stores, so cases are never renamed once shipped.
enum LongSwipeAction: String, CaseIterable, Codable, Sendable {
    /// Nothing: a flick in this direction stays an ordinary swipe.
    case none
    case escape
    case tab
    case backTab
    case newline
    case space
    case deleteBackward
    case deleteWordBackward
    case lineStart
    case lineEnd
    case documentStart
    case documentEnd
    case dismissKeyboard

    /// The pipeline action this choice performs, or `nil` for `.none`.
    var keyAction: KeyAction? {
        switch self {
        case .none: nil
        case .escape: .escape
        case .tab: .tab
        case .backTab: .backTab
        case .newline: .newline
        case .space: .space
        case .deleteBackward: .deleteBackward
        case .deleteWordBackward: .deleteWordBackward
        case .lineStart: .lineStart
        case .lineEnd: .lineEnd
        case .documentStart: .documentStart
        case .documentEnd: .documentEnd
        case .dismissKeyboard: .dismissKeyboard
        }
    }
}

/// The user's long-swipe settings, resolved once into an immutable value that
/// lives in `GestureTuning` — the touch path never reads `UserDefaults` for
/// them.
///
/// **Distance.** A flick counts as long when the finger ends up farther from
/// where it landed than `threshold` key sizes, measured the way Flickboard
/// does: each axis is divided by the key's own extent along it (width for x,
/// height for y) and the length of the resulting vector is compared. A square
/// key and a wide key therefore ask for the same *relative* reach, and a
/// diagonal needs less absolute travel than the cardinal directions of a long
/// key — it is the number of keys crossed that matters, not points.
///
/// **Which swipe.** Only plain swipes qualify: a tap, a circle, or a return
/// swipe (out and back, so the finger ends near its start) is never a long
/// swipe, whatever its extent.
struct LongSwipeConfiguration: Sendable, Equatable {
    /// Whether long swipes are on at all. Off by default, and only ever on
    /// while expert mode is, because that is where the settings live.
    var isEnabled = false

    /// Distance, in key sizes, past which a flick is a long swipe.
    var threshold: CGFloat = LongSwipeConfiguration.defaultThreshold

    /// The action per direction. A direction without an entry has no long
    /// swipe, so a long flick that way stays an ordinary swipe.
    var actions: [GestureType: KeyAction] = LongSwipeConfiguration.defaultActions

    // MARK: - Defaults and ranges

    static let defaultThreshold: CGFloat = 1.5
    /// The range the settings screen offers; stored values are clamped to it.
    static let thresholdRange: ClosedRange<Double> = 1.0 ... 3.0

    /// The eight directions, in the order the settings screen lists them.
    static let directions: [GestureType] = [
        .swipeUp, .swipeDown, .swipeLeft, .swipeRight,
        .swipeUpLeft, .swipeUpRight, .swipeDownLeft, .swipeDownRight,
    ]

    /// Flickboard's defaults: Esc up, Return down, delete word left, Tab right,
    /// Shift-Tab up-left, line start up-right, line end down-right, hide
    /// keyboard down-left.
    static let defaultChoices: [GestureType: LongSwipeAction] = [
        .swipeUp: .escape,
        .swipeDown: .newline,
        .swipeLeft: .deleteWordBackward,
        .swipeRight: .tab,
        .swipeUpLeft: .backTab,
        .swipeUpRight: .lineStart,
        .swipeDownRight: .lineEnd,
        .swipeDownLeft: .dismissKeyboard,
    ]

    /// `defaultChoices` as pipeline actions.
    static let defaultActions: [GestureType: KeyAction] = actions(from: defaultChoices)

    private static func actions(from choices: [GestureType: LongSwipeAction]) -> [GestureType: KeyAction] {
        choices.compactMapValues(\.keyAction)
    }

    // MARK: - Storage

    /// The stored setting that holds the choice for `gesture`.
    static func settingsKey(for gesture: GestureType) -> SettingsKey? {
        switch gesture {
        case .swipeUp: .longSwipeUp
        case .swipeDown: .longSwipeDown
        case .swipeLeft: .longSwipeLeft
        case .swipeRight: .longSwipeRight
        case .swipeUpLeft: .longSwipeUpLeft
        case .swipeUpRight: .longSwipeUpRight
        case .swipeDownLeft: .longSwipeDownLeft
        case .swipeDownRight: .longSwipeDownRight
        default: nil
        }
    }

    /// Resolves the configuration from a defaults store. Call it when settings
    /// change, never per touch. Like the other gesture tuning, the stored
    /// values only apply while expert mode is on.
    static func load(from store: UserDefaults = SharedDefaults.store) -> LongSwipeConfiguration {
        guard store.bool(forKey: SettingsKey.expertModeEnabled.rawValue),
              store.bool(forKey: SettingsKey.isLongSwipeEnabled.rawValue)
        else { return LongSwipeConfiguration() }

        var choices = defaultChoices
        for gesture in directions {
            guard let key = settingsKey(for: gesture),
                  let stored = store.string(forKey: key.rawValue),
                  let choice = LongSwipeAction(rawValue: stored)
            else { continue }
            choices[gesture] = choice
        }

        var threshold = defaultThreshold
        if store.object(forKey: SettingsKey.longSwipeThreshold.rawValue) != nil {
            let stored = store.double(forKey: SettingsKey.longSwipeThreshold.rawValue)
            if stored.isFinite {
                threshold = CGFloat(min(max(stored, thresholdRange.lowerBound), thresholdRange.upperBound))
            }
        }
        return LongSwipeConfiguration(
            isEnabled: true, threshold: threshold, actions: actions(from: choices)
        )
    }

    // MARK: - Resolution

    /// The long swipe a completed gesture is, or `nil` when it is an ordinary
    /// one: long swipes are off, the gesture is not a plain swipe, the finger
    /// did not travel `threshold` key sizes, or the direction has no action.
    func action(for classification: GestureClassification) -> KeyAction? {
        guard isEnabled, classification.gesture.isSwipe, !classification.isReturn,
              Self.length(of: classification.displacementInKeys) >= threshold
        else { return nil }
        return actions[classification.gesture]
    }

    /// Whether a finger that has moved by `translation` from where it landed
    /// on a key of `keySize` is, right now, far enough that releasing would
    /// fire a long swipe. Drives the trail's colour change while dragging.
    ///
    /// Pure, and cheap enough to run on every drag sample: a few multiplies and
    /// one dictionary lookup. It judges the *current* position, which is also
    /// what a release is judged on, so the trail changes colour exactly when
    /// letting go would fire — and changes back if the finger returns.
    func isArmed(translation: CGSize, keySize: CGSize) -> Bool {
        guard isEnabled, keySize.width > 0, keySize.height > 0 else { return false }
        let units = CGVector(
            dx: translation.width / keySize.width, dy: translation.height / keySize.height
        )
        guard Self.length(of: units) >= threshold else { return false }
        // The same sector map the classifier uses. Dividing by the key's own
        // extent per axis is the aspect-ratio normalisation the preprocessor
        // applies, so both agree on the direction.
        let gesture = KeyGestureRecognizer.angleToGestureType(atan2(units.dy, units.dx))
        return actions[gesture] != nil
    }

    private static func length(of vector: CGVector) -> CGFloat {
        hypot(vector.dx, vector.dy)
    }
}
