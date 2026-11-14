//
//  CustomLayoutLibraryTests.swift
//  WurstfingerTests
//
//  The host app's side of custom layouts: the library that saves, imports and
//  exports them and tells the keyboard, the editing helpers the visual editor
//  binds to, and the numbers the user-facing messages promise.
//

import Foundation
import Testing
@testable import WurstfingerKit

// MARK: - Library

extension CustomLayoutSharedState {
@Suite
@MainActor
struct LibraryTests {
    /// A library over a temporary store and in-memory defaults; the registry is
    /// the process-wide one, so each test empties it afterwards.
    private func withLibrary(
        _ body: (CustomLayoutLibrary, CustomLayoutStore, UserDefaults, () -> Int) throws -> Void
    ) rethrows {
        try withTemporaryStore { store in
            let defaults = InMemoryUserDefaults()
            // The library holds the callback for its lifetime, so the count is
            // read back through the counter.
            let counter = Counter()
            let library = CustomLayoutLibrary(store: store, defaults: defaults, didChange: { counter.value += 1 })
            defer { KeyboardRegistry.replaceCustomLayouts([], revision: nil) }
            try body(library, store, defaults, { counter.value })
        }
    }

    private final class Counter { var value = 0 }

    @Test func savingWritesTheFilePublishesTheSetAndBumpsTheRevision() throws {
        try withLibrary { library, store, defaults, notified in
            let layout = makeCustomLayout(id: "custom-lib-save")
            try library.save(layout)

            #expect(library.layouts == [layout])
            #expect(store.load().layouts == [layout])
            #expect(KeyboardRegistry.allLanguages.contains { $0.id == layout.id })
            #expect(KeyboardRegistry.load(id: layout.id)?.id == layout.id)
            #expect(defaults.string(forKey: SettingsKey.customLayoutsRevision.rawValue) != nil)
            #expect(notified() == 1)
        }
    }

    @Test func everyChangeWritesADifferentRevision() throws {
        try withLibrary { library, _, defaults, _ in
            let key = SettingsKey.customLayoutsRevision.rawValue
            try library.save(makeCustomLayout(id: "custom-lib-rev"))
            let first = defaults.string(forKey: key)
            try library.save(makeCustomLayout(id: "custom-lib-rev", title: "Edited"))
            #expect(defaults.string(forKey: key) != first)
        }
    }

    @Test func deletingRemovesItEverywhere() throws {
        try withLibrary { library, store, _, notified in
            try library.save(makeCustomLayout(id: "custom-lib-del"))
            try library.delete(id: "custom-lib-del")
            #expect(library.layouts.isEmpty)
            #expect(store.load().layouts.isEmpty)
            #expect(KeyboardRegistry.load(id: "custom-lib-del") == nil)
            #expect(notified() == 2)
        }
    }

    @Test func aRefusedSaveChangesNothing() {
        withLibrary { library, store, defaults, notified in
            #expect(throws: CustomLayoutError.invalidTitle) { try library.save(makeCustomLayout(title: " ")) }
            #expect(library.layouts.isEmpty)
            #expect(store.load().layouts.isEmpty)
            #expect(defaults.string(forKey: SettingsKey.customLayoutsRevision.rawValue) == nil)
            #expect(notified() == 0)
        }
    }

    @Test func duplicatingAShippedLayoutCreatesAnEditableCopyWithAFreshId() throws {
        try withLibrary { library, _, _, _ in
            let copy = try library.duplicate(languageId: "de_DE", title: "Mein Deutsch")
            #expect(copy.id.hasPrefix("custom-"))
            #expect(copy.title == "Mein Deutsch")
            #expect(copy.basedOn == "de_DE")
            #expect(library.layouts.map(\.id) == [copy.id])
            // It types what German types.
            let german = try #require(KeyboardRegistry.load(id: "de_DE"))
            let rebuilt = try #require(KeyboardRegistry.load(id: copy.id))
            #expect(rebuilt.modes == german.modes)
        }
    }

