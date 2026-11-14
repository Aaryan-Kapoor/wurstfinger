//
//  CustomLayoutRobustnessTests.swift
//  WurstfingerKitTests
//
//  Custom layouts under hostile or unlucky conditions: a directory full of
//  junk, an edit that lands while a definition is being built, and the
//  selected layout deleted from under the keyboard.
//

import Foundation
import Testing
@testable import WurstfingerKit
@testable import WurstfingerScenarioKit

// MARK: - The store

struct CustomLayoutStoreBoundsTests {
    @Test func aDirectoryOfJunkIsOpenedOnlyUpToTheCap() throws {
        try withTemporaryStore { store in
            try store.save(makeCustomLayout(id: "custom-aaa", title: "First"))
            // Far more junk than one read is willing to open, then a valid
            // layout that sorts after all of it.
            let junkCount = CustomLayoutStore.maxFilesRead * 3
            for index in 0 ..< junkCount {
                let name = "custom-junk-\(String(format: "%04d", index)).json"
                try Data("{broken".utf8).write(to: store.directory.appendingPathComponent(name))
            }
            try CustomLayoutCodec.encode(makeCustomLayout(id: "custom-zzz", title: "Last"))
                .write(to: store.directory.appendingPathComponent("custom-zzz.json"))

            let contents = store.load()
            #expect(contents.layouts.map(\.id) == ["custom-aaa"])
            // Opened and found broken: only as many as the cap allows.
            let opened = contents.rejected.values.filter { $0 == .notALayout }.count
            #expect(opened == CustomLayoutStore.maxFilesRead - 1)
            // The rest were turned away without being read, valid or not.
            #expect(contents.rejected["custom-zzz"] == .tooManyLayouts(limit: CustomLayoutStore.maxLayouts))
            #expect(contents.rejected.count == junkCount + 1)
        }
    }

    @Test func theReadCapLeavesRoomForEveryLayoutTheStoreMayHold() {
        #expect(CustomLayoutStore.maxFilesRead >= CustomLayoutStore.maxLayouts)
    }
}

// MARK: - The registry

extension CustomLayoutSharedState {
@Suite
@MainActor
struct RobustnessTests {
    /// A descriptor taken before an edit builds from the layout as it is when
    /// the build runs: the build is what lands in the cache, and a cache that
    /// an edit evicted in between must not receive the old layout.
    @Test func aBuildThatStartedBeforeAnEditBuildsTheEditedLayout() throws {
        let original = makeCustomLayout(id: "custom-race-build", title: "Before")
        KeyboardRegistry.replaceCustomLayouts([original], revision: "r1")
        defer { KeyboardRegistry.replaceCustomLayouts([], revision: nil) }

        let descriptor = try #require(KeyboardRegistry.descriptor(for: original.id))
        let edited = makeCustomLayout(id: original.id, title: "After") {
            $0.keys[GridSlot.topLeft]?[.tap] = CustomBinding("z")
        }
        KeyboardRegistry.replaceCustomLayouts([edited], revision: "r2")

        let built = descriptor.makeDefinition()
        #expect(built.title == "After")
        #expect(built.modes[ModeNames.main]?.keys[GridSlot.topLeft]?.bindings[.tap]?.action == .commitText("z"))
    }

    @Test func aBuildForALayoutThatWasDeletedMeanwhileStillReturnsADefinition() throws {
        let original = makeCustomLayout(id: "custom-race-gone")
        KeyboardRegistry.replaceCustomLayouts([original], revision: "r1")
        defer { KeyboardRegistry.replaceCustomLayouts([], revision: nil) }

        let descriptor = try #require(KeyboardRegistry.descriptor(for: original.id))
        KeyboardRegistry.replaceCustomLayouts([], revision: "r2")
        #expect(descriptor.makeDefinition().id == original.id, "the caller is handed its build; the cache never keeps it")
        #expect(!KeyboardRegistry.isCached(id: original.id))
    }

