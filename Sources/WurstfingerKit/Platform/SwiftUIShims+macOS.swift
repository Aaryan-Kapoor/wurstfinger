//
//  SwiftUIShims+macOS.swift
//  Wurstfinger
//
//  No-op macOS versions of the iOS-only SwiftUI modifiers the settings UI
//  uses, so the same views compile for the Mac build unchanged.
//

#if os(macOS)
import SwiftUI

/// Mirror of `NavigationBarItem.TitleDisplayMode`, which SwiftUI marks
/// unavailable on macOS.
enum NavigationBarTitleDisplayMode {
    case automatic, inline, large
}

/// Mirror of `UIKeyboardType`; the Mac has no software keyboard to configure.
enum UIKeyboardType {
    case `default`, asciiCapable, numbersAndPunctuation, URL, numberPad
    case phonePad, namePhonePad, emailAddress, decimalPad, twitter, webSearch
}

/// Mirror of `TextInputAutocapitalization`, which SwiftUI marks unavailable
/// on macOS.
enum TextInputAutocapitalization {
    case never, words, sentences, characters
}

extension View {
    func textInputAutocapitalization(_: TextInputAutocapitalization?) -> some View {
        self
    }

    func navigationBarTitleDisplayMode(_: NavigationBarTitleDisplayMode) -> some View {
        self
    }

    func keyboardType(_: UIKeyboardType) -> some View {
        self
    }

    func statusBarHidden(_: Bool = true) -> some View {
        self
    }

    func statusBar(hidden _: Bool) -> some View {
        self
    }
}

extension ToolbarItemPlacement {
    /// The Mac has no navigation bar; the automatic placement is the closest fit.
    static var navigationBarTrailing: ToolbarItemPlacement { .automatic }
    static var navigationBarLeading: ToolbarItemPlacement { .automatic }
}
#endif
