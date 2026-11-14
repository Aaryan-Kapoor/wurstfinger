//
//  InputSignposts.swift
//  Wurstfinger
//
//  The signpost intervals around a keystroke, for Instruments.
//

import os

/// The `os_signpost` intervals bracketing the input path: `keystroke` from
/// touch-down to the pipeline returning, with `classify` and `dispatch`
/// nested inside. Subsystem `de.akator.wurstfinger`, category `input`.
///
/// Emitted through the `os_signpost` function on an `OSLog`, not through
/// `OSSignposter`: the latter's `beginInterval` builds an interval-state
/// object on every call even when no client is recording — three heap
/// allocations per keystroke, the bench found (`OSSignposter.isEnabled`
/// reports true regardless, so it could not be gated). `os_signpost` with a
/// fixed `OSSignpostID` and no message allocates nothing, and costs a flag
/// check until Instruments attaches.
enum InputSignposts {
    static let log = OSLog(subsystem: "de.akator.wurstfinger", category: "input")

    /// Names are `StaticString`s: signposts key their intervals on them.
    static let keystroke: StaticString = "keystroke"
    static let classify: StaticString = "classify"
    static let dispatch: StaticString = "dispatch"

    /// One id per interval name. The keyboard never has two intervals of the
    /// same name open at once (a new keystroke closes the previous one), so a
    /// fixed id per name pairs each begin with its end.
    static let keystrokeID = OSSignpostID(log: log)
    static let classifyID = OSSignpostID(log: log)
    static let dispatchID = OSSignpostID(log: log)

    @inline(__always)
    static func begin(_ name: StaticString, _ id: OSSignpostID) {
        os_signpost(.begin, log: log, name: name, signpostID: id)
    }

    @inline(__always)
    static func end(_ name: StaticString, _ id: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: id)
    }
}
