//
//  CustomLayoutEditorView.swift
//  Wurstfinger
//
//  The visual editor for a custom layout: the 3x3 grid, and a sheet per key.
//

import SwiftUI

// MARK: - Editor

/// Edits one custom layout. Changes stay in a local draft until "Save", which
/// writes the layout through `CustomLayoutLibrary` (and so to the keyboard).
struct CustomLayoutEditorView: View {
    private let library = CustomLayoutLibrary.shared

    @State private var draft: CustomLayout
    @State private var editedSlot: SlotSelection?
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    init(layout: CustomLayout) {
        _draft = State(initialValue: layout)
    }

    private var saved: CustomLayout? { library.layout(withId: draft.id) }
    private var problem: CustomLayoutError? { draft.validate().first }
    private var canSave: Bool { problem == nil && draft != saved }

    var body: some View {
        CustomLayoutEditorContent(layout: $draft, problem: problem, onSelect: { editedSlot = SlotSelection(slot: $0) })
            .navigationTitle(draft.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                }
            }
            .sheet(item: $editedSlot) { selection in
                NavigationStack {
                    CustomKeyEditorView(layout: $draft, slot: selection.slot)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { editedSlot = nil }
                            }
                        }
                }
                #if os(macOS)
                .frame(minWidth: 380, minHeight: 560)
                #endif
            }
            .alert("Layout Not Accepted", isPresented: Binding(
                get: { failure != nil }, set: { if !$0 { failure = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
    }

    private func save() {
        do {
            try library.save(draft)
            dismiss()
        } catch let error as CustomLayoutError {
            failure = error.userMessage
        } catch {
            failure = CustomLayoutError.storageFailure.userMessage
        }
    }
}

/// A slot picked for editing; `Identifiable` for `.sheet(item:)`.
struct SlotSelection: Identifiable, Equatable {
    let slot: String
    var id: String { slot }
}

/// The editor's form, free of navigation and storage so it renders on its own
/// (the snapshot tool draws it).
struct CustomLayoutEditorContent: View {
    @Binding var layout: CustomLayout
    var problem: CustomLayoutError?
    var onSelect: (String) -> Void = { _ in }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $layout.title)
                TextField("Language Code", text: $layout.localeIdentifier)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } footer: {
                Text("A language code such as en or tr_TR decides how letters are capitalized.")
            }

            Section {
                Toggle("Capital Letters", isOn: $layout.supportsCapitalization)
                Toggle("Shared Symbols", isOn: $layout.usesSharedSymbols)
            } footer: {
                Text("Shared symbols add the standard punctuation to the keys. Turn them off for a clean layout like Thumb-Key.")
            }

            Section {
                CustomLayoutGrid(layout: layout, onSelect: onSelect)
                    .padding(.vertical, 6)
            } header: {
                Text("Keys")
            } footer: {
                Text("Tap a key to change what each swipe types.")
            }

            if let problem {
                Section {
                    Label(problem.userMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.callout)
                }
            }
        }
    }
}

// MARK: - The grid

/// The nine keys, each drawn like the real thing: its tap character large, the
/// eight swipe outputs around it.
struct CustomLayoutGrid: View {
    let layout: CustomLayout
    var onSelect: (String) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(GridSlot.allSlots, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { slot in
                        Button { onSelect(slot) } label: {
                            CustomKeyTile(layout: layout, slot: slot)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Key \(layout.tapText(of: slot))")
                    }
                }
            }
        }
    }
}

/// One key of the grid.
struct CustomKeyTile: View {
    let layout: CustomLayout
    let slot: String

