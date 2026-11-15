//
//  SnapshotHooks.swift
//  Wurstfinger
//
//  Environment values that let a headless host put the keyboard into a state
//  that otherwise needs a finger on the screen: a key held in the pressed
//  state, a gesture trail mid-flick. The snapshot tool uses them to render
//  those states; both default to "nothing", so in the app the views behave
//  exactly as they did without them.
//

import SwiftUI

private struct ForcedActiveKeyIdsKey: EnvironmentKey {
    static let defaultValue: Set<String> = []
}

/// When the guide card shows the touched key's whole map.
enum TouchGuideReveal: Sendable {
    /// After the finger has rested for `TouchGuideCard.revealDelay` (the app).
    case afterPause
    /// From the first frame: a still of a finger that has paused.
    case immediately
    /// Never: a still of a fluent flick, which a renderer that skips the
    /// delay would otherwise show revealed.
    case never
}

private struct TouchGuideRevealKey: EnvironmentKey {
    static let defaultValue = TouchGuideReveal.afterPause
}

private struct TouchSurfaceEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

private struct GestureTrailRecorderOverrideKey: EnvironmentKey {
    static let defaultValue: GestureTrailRecorder? = nil
}

private struct OffersCompletionActionKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ForcedPressedCompletionKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

extension EnvironmentValues {
    /// Ids of keys drawn as pressed regardless of touch state.
    var forcedActiveKeyIds: Set<String> {
        get { self[ForcedActiveKeyIdsKey.self] }
        set { self[ForcedActiveKeyIdsKey.self] = newValue }
    }

    /// Whether the word completion row is on, so the space bar offers
    /// "Accept suggestion" to VoiceOver (set by the root view from the row's
    /// height; off elsewhere, where the action would do nothing).
    var offersCompletionAction: Bool {
        get { self[OffersCompletionActionKey.self] }
        set { self[OffersCompletionActionKey.self] = newValue }
    }

    /// Index of the word completion drawn pressed regardless of touch state.
    var forcedPressedCompletion: Int? {
        get { self[ForcedPressedCompletionKey.self] }
        set { self[ForcedPressedCompletionKey.self] = newValue }
    }

    /// A trail recorder the key grid uses in place of its own, so the host can
    /// drive it through `begin` / `extend` and have the overlay draw it.
    var gestureTrailRecorderOverride: GestureTrailRecorder? {
        get { self[GestureTrailRecorderOverrideKey.self] }
        set { self[GestureTrailRecorderOverrideKey.self] = newValue }
    }

    /// Whether the key grid installs its native touch surface. A headless
    /// renderer cannot draw native views (it would show a placeholder), so it
    /// turns this off and feeds the view model's `TouchEngine` itself.
    var isTouchSurfaceEnabled: Bool {
        get { self[TouchSurfaceEnabledKey.self] }
        set { self[TouchSurfaceEnabledKey.self] = newValue }
    }

    /// When guide cards reveal their map. A still picture cannot wait for the
    /// reveal delay, so headless hosts choose the state they are drawing.
    var touchGuideReveal: TouchGuideReveal {
        get { self[TouchGuideRevealKey.self] }
        set { self[TouchGuideRevealKey.self] = newValue }
    }
}
