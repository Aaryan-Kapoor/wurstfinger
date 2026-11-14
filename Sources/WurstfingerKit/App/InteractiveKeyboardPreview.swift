//
//  InteractiveKeyboardPreview.swift
//  wurstfinger
//
//  Created by Claas Flint on 19.11.25.
//

import Observation
import SwiftUI

/// A simple in-memory text target that captures pipeline output
/// for the interactive preview.
@MainActor
@Observable
private final class PreviewTextTarget: TextInputTarget {
    var text: String = ""
    var documentContextBeforeInput: String? {
        text
    }

    var documentContextAfterInput: String? {
        nil
    }

    var selectedText: String? {
        nil
    }

    var hasFullAccess: Bool {
        false
    }

    func deleteBackward() {
        if !text.isEmpty {
            text.removeLast()
        }
    }

    func insertText(_ text: String) {
        self.text += text
    }

    func adjustTextPosition(byCharacterOffset _: Int) {}
}

struct InteractiveKeyboardPreview: View {
    @Binding var aspectRatio: Double
    /// Keyboard width wish in points (mirrors the persisted setting).
    @Binding var width: Double
    @Binding var position: Double
    /// Gap between keys in points (mirrors `SettingsKey.keySpacing`).
    @Binding var keySpacing: Double
    /// A `NumpadColumnPlacement` raw value (mirrors `SettingsKey.numpadColumn`).
    @Binding var numpadColumn: String
    /// Mirrors `SettingsKey.isSplitLayoutEnabled`.
    @Binding var isSplit: Bool

    @State private var previewViewModel = KeyboardViewModel(shouldPersistSettings: false)
    @State private var previewTarget = PreviewTextTarget()

    init(
        aspectRatio: Binding<Double> = .constant(1.0),
        width: Binding<Double> = .constant(DeviceLayout.defaultKeyboardWidth),
        position: Binding<Double> = .constant(0.5),
        keySpacing: Binding<Double> = .constant(Double(KeyboardConstants.Layout.defaultKeySpacing)),
        numpadColumn: Binding<String> = .constant(NumpadColumnPlacement.off.rawValue),
        isSplit: Binding<Bool> = .constant(false)
    ) {
        _aspectRatio = aspectRatio
        _width = width
        _position = position
        _keySpacing = keySpacing
        _numpadColumn = numpadColumn
        _isSplit = isSplit
    }

    private var previewHeight: CGFloat {
        // Same metrics the keyboard itself renders from, resolved against
        // the preview's container (the parents inset it 16 pt per side), so
        // the frame height always matches the rendered content height.
        let containerWidth = DeviceLayout.screenBounds.width - 32
        let metrics = previewViewModel.layoutMetrics(forContainerWidth: containerWidth)
        return KeyboardConstants.Preview.frameHeight(forContentHeight: metrics.totalHeight)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Preview")
                    .font(.headline)
                Spacer()
                if !previewTarget.text.isEmpty {
                    Button("Clear") {
                        previewTarget.text = ""
                    }
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !previewTarget.text.isEmpty {
                Text(previewTarget.text)
                    .font(.title2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
            } else {
                Text("Type on the keyboard below")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
            }

            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    Color(.systemGray6)

                    // The proxy width makes the preview lay out against its
                    // real container instead of the full screen width, so the
                    // fit-clamp and horizontal position match the extension.
                    DataDrivenKeyboardRootView(viewModel: previewViewModel, overrideWidth: proxy.size.width)
                        .onChange(of: aspectRatio) { _, newValue in
                            previewViewModel.keyAspectRatio = newValue
                        }
                        .onChange(of: width) { _, newValue in
                            previewViewModel.keyboardWidth = newValue
                        }
                        .onChange(of: position) { _, newValue in
                            previewViewModel.keyboardHorizontalPosition = newValue
                        }
                        .onChange(of: keySpacing) { _, newValue in
                            previewViewModel.keySpacing = newValue
                        }
                        .onChange(of: numpadColumn) { _, newValue in
                            // The column's keys belong to the definition, so
                            // the preview reloads it like the keyboard does.
                            previewViewModel.numpadColumn = NumpadColumnPlacement(rawValue: newValue) ?? .off
                            previewViewModel.reloadDefinitionIfNumpadColumnChanged()
                        }
                        .onChange(of: isSplit) { _, newValue in
                            previewViewModel.isSplitLayoutEnabled = newValue
                        }
                        .onAppear {
                            previewViewModel.keyAspectRatio = aspectRatio
                            previewViewModel.keyboardWidth = width
                            previewViewModel.keyboardHorizontalPosition = position
                            previewViewModel.keySpacing = keySpacing
                            previewViewModel.numpadColumn = NumpadColumnPlacement(rawValue: numpadColumn) ?? .off
                            previewViewModel.isSplitLayoutEnabled = isSplit

                            // Wire up preview text target and load definition
                            previewViewModel.bindTextInputTarget(previewTarget)
                            let languageId = SharedDefaults.store.string(
                                forKey: SettingsKey.selectedLanguageId.rawValue
                            ) ?? LanguageSettings.detectSystemLanguage()
                            previewViewModel.loadDefinition(for: languageId)
                        }
                }
            }
            .frame(height: previewHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            // The keys move by the keyboard's own layout motion (the root
            // view's `LayoutMotion`); the frame follows them the way the
            // keyboard's frame follows a resize, so a slider drag tracks the
            // thumb without the frame lagging the keys.
            .animation(LayoutMotion.follow.animation, value: previewHeight)
        }
    }
}

#if !WURSTFINGER_NO_PREVIEWS
#Preview {
    InteractiveKeyboardPreview()
        .padding()
}
#endif
