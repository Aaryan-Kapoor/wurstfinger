//
//  CircleSettingsView.swift
//  wurstfinger
//
//  What a circle on a letter key types, per direction. Reached from the Expert
//  screen; the choices only apply while expert mode is on.
//

import SwiftUI

struct CircleSettingsView: View {
    @AppStorage(SettingsKey.clockwiseCircleBehaviour.rawValue, store: SharedDefaults.store)
    private var clockwiseRaw = CircleType.default.rawValue

    @AppStorage(SettingsKey.counterclockwiseCircleBehaviour.rawValue, store: SharedDefaults.store)
    private var counterclockwiseRaw = CircleType.default.rawValue

    var body: some View {
        Form {
            Section {
                picker("Clockwise Circle", icon: "arrow.clockwise", selection: $clockwiseRaw)
                picker("Counter-clockwise Circle", icon: "arrow.counterclockwise", selection: $counterclockwiseRaw)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose what a circle on a letter key types. Keys with a circle of their own, like the clipboard key, keep it.")
                    Text("Digit types the number the key carries in the numeric layout. Uppercase Word capitalizes the word before the cursor.")
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("Circles")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Reset") {
                    clockwiseRaw = CircleType.default.rawValue
                    counterclockwiseRaw = CircleType.default.rawValue
                }
            }
        }
    }

    private func picker(_ title: LocalizedStringKey, icon: String, selection: Binding<String>) -> some View {
        Picker(selection: selection) {
            ForEach(CircleType.allCases, id: \.rawValue) { type in
                Text(type.displayName).tag(type.rawValue)
            }
        } label: {
            Label(title, systemImage: icon)
        }
    }
}

extension CircleType {
    /// What the settings screen calls this choice. Lives here, next to the
    /// screen: the strings are host-app only, and the enum is compiled into the
    /// keyboard extension too (see `docs/localization.md`).
    var displayName: String {
        switch self {
        case .uppercase: String(localized: "Uppercase")
        case .digit: String(localized: "Digit")
        case .uppercaseWord: String(localized: "Uppercase Word")
        }
    }
}

#if !WURSTFINGER_NO_PREVIEWS
#Preview {
    NavigationStack {
        CircleSettingsView()
    }
}
#endif
