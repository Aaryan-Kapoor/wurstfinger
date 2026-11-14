//
//  CustomLayoutsView.swift
//  Wurstfinger
//
//  The "Custom Layouts" screen: the user's layouts, and the ways to get a new
//  one — duplicate an existing layout, import a file, paste JSON.
//

import SwiftUI
import UniformTypeIdentifiers

struct CustomLayoutsView: View {
    private let library = CustomLayoutLibrary.shared
    private let languageSettings = LanguageSettings.shared

    @State private var editingId: String?
    @State private var isChoosingBase = false
    @State private var isImporting = false
    @State private var exported: CustomLayoutFile?
    @State private var pendingDeletion: CustomLayout?
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                ForEach(library.layouts) { layout in
                    NavigationLink(destination: CustomLayoutEditorView(layout: layout)) {
                        CustomLayoutRow(layout: layout, isEnabled: languageSettings.isLanguageEnabled(layout.metadata))
                    }
                    .contextMenu { rowMenu(for: layout) }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) { pendingDeletion = layout }
                    }
                }
            } footer: {
                Text("Start from an existing layout and change any key, or import a layout file. Turn a custom layout on under Languages.")
                if library.unreadableCount > 0 {
                    Text("Some layout files could not be read and were skipped.")
                }
            }

            Section {
                Button { isChoosingBase = true } label: {
                    Label("Start from Existing Layout…", systemImage: "plus.square.on.square")
                }
                Button { isImporting = true } label: {
                    Label("Import from File…", systemImage: "square.and.arrow.down")
                }
                Button(action: pasteFromClipboard) {
                    Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                }
            }
        }
        .navigationTitle("Custom Layouts")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $editingId) { id in
            if let layout = library.layout(withId: id) {
                CustomLayoutEditorView(layout: layout)
            }
        }
        .sheet(isPresented: $isChoosingBase) {
            NavigationStack {
                BaseLayoutPicker { choice in
                    isChoosingBase = false
                    startFrom(choice)
                }
            }
            #if os(macOS)
            .frame(minWidth: 360, minHeight: 480)
            #endif
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            importFile(result)
        }
        .fileExporter(
            isPresented: Binding(get: { exported != nil }, set: { if !$0 { exported = nil } }),
            document: exported ?? CustomLayoutFile(name: "", data: Data()),
            contentType: .json,
            defaultFilename: exported?.name
        ) { _ in }
        .confirmationDialog("Delete Layout?", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { layout in
            Button("Delete", role: .destructive) { delete(layout) }
        } message: { _ in
            Text("This cannot be undone.")
        }
        .alert("Layout Not Accepted", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    @ViewBuilder
    private func rowMenu(for layout: CustomLayout) -> some View {
        Button { startFrom(layout.id) } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        if let file = try? CustomLayoutFile(layout: layout) {
            ShareLink(item: file, preview: SharePreview(layout.title)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Button { exported = file } label: {
                Label("Save as File…", systemImage: "folder")
            }
        }
        Button(role: .destructive) { pendingDeletion = layout } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Actions

    private func startFrom(_ languageId: String) {
        let base = library.allLanguages.first { $0.id == languageId }?.title ?? ""
        do {
            let copy = try library.duplicate(languageId: languageId, title: String(localized: "\(base) Copy"))
            editingId = copy.id
        } catch {
            fail(error)
        }
    }

    private func delete(_ layout: CustomLayout) {
        do {
            try library.delete(id: layout.id)
        } catch {
            fail(error)
        }
    }

    private func pasteFromClipboard() {
        guard let text = ClipboardStore.shared.string else {
            return fail(CustomLayoutError.notALayout)
        }
        do {
            try library.importDocument(Data(text.utf8))
        } catch {
            fail(error)
        }
    }

    private func importFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            // Outside the sandbox the picked file is only readable inside a
            // security scope (a no-op where none applies).
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // Refuse an oversized file from its size, without reading it.
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > CustomLayoutCodec.maxDocumentBytes {
                throw CustomLayoutError.tooLarge(bytes: size)
            }
            guard let data = try? Data(contentsOf: url) else { throw CustomLayoutError.storageFailure }
            try library.importDocument(data)
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        failure = (error as? CustomLayoutError ?? .storageFailure).userMessage
    }
}

// MARK: - Row

private struct CustomLayoutRow: View {
    let layout: CustomLayout
    let isEnabled: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(layout.title)
                    .font(.body)
                Text(layout.localeIdentifier)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if isEnabled {
                Text("Enabled")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
        }
    }
}

// MARK: - Choosing a starting point

/// Every layout there is, shipped or custom, to copy from.
private struct BaseLayoutPicker: View {
    private let library = CustomLayoutLibrary.shared
    let onChoose: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(library.allLanguages) { language in
            Button { onChoose(language.id) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(language.title)
                        .foregroundColor(.primary)
                    Text(language.family.subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Start From")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }
}

// MARK: - File

/// A layout as a `.json` file: what is shared, saved and picked.
struct CustomLayoutFile: FileDocument, Transferable, Sendable {
    static let readableContentTypes: [UTType] = [.json]

    let name: String
    let data: Data

    init(name: String, data: Data) {
        self.name = name
        self.data = data
    }

    init(layout: CustomLayout) throws {
        self.init(name: layout.title, data: try CustomLayoutCodec.encode(layout))
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CustomLayoutError.notALayout }
        self.init(name: "", data: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { file in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(file.name.isEmpty ? "layout" : file.name)
                .appendingPathExtension("json")
            try file.data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

extension LayoutFamily {
    /// The line under a layout's name in the language lists.
    var subtitle: String {
        switch self {
        case .messagEase: String(localized: "MessagEase Layout")
        case .thumbKey: String(localized: "Thumb-Key Layout")
        case .custom: String(localized: "Custom Layout")
        }
    }
}

extension CustomLayout {
    /// The layout as the language list sees it.
    var metadata: LanguageMetadata {
        LanguageMetadata(id: id, title: title, localeIdentifier: localeIdentifier, family: .custom)
    }
}

#if !WURSTFINGER_NO_PREVIEWS
#Preview {
    NavigationStack {
        CustomLayoutsView()
    }
}
#endif