    /// Prewarms race edits; whatever survives in the compiled cache afterwards
    /// must have been compiled from the layout as it finally is.
    @Test func aPrewarmRacingEditsLeavesNoStaleTables() async throws {
        let id = "custom-race-prewarm"
        func layout(_ letter: String) -> CustomLayout {
            makeCustomLayout(id: id, title: "T") { $0.keys[GridSlot.topLeft]?[.tap] = CustomBinding(letter) }
        }
        KeyboardRegistry.replaceCustomLayouts([layout("a")], revision: "r0")
        defer { KeyboardRegistry.replaceCustomLayouts([], revision: nil) }

        let letters = ["b", "c", "d", "e", "f", "g", "h", "i"]
        let prewarms = Task.detached {
            for _ in 0 ..< 40 { await KeyboardRegistry.prewarm([id]) }
        }
        for (index, letter) in letters.enumerated() {
            KeyboardRegistry.replaceCustomLayouts([layout(letter)], revision: "r\(index + 1)")
            await Task.yield()
        }
        await prewarms.value
        await KeyboardRegistry.prewarm([id])

        let latest = try #require(KeyboardRegistry.load(id: id))
        let signature = KeyboardRegistry.compiledSignature(languageId: id, numpadType: nil)
        let tables = KeyboardRegistry.compiled(for: latest, signature: signature)
        let table = try #require(tables.mode(ModeNames.main))
        let slot = try #require(table.slot(for: GridSlot.topLeft))
        #expect(table.binding(slot: slot, gesture: .tap, isReturn: false)?.action == .commitText("i"))
    }

    // MARK: The selected layout goes away

    @Test func deletingTheSelectedLayoutFallsBackToEnglishOnTheNextReload() throws {
        let shared = CustomLayoutStore.shared
        defer {
            try? FileManager.default.removeItem(at: shared.directory)
            KeyboardRegistry.replaceCustomLayouts([], revision: nil)
        }
        let layout = makeCustomLayout(id: "custom-selected-gone", title: "Mine")
        try shared.save(layout)
        KeyboardRegistry.replaceCustomLayouts([layout], revision: "r1")

        let defaults = InMemoryUserDefaults()
        defaults.set("r1", forKey: SettingsKey.customLayoutsRevision.rawValue)
        defaults.set(["en_US", layout.id], forKey: SettingsKey.enabledLanguageIds.rawValue)
        defaults.set(layout.id, forKey: SettingsKey.selectedLanguageId.rawValue)
        let viewModel = KeyboardViewModel(userDefaults: defaults, shouldPersistSettings: true)
        viewModel.loadDefinition(for: layout.id)
        #expect(viewModel.currentDefinition?.id == layout.id)
        let customSignature = KeyboardRegistry.compiledSignature(languageId: layout.id, numpadType: nil)
        #expect(KeyboardRegistry.isCompiledCached(signature: customSignature))

        try shared.delete(id: layout.id)
        defaults.set("r2", forKey: SettingsKey.customLayoutsRevision.rawValue)
        viewModel.reloadSettings()

        #expect(viewModel.currentDefinition?.id == "en_US", "the keyboard shows English, not a blank or stale layout")
        #expect(viewModel.compiledDefinition != nil)
        #expect(viewModel.activeModeName == ModeNames.main)
        #expect(viewModel.enabledLanguageIds == ["en_US"])
        #expect(!KeyboardRegistry.isCached(id: layout.id))
        #expect(!KeyboardRegistry.isCompiledCached(signature: customSignature))
        #expect(viewModel.compiledDefinition?.mode(ModeNames.main) != nil)
    }

    @Test func editingTheSelectedLayoutTypesTheEditAfterTheNextReload() throws {
        let shared = CustomLayoutStore.shared
        defer {
            try? FileManager.default.removeItem(at: shared.directory)
            KeyboardRegistry.replaceCustomLayouts([], revision: nil)
        }
        let original = makeCustomLayout(id: "custom-selected-edit", title: "Mine")
        KeyboardRegistry.replaceCustomLayouts([original], revision: "r1")
        let defaults = InMemoryUserDefaults()
        defaults.set("r1", forKey: SettingsKey.customLayoutsRevision.rawValue)
        let viewModel = KeyboardViewModel(userDefaults: defaults, shouldPersistSettings: true)
        let target = ScenarioTextTarget()
        viewModel.bindTextInputTarget(target)
        viewModel.loadDefinition(for: original.id)

        try shared.save(makeCustomLayout(id: original.id, title: "Mine") {
            $0.keys[GridSlot.topLeft]?[.tap] = CustomBinding("z")
        })
        defaults.set("r2", forKey: SettingsKey.customLayoutsRevision.rawValue)
        viewModel.reloadSettings()

        viewModel.handleGesture(.tap, keyId: GridSlot.topLeft, isReturn: false)
        #expect(target.text == "z", "the compiled tables follow the edit, not just the definition")
    }
}
}
