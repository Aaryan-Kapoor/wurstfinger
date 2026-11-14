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

private struct GestureTrailRecorderOverrideKey: EnvironmentKey {
    static let defaultValue: GestureTrailRecorder? = nil
}

extension EnvironmentValues {
    /// Ids of keys drawn as pressed regardless of touch state.
    var forcedActiveKeyIds: Set<String> {
        get { self[ForcedActiveKeyIdsKey.self] }
        set { self[ForcedActiveKeyIdsKey.self] = newValue }
    }

    /// A trail recorder the key grid uses in place of its own, so the host can
    /// drive it through `begin` / `extend` and have the overlay draw it.
    var gestureTrailRecorderOverride: GestureTrailRecorder? {
        get { self[GestureTrailRecorderOverrideKey.self] }
        set { self[GestureTrailRecorderOverrideKey.self] = newValue }
    }
}
