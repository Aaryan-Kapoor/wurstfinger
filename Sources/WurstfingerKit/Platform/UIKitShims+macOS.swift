//
//  UIKitShims+macOS.swift
//  Wurstfinger
//
//  Just enough of UIKit's surface, named identically, for the shared
//  keyboard and settings code to compile and run on macOS unchanged. These
//  types exist only on macOS; on iOS the real UIKit ones are used.
//

#if os(macOS)
import AppKit
import CoreGraphics

// MARK: - Screen and device

/// Fixed phone-sized "screen" so the keyboard lays out at iPhone width when
/// hosted in a Mac window (390 x 844 pt, an iPhone 14/15/16-class display).
///
/// `@MainActor` like the real `UIScreen`, so shared code that reads it is
/// isolation-checked the same way on both platforms.
@MainActor
struct UIScreen {
    static let main = UIScreen()
    static let phoneBounds = CGRect(x: 0, y: 0, width: 390, height: 844)

    var bounds: CGRect { Self.phoneBounds }
}

enum UIUserInterfaceIdiom: Sendable {
    case phone
    case pad
}

/// `@MainActor` like the real `UIDevice`.
@MainActor
struct UIDevice {
    static let current = UIDevice()

    /// A Mac window hosts the phone keyboard, so the device class is always phone.
    var userInterfaceIdiom: UIUserInterfaceIdiom { .phone }
}

// MARK: - Haptics

/// Trackpad haptics standing in for the Taptic Engine generators. The macOS
/// performer is a no-op on Macs without a Force Touch trackpad.
@MainActor
private func performTrackpadHaptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
    NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
}

/// `@MainActor` like the real feedback generators: feedback is triggered from
/// the touch handler on the main thread.
@MainActor
final class UISelectionFeedbackGenerator {
    init() {}

    func prepare() {}

    func selectionChanged() {
        performTrackpadHaptic(.alignment)
    }
}

@MainActor
final class UIImpactFeedbackGenerator {
    enum FeedbackStyle: Int, Hashable, Sendable {
        case light, medium, heavy, soft, rigid
    }

    private let style: FeedbackStyle

    init(style: FeedbackStyle) {
        self.style = style
    }

    func prepare() {}

    func impactOccurred() {
        // The trackpad has three patterns; spread the five impact styles
        // across them so stronger levels still feel different.
        switch style {
        case .soft, .light: performTrackpadHaptic(.generic)
        case .medium: performTrackpadHaptic(.alignment)
        case .heavy, .rigid: performTrackpadHaptic(.levelChange)
        }
    }
}

// MARK: - Pasteboard

/// `UIPasteboard.general.string` backed by `NSPasteboard.general`.
/// `@MainActor` like the real `UIPasteboard`; the clipboard actions run in the
/// main-actor action pipeline.
@MainActor
final class UIPasteboard {
    static let general = UIPasteboard()

    private init() {}

    var string: String? {
        get { NSPasteboard.general.string(forType: .string) }
        set {
            NSPasteboard.general.clearContents()
            if let newValue {
                NSPasteboard.general.setString(newValue, forType: .string)
            }
        }
    }

    /// Every item on the pasteboard as `[type: data]`, so a caller can save
    /// the whole clipboard and put it back (the tests do).
    var items: [[String: Any]] {
        get {
            (NSPasteboard.general.pasteboardItems ?? []).map { item in
                var entry: [String: Any] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) { entry[type.rawValue] = data }
                }
                return entry
            }
        }
        set {
            NSPasteboard.general.clearContents()
            let restored = newValue.map { entry -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, value) in entry {
                    switch value {
                    case let data as Data: item.setData(data, forType: NSPasteboard.PasteboardType(type))
                    case let text as String: item.setString(text, forType: NSPasteboard.PasteboardType(type))
                    default: break
                    }
                }
                return item
            }
            if !restored.isEmpty { NSPasteboard.general.writeObjects(restored) }
        }
    }
}
#endif

#if os(macOS)
import Foundation

// MARK: - Memory

/// `os_proc_available_memory()` is iOS-only (the extension's jetsam headroom).
/// A Mac has no such per-process budget, so report physical memory as the
/// headroom; the health log is diagnostics only.
func os_proc_available_memory() -> Int {
    Int(clamping: ProcessInfo.processInfo.physicalMemory)
}
#endif
