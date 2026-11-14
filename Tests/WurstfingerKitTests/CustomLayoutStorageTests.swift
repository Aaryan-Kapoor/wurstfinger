//
//  CustomLayoutStorageTests.swift
//  WurstfingerTests
//
//  Custom layouts on disk (a temporary directory per test, removed after) and
//  in the registry: loading, caching, eviction, and the revision signal that
//  carries a host-app edit into the keyboard extension.
//

import Foundation
import Testing
@testable import WurstfingerKit
@testable import WurstfingerScenarioKit

/// Parent of every suite that touches the process-wide custom-layout registry:
/// `.serialized` applies to the nested suites too, so they run one at a time.
@Suite(.serialized)
@MainActor
enum CustomLayoutSharedState {}

/// A store in a fresh temporary directory, removed when `body` returns.
func withTemporaryStore<T>(_ body: (CustomLayoutStore) throws -> T) rethrows -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("wurstfinger-store-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(CustomLayoutStore(directory: directory))
}

// MARK: - Store

struct CustomLayoutStoreTests {
    @Test func aMissingDirectoryIsAnEmptyStore() {
        withTemporaryStore { store in
            #expect(store.load() == CustomLayoutStore.Contents())
        }
    }

    @Test func savesAndLoadsLayoutsSortedByTitle() throws {
        try withTemporaryStore { store in
            try store.save(makeCustomLayout(id: "custom-b", title: "Beta"))
            try store.save(makeCustomLayout(id: "custom-a", title: "alpha"))
            try store.save(makeCustomLayout(id: "custom-c", title: "Gamma"))
            let loaded = store.load()
            #expect(loaded.layouts.map(\.title) == ["alpha", "Beta", "Gamma"])
            #expect(loaded.rejected.isEmpty)
        }
    }

    @Test func savingTheSameIdReplacesTheLayout() throws {
        try withTemporaryStore { store in
            try store.save(makeCustomLayout(title: "One"))
            try store.save(makeCustomLayout(title: "Two"))
            #expect(store.load().layouts.map(\.title) == ["Two"])
        }
    }

    @Test func addRefusesADuplicateIdButSaveDoesNot() throws {
        try withTemporaryStore { store in
            try store.add(makeCustomLayout(title: "Original"))
            #expect(throws: CustomLayoutError.duplicateId("custom-test-layout")) {
                try store.add(makeCustomLayout(title: "Imposter"))
            }
            #expect(store.load().layouts.map(\.title) == ["Original"])
        }
    }

    @Test func refusesToStoreAnInvalidLayout() {
        withTemporaryStore { store in
            #expect(throws: CustomLayoutError.invalidTitle) { try store.save(makeCustomLayout(title: "")) }
            #expect(store.load().layouts.isEmpty)
        }
    }

    @Test func deletesALayoutAndIgnoresAMissingOne() throws {
        try withTemporaryStore { store in
            try store.save(makeCustomLayout())
            try store.delete(id: "custom-test-layout")
            #expect(store.load().layouts.isEmpty)
            try store.delete(id: "custom-test-layout")
            #expect(throws: CustomLayoutError.invalidId("../x")) { try store.delete(id: "../x") }
        }
    }

    @Test func stopsAtTheLayoutLimit() throws {
        try withTemporaryStore { store in
            for index in 0 ..< CustomLayoutStore.maxLayouts {
                try store.save(makeCustomLayout(id: "custom-\(String(format: "%02d", index))", title: "L\(index)"))
            }
            #expect(throws: CustomLayoutError.tooManyLayouts(limit: CustomLayoutStore.maxLayouts)) {
                try store.save(makeCustomLayout(id: "custom-extra", title: "Extra"))
            }
            // Replacing an existing one is still allowed at the limit.
            try store.save(makeCustomLayout(id: "custom-00", title: "Renamed"))
            #expect(store.load().layouts.count == CustomLayoutStore.maxLayouts)
        }
    }

    @Test func oneCorruptFileDoesNotTakeTheOthersDown() throws {
        try withTemporaryStore { store in
            try store.save(makeCustomLayout(id: "custom-good", title: "Good"))
            let directory = store.directory
            try Data("{not json".utf8).write(to: directory.appendingPathComponent("custom-bad.json"))
            // A valid document under the wrong file name is not trusted either.
            try CustomLayoutCodec.encode(makeCustomLayout(id: "custom-other", title: "Other"))
                .write(to: directory.appendingPathComponent("custom-misnamed.json"))
            // Not a layout file at all.
            try Data("x".utf8).write(to: directory.appendingPathComponent("notes.txt"))

            let loaded = store.load()
            #expect(loaded.layouts.map(\.id) == ["custom-good"])
            #expect(loaded.rejected["custom-bad"] == .notALayout)
            #expect(loaded.rejected["custom-misnamed"] == .invalidId("custom-other"))
        }
    }

    @Test func anOversizedFileIsRejectedWithoutBeingRead() throws {
        try withTemporaryStore { store in
            try store.save(makeCustomLayout(id: "custom-good", title: "Good"))
            let huge = Data(repeating: 0x20, count: CustomLayoutCodec.maxDocumentBytes + 10)
            try huge.write(to: store.directory.appendingPathComponent("custom-huge.json"))
            let loaded = store.load()
            #expect(loaded.layouts.map(\.id) == ["custom-good"])
            #expect(loaded.rejected["custom-huge"] == .tooLarge(bytes: huge.count))
        }
    }

    @Test func aNewerSchemaOnDiskIsKeptButNotLoaded() throws {
        try withTemporaryStore { store in
            let future = String(
                decoding: try CustomLayoutCodec.encode(makeCustomLayout(id: "custom-future")), as: UTF8.self
            ).replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 7")
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            let url = store.directory.appendingPathComponent("custom-future.json")
            try Data(future.utf8).write(to: url)
            #expect(store.load().layouts.isEmpty)
            #expect(store.load().rejected["custom-future"] == .unsupportedSchema(version: 7))
            #expect(FileManager.default.fileExists(atPath: url.path), "an unreadable file must not be deleted")
        }
    }

    @Test func theTestHostsSharedStoreIsATemporaryDirectory() {
        let path = CustomLayoutStore.shared.directory.path
        #expect(path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }
}

