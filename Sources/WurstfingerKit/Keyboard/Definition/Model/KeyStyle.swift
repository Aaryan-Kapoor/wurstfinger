//
//  KeyStyle.swift
//  Wurstfinger
//
//  Visual appearance of a key.
//

import Foundation

/// Visual appearance of a key.
enum KeyStyle: String, Codable, CaseIterable, Sendable {
    case primary // Main keys (letters) — large font, full background
    case secondary // Helper keys (swipe symbols) — smaller font
    case utility // Function keys (delete, return, globe) — icon instead of text
    case spacebar // Space bar — special rendering
    case accent // Accent/compose — visually highlighted
    case numpad // Numpad-column key — three digits side by side, symbols as hints
}
