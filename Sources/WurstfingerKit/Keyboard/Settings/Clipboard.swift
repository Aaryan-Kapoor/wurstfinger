//
//  Clipboard.swift
//  Wurstfinger
//
//  The pasteboard, as far as the keyboard uses it: one string.
//

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Where copy, cut and paste read and write text.
///
/// The clipboard actions used to call `UIPasteboard.general` directly, so
/// their tests went through the developer's real clipboard (on a Mac,
/// `NSPasteboard.general` behind the shim): serialized against each other, racy
/// against a second test process, and overwriting whatever the developer had
/// copied. The middleware now takes a `Clipboard`; the keyboard hands it
/// `ClipboardStore.shared`, which is the system pasteboard everywhere except under
/// the unit-test runner (`UnitTestHost`).
@MainActor
protocol Clipboard: AnyObject {
    var string: String? { get set }
}

/// Process-wide default clipboard.
@MainActor
enum ClipboardStore {
    /// The system pasteboard, or an in-memory one under the unit-test runner
    /// so tests can never touch the developer's clipboard.
    static let shared: any Clipboard = UnitTestHost.isActive ? MemoryClipboard() : SystemClipboard()
}

/// `UIPasteboard.general` (on macOS, the shim over `NSPasteboard.general`).
@MainActor
final class SystemClipboard: Clipboard {
    var string: String? {
        get { UIPasteboard.general.string }
        set { UIPasteboard.general.string = newValue }
    }
}

/// A clipboard that lives in this object only.
@MainActor
final class MemoryClipboard: Clipboard {
    var string: String?

    init(string: String? = nil) {
        self.string = string
    }
}