// MARK: - Registry

/// The registry is process-wide state, so every test here uses ids no other
/// suite knows and restores the empty set before returning. It runs inside
/// `CustomLayoutSharedState`, so it never overlaps the library tests, which
/// empty the same registry.
extension CustomLayoutSharedState {
@Suite
@MainActor
struct RegistryTests {
    private func withRegistered<T>(_ layouts: [CustomLayout], _ body: () throws -> T) rethrows -> T {
        KeyboardRegistry.replaceCustomLayouts(layouts, revision: "test")
        defer { KeyboardRegistry.replaceCustomLayouts([], revision: nil) }
        return try body()
    }

    @Test func aRegisteredLayoutIsListedButNotShipped() {
        let layout = makeCustomLayout(id: "custom-reg-list", title: "Zzz Listed")
        withRegistered([layout]) {
            let listed = KeyboardRegistry.allLanguages.first { $0.id == layout.id }
            #expect(listed?.family == .custom)
            #expect(listed?.title == "Zzz Listed")
            #expect(LanguageMetadata.language(withId: layout.id)?.id == layout.id)
            #expect(KeyboardRegistry.metadata(for: layout.id)?.localeIdentifier == "en_US")
            #expect(!KeyboardRegistry.available.contains { $0.id == layout.id })
            #expect(!KeyboardRegistry.isShippedID(layout.id))
        }
        #expect(LanguageMetadata.language(withId: layout.id) == nil)
    }

    @Test func loadsAndCachesACustomLayoutLikeAShippedOne() throws {
        let layout = makeCustomLayout(id: "custom-reg-load")
        try withRegistered([layout]) {
            #expect(!KeyboardRegistry.isCached(id: layout.id))
            let first = try #require(KeyboardRegistry.load(id: layout.id))
            #expect(first.id == layout.id)
            #expect(first.validate().isEmpty)
            #expect(KeyboardRegistry.isCached(id: layout.id))
            #expect(KeyboardRegistry.load(id: layout.id) == first)
        }
        #expect(KeyboardRegistry.load(id: layout.id) == nil)
    }

    @Test func aLayoutBasedOnATelexLanguageTypesTelex() throws {
        let layout = makeCustomLayout(id: "custom-reg-telex") { $0.basedOn = "vi_VN" }
        try withRegistered([layout]) {
            let definition = try #require(KeyboardRegistry.load(id: layout.id))
            #expect(definition.settings.inputMethod == .telex)
        }
    }

    @Test func aMissingBaseFallsBackToDefaults() throws {
        let layout = makeCustomLayout(id: "custom-reg-nobase") { $0.basedOn = "xx_XX" }
        try withRegistered([layout]) {
            let definition = try #require(KeyboardRegistry.load(id: layout.id))
            #expect(definition.settings.inputMethod == .direct)
        }
    }

