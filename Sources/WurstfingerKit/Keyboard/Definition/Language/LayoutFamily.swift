//
//  LayoutFamily.swift
//  Wurstfinger
//
//  Which kind of layout a keyboard language is.
//

import Foundation

/// The kind of layout a selectable keyboard is.
///
/// Every layout shares the same chrome and gesture engine; the family says
/// whose letter arrangement it is, which is all the language list shows.
enum LayoutFamily: Sendable, Equatable {
    /// A MessagEase arrangement (the app's native layouts).
    case messagEase

    /// A MessagEase arrangement with letters moved where measurement says they
    /// cost less to type (see docs/layout-science.md).
    case optimized

    /// The English layout of the open-source Thumb-Key keyboard.
    case thumbKey

    /// A layout the user made or imported (see `CustomLayout`).
    case custom
}

/// How far a layout's letters have been moved from the language's standard
/// MessagEase arrangement.
enum LayoutVariant: String, Sendable, Equatable, CaseIterable {
    /// The shipped MessagEase arrangement.
    case standard

    /// A few letters moved where the language's own text says they cost less
    /// to type (`layoutlab`, docs/layout-science.md).
    case optimized

    /// Every letter placed by the same search, without the few-moves limit.
    case full
}
