//
//  GestureTypingAccessibility.swift
//  Wurstfinger
//
//  The touch surface's face to VoiceOver.
//

import SwiftUI

/// How the touch surface presents itself to assistive technologies.
///
/// Normally it is hidden: VoiceOver reads the keys beneath it one by one and
/// offers every character as a named action (`KeyAccessibilityActions`).
///
/// With "Gesture Typing with VoiceOver" on and VoiceOver running, it becomes a
/// single direct-touch area instead: VoiceOver passes the raw touches through
/// to the input engine, so a flick types exactly as it does without VoiceOver,
/// and the view model speaks each target as the finger heads for it
/// (`SpokenFeedback`). `silentOnTouch` keeps VoiceOver from talking over that
/// with the area's own label on every touch-down. The keys leave the
/// accessibility tree meanwhile (`KeyboardGridView`).
struct GestureTypingAccessibility: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content
                .accessibilityElement()
                .accessibilityLabel(Text("Keyboard"))
                .accessibilityHint(Text("Flick to type. The character is spoken as you move; lift your finger to type it."))
                .accessibilityDirectTouch(options: .silentOnTouch)
        } else {
            content.accessibilityHidden(true)
        }
    }
}