    @Test func editingALayoutDropsItsStaleDefinition() throws {
        let original = makeCustomLayout(id: "custom-reg-edit", title: "Before")
        try withRegistered([original]) {
            _ = KeyboardRegistry.load(id: original.id)
            #expect(KeyboardRegistry.isCached(id: original.id))

            let edited = makeCustomLayout(id: "custom-reg-edit", title: "After") {
                $0.keys[GridSlot.topLeft]?[.tap] = CustomBinding("z")
            }
            let stale = KeyboardRegistry.replaceCustomLayouts([edited], revision: "r2")
            #expect(stale == [original.id])
            #expect(!KeyboardRegistry.isCached(id: original.id))

            let reloaded = try #require(KeyboardRegistry.load(id: original.id))
            #expect(reloaded.title == "After")
            #expect(reloaded.modes[ModeNames.main]?.keys[GridSlot.topLeft]?.bindings[.tap]?.action == .commitText("z"))
        }
    }

    /// The keyboard resolves gestures through compiled tables cached beside
    /// the definition; an edit must drop those too, or the keyboard would draw
    /// the new layout and type the old one.
    @Test @MainActor func editingALayoutChangesWhatTheKeyboardTypes() {
        let original = makeCustomLayout(id: "custom-reg-typing")
        withRegistered([original]) {
            let (vm, target) = makeViewModel(languageId: original.id)
            vm.handleGesture(.tap, keyId: GridSlot.topLeft, isReturn: false)
            #expect(target.events.last == .insertText("q"))

            let edited = makeCustomLayout(id: "custom-reg-typing") {
                $0.keys[GridSlot.topLeft]?[.tap] = CustomBinding("z")
            }
            KeyboardRegistry.replaceCustomLayouts([edited], revision: "r2")
            vm.loadDefinition(for: original.id)
            vm.handleGesture(.tap, keyId: GridSlot.topLeft, isReturn: false)
            #expect(target.events.last == .insertText("z"))
        }
    }

    @Test func anUnchangedLayoutKeepsItsCachedDefinition() {
        let layout = makeCustomLayout(id: "custom-reg-keep")
        withRegistered([layout]) {
            _ = KeyboardRegistry.load(id: layout.id)
            let stale = KeyboardRegistry.replaceCustomLayouts([layout], revision: "r2")
            #expect(stale.isEmpty)
            #expect(KeyboardRegistry.isCached(id: layout.id))
        }
    }

    @Test func removingALayoutEvictsIt() {
        let layout = makeCustomLayout(id: "custom-reg-remove")
        withRegistered([layout]) {
            _ = KeyboardRegistry.load(id: layout.id)
            let stale = KeyboardRegistry.replaceCustomLayouts([], revision: "r2")
            #expect(stale == [layout.id])
            #expect(!KeyboardRegistry.isCached(id: layout.id))
            #expect(KeyboardRegistry.load(id: layout.id) == nil)
        }
    }

    @Test func prewarmBuildsACustomLayoutOffTheCallingThread() async {
        let layout = makeCustomLayout(id: "custom-reg-prewarm")
        KeyboardRegistry.replaceCustomLayouts([layout], revision: "test")
        defer { KeyboardRegistry.replaceCustomLayouts([], revision: nil) }
        await KeyboardRegistry.prewarm([layout.id, "unknown-id"])
        #expect(KeyboardRegistry.isCached(id: layout.id))
    }

    @Test func aShippedLayoutIsNeverShadowedByACustomOne() throws {
        // A custom layout can't carry a shipped id (validation), but even a
        // registry fed one directly must resolve the shipped definition.
        let shadow = makeCustomLayout(id: "en_US", title: "Not English")
        KeyboardRegistry.replaceCustomLayouts([shadow], revision: "test")
        defer { KeyboardRegistry.replaceCustomLayouts([], revision: nil) }
        let english = try #require(KeyboardRegistry.load(id: "en_US"))
        #expect(english.title == "English")
    }

    // MARK: Revision signal

    @Test func aStoreWithoutARevisionIsLeftAlone() throws {
        try withTemporaryStore { store in
            try store.save(makeCustomLayout())
            let registry = CustomLayoutRegistry()
            #expect(registry.sync(defaults: InMemoryUserDefaults(), store: store).isEmpty)
            #expect(registry.languages.isEmpty)
        }
    }

