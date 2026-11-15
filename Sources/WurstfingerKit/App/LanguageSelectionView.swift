//
//  LanguageSelectionView.swift
//  Wurstfinger
//
//  Created by Claas Flint on 06.11.25.
//

import SwiftUI

struct LanguageSelectionView: View {
    /// `@Observable` and shared: reading it in `body` subscribes this view to
    /// the properties it uses; `let` is enough because nothing here binds to it.
    private let languageSettings = LanguageSettings.shared
    /// Observed so a layout added or removed on the Custom Layouts screen shows here.
    private let library = CustomLayoutLibrary.shared
    @State private var showLastLanguageAlert = false

    var body: some View {
        List {
            Section {
                // One row per language; its optimized arrangements are a menu
                // inside the row, not rows of their own.
                ForEach(library.allLanguages.filter { $0.variantOf == nil }) { language in
                    let layouts = LanguageRow.layouts(of: language, in: library.allLanguages)
                    // The arrangement of this language that is switched on, if any.
                    let active = layouts.first { languageSettings.isLanguageEnabled($0) }
                    LanguageRow(
                        language: language,
                        layouts: layouts,
                        active: active ?? language,
                        isEnabled: active != nil,
                        isDefault: layouts.contains { languageSettings.pinnedLanguageId == $0.id },
                        onTap: {
                            if let active {
                                languageSettings.pinLanguage(active)
                            } else {
                                // Turning a language on starts it on its optimized layout, when it has one.
                                let starting = LanguageSettings.startingLayout(for: language)
                                languageSettings.toggleLanguage(starting)
                                languageSettings.pinLanguage(starting)
                            }
                        },
                        onToggle: {
                            if !languageSettings.toggleLanguage(active ?? LanguageSettings.startingLayout(for: language)) {
                                showLastLanguageAlert = true
                            }
                        },
                        onChooseLayout: { layout in
                            if let active {
                                languageSettings.switchLayout(from: active.id, to: layout.id)
                            }
                        }
                    )
                }
            } footer: {
                if languageSettings.hasMultipleLanguages {
                    Text("Swipe right on the globe key to switch languages. Tap a language to set it as the default startup language.")
                }
            }
            Section {
            } footer: {
                Text("Optimized layouts move a few letters to where your language's own text says they cost least to type; fully optimized ones place every letter. Your layout never changes unless you choose one here.")
            }
        }
        .navigationTitle("Languages")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Cannot Disable", isPresented: $showLastLanguageAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("At least one language must be enabled.")
        }
    }
}

private struct LanguageRow: View {
    let language: LanguageMetadata
    /// The standard layout and its optimized arrangements, in that order.
    let layouts: [LanguageMetadata]
    /// The arrangement in use (the standard one while the language is off).
    let active: LanguageMetadata
    let isEnabled: Bool
    let isDefault: Bool
    let onTap: () -> Void
    let onToggle: () -> Void
    let onChooseLayout: (LanguageMetadata) -> Void

    /// Says which arrangement is in use: "MessagEase Layout", or "Optimized for German".
    private var subtitle: String {
        let name = language.locale.language.languageCode.flatMap { Locale.current.localizedString(forLanguageCode: $0.identifier) }
            ?? language.title
        switch active.variant {
        case .standard: return active.family.subtitle
        case .optimized: return String(localized: "Optimized for \(name)")
        case .full: return String(localized: "Fully optimized for \(name)")
        }
    }

    /// `language` first, then its variants from least to most moved.
    static func layouts(of language: LanguageMetadata, in all: [LanguageMetadata]) -> [LanguageMetadata] {
        let variants = all.filter { $0.variantOf == language.id }
            .sorted { LayoutVariant.allCases.firstIndex(of: $0.variant)! < LayoutVariant.allCases.firstIndex(of: $1.variant)! }
        return [language] + variants
    }

    var body: some View {
        HStack {
            Button(action: onToggle) {
                Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isEnabled ? .accentColor : .secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isEnabled
                    ? String(localized: "Disable \(language.title)")
                    : String(localized: "Enable \(language.title)")
            )
            .accessibilityValue(isEnabled ? String(localized: "Enabled") : String(localized: "Disabled"))

            VStack(alignment: .leading, spacing: 4) {
                Text(language.title)
                    .font(.body)
                    .foregroundColor(.primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // The layout menu is for a language that is on; an off row stays plain.
            if isEnabled, layouts.count > 1 {
                Menu {
                    ForEach(layouts) { layout in
                        Button {
                            onChooseLayout(layout)
                        } label: {
                            if layout.id == active.id {
                                Label(layout.variant.displayName, systemImage: "checkmark")
                            } else {
                                Text(layout.variant.displayName)
                            }
                        }
                    }
                } label: {
                    Text(active.variant.displayName)
                        .font(.caption)
                }
                .accessibilityLabel(String(localized: "Layout"))
                .accessibilityValue(active.variant.displayName)
            }

            if isDefault {
                Text("Default")
                    .font(.caption)
                    .foregroundColor(.accentColor)
                    .fontWeight(.medium)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

extension LayoutVariant {
    /// What the layout menu of a language calls this arrangement.
    var displayName: String {
        switch self {
        case .standard: String(localized: "Standard")
        case .optimized: String(localized: "Optimized")
        case .full: String(localized: "Fully optimized")
        }
    }
}

#if !WURSTFINGER_NO_PREVIEWS
#Preview {
    NavigationStack {
        LanguageSelectionView()
    }
}
#endif
