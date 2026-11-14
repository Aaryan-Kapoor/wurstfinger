//
//  FeelEnvironment.swift
//  Wurstfinger
//
//  Hands the feel layer's board from the view model to the key grid.
//

import SwiftUI

private struct FeelBoardKey: EnvironmentKey {
    static let defaultValue: FeelBoard? = nil
}

private struct FeelStillFrameKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// The board the grid's feel overlay draws (`FeelOverlay`), set by the
    /// keyboard's root view from its view model; nil in hosts without one,
    /// where the grid draws no overlay.
    var feelBoard: FeelBoard? {
        get { self[FeelBoardKey.self] }
        set { self[FeelBoardKey.self] = newValue }
    }

    /// A headless host's pose for the feel layer's transient animations: the
    /// commit pop, the long-press ring and the glass ripple are drawn frozen
    /// at this fraction (0...1) of their run instead of animating. Nil in the
    /// app. (Same idea as `touchGuideReveal`: a still cannot wait for an
    /// animation.)
    var feelStillFrame: CGFloat? {
        get { self[FeelStillFrameKey.self] }
        set { self[FeelStillFrameKey.self] = newValue }
    }
}