    @Test func duplicatingACustomLayoutCopiesItsEdits() throws {
        try withLibrary { library, _, _, _ in
            let original = makeCustomLayout(id: "custom-lib-orig") {
                $0.keys[GridSlot.center]?[.swipeUp] = CustomBinding("ö")
            }
            try library.save(original)
            let copy = try library.duplicate(languageId: original.id, title: "Copy")
            #expect(copy.id != original.id)
            #expect(copy.keys == original.keys)
            #expect(library.layouts.count == 2)
        }
    }

    @Test func duplicatingAnUnknownLayoutFails() {
        withLibrary { library, _, _, _ in
            #expect(throws: CustomLayoutError.notALayout) { try library.duplicate(languageId: "nope", title: "x") }
        }
    }

    @Test func exportThenImportRoundTrips() throws {
        try withLibrary { library, _, _, _ in
            let layout = makeCustomLayout(id: "custom-lib-share") {
                $0.keys[GridSlot.midLeft]?[.swipeRight] = CustomBinding("k", returnText: "K!")
            }
            try library.save(layout)
            let data = try library.exportData(for: layout)
            try library.delete(id: layout.id)

            let imported = try library.importDocument(data)
            #expect(imported == layout)
            #expect(library.layouts == [layout])
        }
    }

    @Test func importingAnIdThatExistsIsRefusedAndKeepsTheOriginal() throws {
        try withLibrary { library, _, _, _ in
            let layout = makeCustomLayout(id: "custom-lib-dup", title: "Original")
            try library.save(layout)
            let other = makeCustomLayout(id: "custom-lib-dup", title: "Imposter")
            let data = try CustomLayoutCodec.encode(other)
            #expect(throws: CustomLayoutError.duplicateId("custom-lib-dup")) { try library.importDocument(data) }
            #expect(library.layouts.map(\.title) == ["Original"])
        }
    }

    @Test func importingGarbageOrAnOversizedDocumentIsRefused() {
        withLibrary { library, _, _, _ in
            #expect(throws: CustomLayoutError.notALayout) { try library.importDocument(Data("hello".utf8)) }
            let big = Data(repeating: 0x20, count: CustomLayoutCodec.maxDocumentBytes + 1)
            #expect(throws: CustomLayoutError.self) { try library.importDocument(big) }
            #expect(library.layouts.isEmpty)
        }
    }

    @Test func aNewerSchemaIsRefusedWithItsOwnMessage() throws {
        try withLibrary { library, _, _, _ in
            let json = String(decoding: try CustomLayoutCodec.encode(makeCustomLayout()), as: UTF8.self)
                .replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 2")
            #expect(throws: CustomLayoutError.unsupportedSchema(version: 2)) {
                try library.importDocument(Data(json.utf8))
            }
        }
    }

    @Test func theLayoutLimitIsEnforcedOnImport() throws {
        try withLibrary { library, store, _, _ in
            // Filled through the store: going through the library would reload
            // and revalidate the whole set sixteen times on the main actor.
            for index in 0 ..< CustomLayoutStore.maxLayouts {
                try store.save(makeCustomLayout(id: "custom-lib-\(String(format: "%02d", index))", title: "L\(index)"))
            }
            library.reload()
            let extra = try CustomLayoutCodec.encode(makeCustomLayout(id: "custom-lib-extra", title: "Extra"))
            #expect(throws: CustomLayoutError.tooManyLayouts(limit: CustomLayoutStore.maxLayouts)) {
                try library.importDocument(extra)
            }
        }
    }

    @Test func aLibraryOpenedOnAStoreSeesWhatIsThere() throws {
        try withTemporaryStore { store in
            try store.save(makeCustomLayout(id: "custom-lib-open"))
            try Data("junk".utf8).write(to: store.directory.appendingPathComponent("custom-junk.json"))
            let library = CustomLayoutLibrary(store: store, defaults: InMemoryUserDefaults(), didChange: {})
            #expect(library.layouts.map(\.id) == ["custom-lib-open"])
            #expect(library.unreadableCount == 1)
        }
    }

    @Test func everyErrorHasAMessage() {
        let all: [CustomLayoutError] = [
            .tooLarge(bytes: 1), .notALayout, .unsupportedSchema(version: 9), .invalidId("x"), .reservedId("x"),
            .duplicateId("x"), .invalidTitle, .invalidLocale("x"), .unknownSlot("x"),
            .unknownGesture(slot: "x", gesture: "y"), .missingTap(slot: "x"),
            .invalidText(slot: "x", gesture: .tap), .returnWithoutBinding(slot: "x", gesture: .tap),
            .invalidDefinition("x"), .tooManyLayouts(limit: 1), .storageFailure,
        ]
        for error in all {
            #expect(!error.userMessage.isEmpty)
        }
    }

    /// The messages state these limits as digits; this keeps the text and the
    /// code from drifting apart.
    @Test func theLimitsTheMessagesPromiseAreTheRealOnes() {
        #expect(CustomLayout.maxTitleLength == 40)
        #expect(CustomLayout.maxTextLength == 8)
        #expect(CustomLayoutStore.maxLayouts == 16)
    }
}

}

