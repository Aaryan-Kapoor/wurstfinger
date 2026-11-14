//
//  CustomLayoutStore.swift
//  Wurstfinger
//
//  Where the user's custom layouts live on disk.
//

import Foundation

/// A directory of custom-layout files, one `<id>.json` per layout.
///
/// In the app group container, so the keyboard extension reads what the host
/// app writes. Plain files rather than `UserDefaults` values: the extension's
/// defaults plist is loaded whole at launch, and a layout file is read only
/// when the registry loads it.
///
/// A `Sendable` value type with no state: every call goes to the file system,
/// so any isolation can use it, and tests point it at a temporary directory.
struct CustomLayoutStore: Sendable {
    /// Most layouts the store holds. Bounds what the keyboard extension reads
    /// at launch and what the list screen shows.
    static let maxLayouts = 16

    /// Most files one read opens. The files that count are the first
    /// `maxLayouts` that validate, so a few broken ones may precede them; past
    /// this many (by file name) the rest are rejected unread. Bounds what a
    /// directory full of junk can cost the keyboard extension at launch, where
    /// each file is read and validated (a validation builds a whole keyboard).
    static let maxFilesRead = 4 * maxLayouts

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// What a read found: the layouts that passed validation, and the files
    /// that did not (kept on disk, never shown to the keyboard).
    struct Contents: Sendable, Equatable {
        var layouts: [CustomLayout] = []
        var rejected: [String: CustomLayoutError] = [:]
    }

    /// The production store: the app group container's `CustomLayouts`
    /// directory; the app's Application Support directory where the app group
    /// is unavailable (an unsigned Mac build); a throwaway temporary directory
    /// under the unit-test runner and for the UI tests' isolated launch, so
    /// neither can reach the user's real layouts.
    static var shared: CustomLayoutStore {
        sharedStore
    }

    private static let sharedStore: CustomLayoutStore = {
        let fileManager = FileManager.default
        if UnitTestHost.isActive || ProcessInfo.processInfo.arguments.contains(SharedDefaults.isolatedStoreArgument) {
            let process = ProcessInfo.processInfo.processIdentifier
            return CustomLayoutStore(
                directory: fileManager.temporaryDirectory
                    .appendingPathComponent("wurstfinger-custom-layouts-\(process)", isDirectory: true)
            )
        }
        let base = fileManager.containerURL(forSecurityApplicationGroupIdentifier: SharedDefaults.suiteName)
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return CustomLayoutStore(directory: base.appendingPathComponent("CustomLayouts", isDirectory: true))
    }()

    // MARK: - Reading

    /// Reads every layout in the directory.
    ///
    /// A file is accepted only if it is within the size cap, decodes and
    /// validates, and its file name is its id; extra files beyond `maxLayouts`
    /// (by file name) are rejected, and so is every file after the first
    /// `maxFilesRead` unread. Never throws: an unreadable directory is an
    /// empty store, and a bad file is reported in `rejected`, so one corrupt
    /// layout cannot take the others — or the keyboard — down with it.
    func load() -> Contents {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return Contents() }

        var contents = Contents()
        var filesRead = 0
        for url in entries.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.deletingPathExtension().lastPathComponent
            guard filesRead < Self.maxFilesRead else {
                contents.rejected[name] = .tooManyLayouts(limit: Self.maxLayouts)
                continue
            }
            filesRead += 1
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > CustomLayoutCodec.maxDocumentBytes {
                contents.rejected[name] = .tooLarge(bytes: size)
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                contents.rejected[name] = .storageFailure
                continue
            }
            do {
                let layout = try CustomLayoutCodec.decode(data)
                guard layout.id == name else {
                    contents.rejected[name] = .invalidId(layout.id)
                    continue
                }
                guard contents.layouts.count < Self.maxLayouts else {
                    contents.rejected[name] = .tooManyLayouts(limit: Self.maxLayouts)
                    continue
                }
                contents.layouts.append(layout)
            } catch let error as CustomLayoutError {
                contents.rejected[name] = error
            } catch {
                contents.rejected[name] = .notALayout
            }
        }
        contents.layouts.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return contents
    }

    // MARK: - Writing

    /// Writes `layout` (replacing the file of the same id).
    /// - Throws: the layout's own validation error, `tooManyLayouts` for a new
    ///   id past the limit, or `storageFailure`.
    func save(_ layout: CustomLayout) throws {
        if let problem = layout.validate().first { throw problem }
        // Counted by file name: decoding every stored layout just to count them
        // would validate each one again.
        let existing = storedIDs()
        if !existing.contains(layout.id), existing.count >= Self.maxLayouts {
            throw CustomLayoutError.tooManyLayouts(limit: Self.maxLayouts)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try CustomLayoutCodec.encode(layout).write(to: fileURL(for: layout.id), options: .atomic)
        } catch {
            throw CustomLayoutError.storageFailure
        }
    }

    /// Adds a layout that must not exist yet — the import path.
    /// - Throws: `duplicateId` if the id is taken, otherwise as `save`.
    func add(_ layout: CustomLayout) throws {
        if let problem = layout.validate().first { throw problem }
        guard !FileManager.default.fileExists(atPath: fileURL(for: layout.id).path) else {
            throw CustomLayoutError.duplicateId(layout.id)
        }
        try save(layout)
    }

    /// Removes the layout with `id`; a missing file is not an error.
    func delete(id: String) throws {
        guard CustomLayout.isValidID(id) else { throw CustomLayoutError.invalidId(id) }
        do {
            try FileManager.default.removeItem(at: fileURL(for: id))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            throw CustomLayoutError.storageFailure
        }
    }

    /// The ids of the layout files in the directory, readable or not.
    private func storedIDs() -> Set<String> {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(entries.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.map { String($0.dropLast(5)) })
    }

    private func fileURL(for id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension("json")
    }
}
