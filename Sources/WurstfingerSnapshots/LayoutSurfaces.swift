//
//  LayoutSurfaces.swift
//  WurstfingerSnapshots
//
//  The Thumb-Key and custom-layout screens: the list, the visual editor, the
//  sheet for one key, and a custom layout on the keyboard.
//

import SwiftUI
@testable import WurstfingerKit

@MainActor
enum LayoutSurfaces {
    /// The layout the screens are drawn with: Thumb-Key's arrangement, in
    /// German, with the umlauts and ß swiped onto free positions.
    static func sampleLayout() -> CustomLayout {
        var layout = CustomLayout(
            duplicating: LanguageDefinitions.thumbKeyEnglish.makeDefinition(),
            id: "custom-thumbkey-deutsch", title: "Thumb-Key Deutsch"
        )
        layout.localeIdentifier = "de_DE"
        layout.setText("ä", slot: GridSlot.topLeft, gesture: .swipeUp)
        layout.setText("ü", slot: GridSlot.topCenter, gesture: .swipeUp)
        layout.setText("ö", slot: GridSlot.topRight, gesture: .swipeUp)
        layout.setText("ß", slot: GridSlot.bottomLeft, gesture: .swipeDown)
        return layout
    }

    /// A second layout, so the list has more than one row.
    static func secondLayout() -> CustomLayout {
        var layout = CustomLayout(
            duplicating: LanguageDefinitions.german.makeDefinition(),
            id: "custom-mein-deutsch", title: "Mein Deutsch"
        )
        layout.setText("€", slot: GridSlot.bottomRight, gesture: .swipeUp)
        return layout
    }

    /// Puts `layouts` into the library and the registry, enabling the first, as
    /// if the user had made them.
    static func install(_ layouts: [CustomLayout], enabling: Bool = true) {
        let library = CustomLayoutLibrary.shared
        for layout in layouts {
            do {
                try library.save(layout)
            } catch {
                preconditionFailure("sample layout refused: \(error)")
            }
        }
        if enabling, let first = layouts.first {
            LanguageSettings.shared.toggleLanguage(first.metadata)
        }
    }

    private static func screen(_ view: some View, scheme: ColorScheme) -> Shot {
        let device = Device.iPhone15
        device.activate()
        return Shot(
            size: device.size, scheme: scheme,
            content: AnyView(view.formStyle(.grouped).frame(width: device.width, height: device.size.height)),
            hosted: true
        )
    }

    static func list(scheme: ColorScheme) -> Shot {
        ScenarioEnvironment.reset()
        install([sampleLayout(), secondLayout()])
        return screen(NavigationStack { CustomLayoutsView() }, scheme: scheme)
    }

    static func editor(scheme: ColorScheme) -> Shot {
        ScenarioEnvironment.reset()
        let layout = sampleLayout()
        install([layout])
        return screen(NavigationStack { CustomLayoutEditorView(layout: layout) }, scheme: scheme)
    }

    /// The editor with a layout that cannot be saved yet.
    static func editorWithProblem(scheme: ColorScheme) -> Shot {
        ScenarioEnvironment.reset()
        var layout = sampleLayout()
        install([layout])
        layout.keys[GridSlot.center]?[.tap] = CustomBinding("")
        return screen(NavigationStack { CustomLayoutEditorView(layout: layout) }, scheme: scheme)
    }

    static func keySheet(scheme: ColorScheme) -> Shot {
        ScenarioEnvironment.reset()
        return screen(KeySheetHost(layout: sampleLayout(), slot: GridSlot.center), scheme: scheme)
    }

    static func languages(scheme: ColorScheme) -> Shot {
        ScenarioEnvironment.reset()
        install([sampleLayout(), secondLayout()])
        return screen(NavigationStack { LanguageSelectionView() }, scheme: scheme)
    }
}

/// Holds the layout the key sheet edits, as the editor does.
private struct KeySheetHost: View {
    @State var layout: CustomLayout
    let slot: String

    var body: some View {
        NavigationStack {
            CustomKeyEditorView(layout: $layout, slot: slot)
        }
    }
}
