//
//  GestureTracesView.swift
//  wurstfinger
//
//  The opt-in gesture recorder: the switch, what it stores, how many traces
//  there are, and the way to export or erase them. Reached from the Expert screen.
//

import SwiftUI

struct GestureTracesView: View {
    @AppStorage(SettingsKey.gestureTraceRecording.rawValue, store: SharedDefaults.store)
    private var isRecording = false

    @AppStorage(SettingsKey.keyboardFullAccess.rawValue, store: SharedDefaults.store)
    private var hasFullAccess = false

    @State private var count = 0
    @State private var exportURL: URL?
    @State private var isConfirmingClear = false

    /// Full Access is known to be missing — as opposed to not yet reported,
    /// which happens before the keyboard has been opened once.
    private var isFullAccessDenied: Bool {
        SharedDefaults.store.object(forKey: SettingsKey.keyboardFullAccess.rawValue) != nil && !hasFullAccess
    }

    var body: some View {
        Form {
            Section {
                Toggle("Record Gesture Traces", isOn: $isRecording)
                    .disabled(isFullAccessDenied)
                if isFullAccessDenied {
                    Text("Needs Full Access, which is off for this keyboard.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } footer: {
                // swiftlint:disable:next line_length
                Text("Saves the shape and timing of your gestures on this device, so the recognizer can be tuned to how you really type. It stores no characters and no text, nothing from password, URL, email or code fields, and nothing leaves your device unless you export it. The last 2,000 gestures are kept.")
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                LabeledContent("Stored Traces") {
                    Text(verbatim: "\(count)").monospacedDigit()
                }
                if let exportURL, count > 0 {
                    ShareLink(item: exportURL) {
                        Label("Export Traces", systemImage: "square.and.arrow.up")
                    }
                }
                Button(role: .destructive) {
                    isConfirmingClear = true
                } label: {
                    Text("Clear Traces")
                }
                .disabled(count == 0)
            }
        }
        .navigationTitle("Gesture Traces")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .confirmationDialog("Clear all gesture traces?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("Clear Traces", role: .destructive) {
                GestureTraceStore.shared.clear()
                Task { await refresh() }
            }
        } message: {
            Text("Every stored trace is deleted from this device. This cannot be undone.")
        }
    }

    /// Counts the stored traces and writes the export file the share sheet hands
    /// on, off the main actor: both read the whole store.
    private func refresh() async {
        let result = await Task.detached(priority: .utility) { () -> (Int, URL?) in
            let store = GestureTraceStore.shared
            let count = store.count()
            guard count > 0, let data = store.exportJSON() else { return (count, nil) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("wurstfinger-gesture-traces.json")
            try? data.write(to: url, options: .atomic)
            return (count, url)
        }.value
        count = result.0
        exportURL = result.1
    }
}

#if !WURSTFINGER_NO_PREVIEWS
#Preview {
    NavigationStack {
        GestureTracesView()
    }
}
#endif