    @Test func aNewRevisionReloadsTheStoreOnceAndOnlyOnce() throws {
        try withTemporaryStore { store in
            let defaults = InMemoryUserDefaults()
            let registry = CustomLayoutRegistry()
            try store.save(makeCustomLayout(id: "custom-sync", title: "First"))
            defaults.set("r1", forKey: SettingsKey.customLayoutsRevision.rawValue)

            #expect(registry.sync(defaults: defaults, store: store).isEmpty) // new layout: nothing stale
            #expect(registry.languages.map(\.title) == ["First"])

            // The files change without a new revision: the registry does not look.
            try store.save(makeCustomLayout(id: "custom-sync", title: "Second"))
            #expect(registry.sync(defaults: defaults, store: store).isEmpty)
            #expect(registry.languages.map(\.title) == ["First"])

            // The host app bumps the revision: now it does, and reports the stale id.
            defaults.set("r2", forKey: SettingsKey.customLayoutsRevision.rawValue)
            #expect(registry.sync(defaults: defaults, store: store) == ["custom-sync"])
            #expect(registry.languages.map(\.title) == ["Second"])
        }
    }

    @Test func aDeletedLayoutDisappearsOnTheNextRevision() throws {
        try withTemporaryStore { store in
            let defaults = InMemoryUserDefaults()
            let registry = CustomLayoutRegistry()
            try store.save(makeCustomLayout(id: "custom-sync-del"))
            defaults.set("r1", forKey: SettingsKey.customLayoutsRevision.rawValue)
            registry.sync(defaults: defaults, store: store)
            try store.delete(id: "custom-sync-del")
            defaults.set("r2", forKey: SettingsKey.customLayoutsRevision.rawValue)
            #expect(registry.sync(defaults: defaults, store: store) == ["custom-sync-del"])
            #expect(registry.layout(withId: "custom-sync-del") == nil)
        }
    }

    // MARK: Language settings and the view model

    @Test func anEnabledCustomLayoutSurvivesNormalizationAndGoesWhenRemoved() throws {
        let layout = makeCustomLayout(id: "custom-reg-settings")
        let defaults = InMemoryUserDefaults()
        defaults.set(["en_US", layout.id], forKey: SettingsKey.enabledLanguageIds.rawValue)
        defaults.set(layout.id, forKey: SettingsKey.selectedLanguageId.rawValue)
        KeyboardRegistry.replaceCustomLayouts([layout], revision: "test")
        defer { KeyboardRegistry.replaceCustomLayouts([], revision: nil) }

        let settings = LanguageSettings(userDefaults: defaults)
        #expect(settings.enabledLanguageIds == ["en_US", layout.id])
        #expect(settings.selectedLanguageId == layout.id)
        #expect(settings.enabledLanguages.last?.family == .custom)

        KeyboardRegistry.replaceCustomLayouts([], revision: "test2")
        settings.reloadFromStore()
        #expect(settings.enabledLanguageIds == ["en_US"])
        #expect(settings.selectedLanguageId == "en_US")
    }

    @Test func theViewModelLoadsAndTypesOnACustomLayout() throws {
        let layout = makeCustomLayout(id: "custom-reg-typing") {
            $0.keys[GridSlot.center]?[.swipeUp] = CustomBinding("ü")
        }
        KeyboardRegistry.replaceCustomLayouts([layout], revision: "test")
        defer { KeyboardRegistry.replaceCustomLayouts([], revision: nil) }

        let scenario = KeyboardScenario(language: layout.id, autoCapitalize: false)
        #expect(scenario.viewModel.currentDefinition?.id == layout.id)
        // q w e / r t y / u i o on the grid, ü above the centre key.
        scenario.tap(GridSlot.topLeft)
        scenario.swipe(GridSlot.center, .swipeUp)
        scenario.tap(GridSlot.bottomRight)
        #expect(scenario.text == "qüo")
        #expect(scenario.type("wet").isEmpty)
        #expect(scenario.text == "qüowet")
    }

    @Test func theViewModelFollowsAnEditFromTheHostApp() throws {
        // The extension's path: the host app wrote files and bumped the
        // revision; a settings reload picks it up and reloads the layout on
        // screen. The shared store here is the test host's temporary directory.
        let shared = CustomLayoutStore.shared
        defer {
            try? FileManager.default.removeItem(at: shared.directory)
            KeyboardRegistry.replaceCustomLayouts([], revision: nil)
        }
        let original = makeCustomLayout(id: "custom-reg-follow", title: "Before")
        KeyboardRegistry.replaceCustomLayouts([original], revision: "r1")

        let defaults = InMemoryUserDefaults()
        defaults.set("r1", forKey: SettingsKey.customLayoutsRevision.rawValue)
        let viewModel = KeyboardViewModel(userDefaults: defaults, shouldPersistSettings: true)
        viewModel.loadDefinition(for: original.id)
        #expect(viewModel.currentDefinition?.title == "Before")

        try shared.save(makeCustomLayout(id: "custom-reg-follow", title: "After"))
        defaults.set("r2", forKey: SettingsKey.customLayoutsRevision.rawValue)
        viewModel.reloadSettings()
        #expect(viewModel.currentDefinition?.title == "After")
    }
}
}
