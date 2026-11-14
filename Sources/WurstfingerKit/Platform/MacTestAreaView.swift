//
//  MacTestAreaView.swift
//  Wurstfinger
//
//  The Mac build's stand-in for the Test tab. On iOS the Test tab is a text
//  editor you type into with the installed keyboard extension; a Mac has no
//  such extension to install, so this hosts the live keyboard in-process,
//  wired to an in-memory text target, with the same settings the extension
//  would read.
//

#if os(macOS)
import SwiftUI

struct MacTestAreaView: View {
    @AppStorage(SettingsKey.keyAspectRatio.rawValue, store: SharedDefaults.store)
    private var keyAspectRatio = DeviceLayout.defaultKeyAspectRatio

    @AppStorage(SettingsKey.keyboardWidthPoints.rawValue, store: SharedDefaults.store)
    private var keyboardWidth = DeviceLayout.defaultKeyboardWidth

    @AppStorage(SettingsKey.keyboardHorizontalPosition.rawValue, store: SharedDefaults.store)
    private var keyboardPosition = DeviceLayout.defaultKeyboardPosition

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text(verbatim: "Click and drag on the keys below as you would swipe on a phone. Typed text appears above the keyboard.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    InteractiveKeyboardPreview(
                        aspectRatio: $keyAspectRatio,
                        width: $keyboardWidth,
                        position: $keyboardPosition
                    )
                }
                .padding()
                .frame(maxWidth: DeviceLayout.screenBounds.width)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Test")
        }
    }
}

#if !WURSTFINGER_NO_PREVIEWS
#Preview {
    MacTestAreaView()
}
#endif
#endif
