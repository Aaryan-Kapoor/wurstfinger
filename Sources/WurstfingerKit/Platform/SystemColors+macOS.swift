//
//  SystemColors+macOS.swift
//  Wurstfinger
//
//  macOS stand-ins for the UIColor semantic colors the shared SwiftUI code
//  reads as `Color(.systemBackground)` and friends. With these in place the
//  same call sites resolve to SwiftUI's `Color(_: NSColor)` initializer on
//  macOS, so no call site needs an `#if`.
//
//  The values are the iOS light/dark system colors rather than AppKit's
//  window colors: the Mac build exists to exercise the keyboard, and the
//  keys should look the way they do on a phone.
//

#if os(macOS)
import AppKit

extension NSColor {
    /// A color that resolves to `light` or `dark` with the effective appearance.
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    private static func rgb(_ red: Int, _ green: Int, _ blue: Int, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: alpha
        )
    }

    static var systemBackground: NSColor {
        dynamic(light: rgb(255, 255, 255), dark: rgb(0, 0, 0))
    }

    static var secondarySystemBackground: NSColor {
        dynamic(light: rgb(242, 242, 247), dark: rgb(28, 28, 30))
    }

    static var systemGray3: NSColor {
        dynamic(light: rgb(199, 199, 204), dark: rgb(72, 72, 74))
    }

    static var systemGray4: NSColor {
        dynamic(light: rgb(209, 209, 214), dark: rgb(58, 58, 60))
    }

    static var systemGray5: NSColor {
        dynamic(light: rgb(229, 229, 234), dark: rgb(44, 44, 46))
    }

    static var systemGray6: NSColor {
        dynamic(light: rgb(242, 242, 247), dark: rgb(28, 28, 30))
    }

    static var systemFill: NSColor {
        dynamic(light: rgb(120, 120, 128, 0.20), dark: rgb(120, 120, 128, 0.36))
    }

    static var tertiarySystemFill: NSColor {
        dynamic(light: rgb(118, 118, 128, 0.12), dark: rgb(118, 118, 128, 0.24))
    }

    static var placeholderText: NSColor {
        dynamic(light: rgb(60, 60, 67, 0.30), dark: rgb(235, 235, 245, 0.30))
    }
}
#endif
