//
//  InputSignposts.swift
//  Wurstfinger
//
//  Instruments hooks for the touch-down -> insertText path.
//

import os

/// Signpost intervals for the keystroke path, for profiling on a device.
///
/// Open Instruments' "os_signpost" (or the Points of Interest-style custom
/// track) and filter on subsystem `de.akator.wurstfinger`, category `input`.
/// A `keystroke` interval runs from the finger touching a key to the pipeline
/// having delivered its text to the host; `classify` and `dispatch` nest
/// inside it and show where the time goes.
///
/// Costs nothing when nobody is recording: `OSSignposter` checks one flag and
/// returns, and the interval state it hands back is a small value, so the hooks
/// stay in release builds.
enum InputSignposts {
    static let signposter = OSSignposter(subsystem: "de.akator.wurstfinger", category: "input")

    /// Names are `StaticString`s: signposts key their intervals on them.
    static let keystroke: StaticString = "keystroke"
    static let classify: StaticString = "classify"
    static let dispatch: StaticString = "dispatch"
}