    /// The eight swipes at their compass positions, row by row, the centre left out.
    private static let ring: [[GestureType?]] = [
        [.swipeUpLeft, .swipeUp, .swipeUpRight],
        [.swipeLeft, nil, .swipeRight],
        [.swipeDownLeft, .swipeDown, .swipeDownRight],
    ]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.14))
            VStack(spacing: 0) {
                ForEach(0 ..< 3, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0 ..< 3, id: \.self) { column in
                            cell(Self.ring[row][column])
                        }
                    }
                }
            }
            .padding(4)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func cell(_ gesture: GestureType?) -> some View {
        Group {
            if let gesture {
                let state = layout.state(slot: slot, gesture: gesture)
                Text(layout.displayedText(slot: slot, gesture: gesture))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(isCustom(state) ? .accentColor : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            } else {
                Text(layout.tapText(of: slot))
                    .font(.system(size: 26, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func isCustom(_ state: CustomBindingState) -> Bool {
        if case .custom = state { return true }
        return false
    }
}

// MARK: - One key

/// The sheet for one key: its nine positions on a grid of text fields, then the
/// circle and long-press outputs.
struct CustomKeyEditorView: View {
    @Binding var layout: CustomLayout
    let slot: String

    /// The compass layout of the fields; the tap sits in the middle.
    private static let rows: [[GestureType]] = [
        [.swipeUpLeft, .swipeUp, .swipeUpRight],
        [.swipeLeft, .tap, .swipeRight],
        [.swipeDownLeft, .swipeDown, .swipeDownRight],
    ]

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    ForEach(Self.rows, id: \.self) { row in
                        HStack(spacing: 8) {
                            ForEach(row, id: \.self) { gesture in
                                GestureField(layout: $layout, slot: slot, gesture: gesture)
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            } footer: {
                Text("Hold a field to remove a standard symbol or bring it back.")
            }

            Section {
                labeledField("Clockwise Circle", gesture: .circularClockwise)
                labeledField("Counter-clockwise Circle", gesture: .circularCounterclockwise)
                labeledField("Long Press", gesture: .longPress)
            } footer: {
                Text("A long press types its text when “Long Press” is on.")
            }
        }
        .navigationTitle("Edit Key")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func labeledField(_ title: LocalizedStringKey, gesture: GestureType) -> some View {
        HStack {
            Text(title)
            Spacer()
            GestureField(layout: $layout, slot: slot, gesture: gesture)
                .frame(width: 96)
        }
    }
}

/// A text field for one gesture of one key.
///
/// Its placeholder shows what the gesture does when the layout says nothing:
/// the standard symbol it inherits, or "∅" when the layout removed it on
/// purpose. The context menu (long press, right click) removes or restores.
struct GestureField: View {
    @Binding var layout: CustomLayout
    let slot: String
    let gesture: GestureType

    var body: some View {
        let state = layout.state(slot: slot, gesture: gesture)
        TextField(placeholder(for: state), text: text)
            .multilineTextAlignment(.center)
            .textFieldStyle(.roundedBorder)
            .font(.title3)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .accessibilityLabel(Self.name(of: gesture))
            .contextMenu {
                if gesture != .tap {
                    switch state {
                    case let .inherited(label):
                        if label != nil {
                            Button("Remove Symbol") { layout.removeBinding(slot: slot, gesture: gesture) }
                        }
                    case .custom, .removed:
                        Button("Restore Default") { layout.restoreBinding(slot: slot, gesture: gesture) }
                    }
                }
            }
    }

    private var text: Binding<String> {
        Binding(
            get: {
                if case let .custom(text) = layout.state(slot: slot, gesture: gesture) { return text }
                return ""
            },
            set: { layout.setText($0, slot: slot, gesture: gesture) }
        )
    }

    private func placeholder(for state: CustomBindingState) -> String {
        switch state {
        case let .inherited(label): label ?? ""
        case .removed: "∅"
        case .custom: ""
        }
    }

    /// The VoiceOver name of a position.
    static func name(of gesture: GestureType) -> String {
        switch gesture {
        case .tap: String(localized: "Tap")
        case .swipeUp: String(localized: "Up")
        case .swipeDown: String(localized: "Down")
        case .swipeLeft: String(localized: "Left")
        case .swipeRight: String(localized: "Right")
        case .swipeUpLeft: String(localized: "Up Left")
        case .swipeUpRight: String(localized: "Up Right")
        case .swipeDownLeft: String(localized: "Down Left")
        case .swipeDownRight: String(localized: "Down Right")
        case .circularClockwise: String(localized: "Clockwise Circle")
        case .circularCounterclockwise: String(localized: "Counter-clockwise Circle")
        case .longPress: String(localized: "Long Press")
        }
    }
}

#if !WURSTFINGER_NO_PREVIEWS
#Preview {
    NavigationStack {
        CustomLayoutEditorView(
            layout: CustomLayout(
                duplicating: LanguageDefinitions.thumbKeyEnglish.makeDefinition(),
                id: "custom-preview", title: "Preview"
            )
        )
    }
}
#endif