// MARK: - Editing helpers

struct CustomLayoutEditingTests {
    @Test func aKeyShowsItsOwnTextThenTheInheritedSymbol() {
        var layout = makeCustomLayout()
        // topCenter swipes left to "+" in the shared set.
        #expect(layout.state(slot: GridSlot.topCenter, gesture: .swipeLeft) == .inherited(label: "+"))
        #expect(layout.displayedText(slot: GridSlot.topCenter, gesture: .swipeLeft) == "+")

        layout.setText("é", slot: GridSlot.topCenter, gesture: .swipeLeft)
        #expect(layout.state(slot: GridSlot.topCenter, gesture: .swipeLeft) == .custom(text: "é"))
        #expect(layout.displayedText(slot: GridSlot.topCenter, gesture: .swipeLeft) == "é")
    }

    @Test func clearingAFieldInheritsAgainAndRemovingUnbindsOnPurpose() {
        var layout = makeCustomLayout()
        layout.setText("é", slot: GridSlot.topCenter, gesture: .swipeLeft)
        layout.setText("", slot: GridSlot.topCenter, gesture: .swipeLeft)
        #expect(layout.state(slot: GridSlot.topCenter, gesture: .swipeLeft) == .inherited(label: "+"))

        layout.removeBinding(slot: GridSlot.topCenter, gesture: .swipeLeft)
        #expect(layout.state(slot: GridSlot.topCenter, gesture: .swipeLeft) == .removed)
        #expect(layout.displayedText(slot: GridSlot.topCenter, gesture: .swipeLeft) == "")

        layout.restoreBinding(slot: GridSlot.topCenter, gesture: .swipeLeft)
        #expect(layout.state(slot: GridSlot.topCenter, gesture: .swipeLeft) == .inherited(label: "+"))
    }

    @Test func withoutSharedSymbolsNothingIsInheritedButTheEssentials() {
        var layout = makeCustomLayout()
        layout.usesSharedSymbols = false
        #expect(layout.state(slot: GridSlot.topCenter, gesture: .swipeLeft) == .inherited(label: nil))
        #expect(layout.state(slot: GridSlot.midRight, gesture: .swipeUp) == .inherited(label: "⇧"))
        #expect(layout.state(slot: GridSlot.bottomCenter, gesture: .swipeDown) == .inherited(label: "."))
    }

    @Test func typedTextIsClippedToTheLimitAndAReturnOutputSurvives() {
        var layout = makeCustomLayout()
        layout.keys[GridSlot.midLeft]?[.swipeRight] = CustomBinding("k", returnText: "K!")
        layout.setText("abcdefghijkl", slot: GridSlot.center, gesture: .swipeUp)
        #expect(layout.keys[GridSlot.center]?[.swipeUp]?.text == "abcdefgh")
        layout.setText("kk", slot: GridSlot.midLeft, gesture: .swipeRight)
        #expect(layout.keys[GridSlot.midLeft]?[.swipeRight] == CustomBinding("kk", returnText: "K!"))
        #expect(layout.validate().isEmpty)
    }

    @Test func aTapCannotBeClearedByTheField() {
        var layout = makeCustomLayout()
        layout.setText("", slot: GridSlot.center, gesture: .tap)
        // The field sets an empty tap, which validation then reports.
        #expect(layout.validate().contains(.missingTap(slot: GridSlot.center)))
    }
}
