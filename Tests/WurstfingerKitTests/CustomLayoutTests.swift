//
//  CustomLayoutTests.swift
//  WurstfingerTests
//
//  The custom-layout document: building a keyboard from it, reading a shipped
//  keyboard back into one, the JSON it is stored as, and everything that makes
//  the app refuse a document.
//

import Foundation
import Testing
@testable import WurstfingerKit

/// A small valid layout the tests start from.
func makeCustomLayout(
    id: String = "custom-test-layout",
    title: String = "Test layout",
    locale: String = "en_US",
    edit: (inout CustomLayout) -> Void = { _ in }
) -> CustomLayout {
    let letters = ["q", "w", "e", "r", "t", "y", "u", "i", "o"]
    var keys: [String: [GestureType: CustomBinding]] = [:]
    for (slot, letter) in zip(CustomLayout.slots, letters) {
        keys[slot] = [.tap: CustomBinding(letter)]
    }
    keys[GridSlot.center]?[.swipeUp] = CustomBinding("ü")
    var layout = CustomLayout(id: id, title: title, localeIdentifier: locale, keys: keys)
    edit(&layout)
    return layout
}

// MARK: - Building a keyboard

struct CustomLayoutDefinitionTests {
    @Test func buildsAValidKeyboardFromTheDocument() throws {
        let layout = makeCustomLayout()
        #expect(layout.validate().isEmpty)
        let definition = layout.makeDefinition(basedOn: nil)
        #expect(definition.id == "custom-test-layout")
        #expect(definition.title == "Test layout")
        #expect(definition.validate().isEmpty)
        // An ASCII-letter layout also gets the one-shot Ctrl and Alt modes, and
        // every layout the two emoji pages.
        #expect(definition.modes.keys.sorted() == [
            ModeNames.alt, ModeNames.capsLock, ModeNames.control, ModeNames.emoji, ModeNames.emojiMore,
            ModeNames.main, ModeNames.numeric, ModeNames.shifted,
        ])

        let main = try #require(definition.modes[ModeNames.main])
        #expect(main.keys[GridSlot.topLeft]?.bindings[.tap]?.action == .commitText("q"))
        #expect(main.keys[GridSlot.center]?.bindings[.swipeUp]?.action == .commitText("ü"))
        let shifted = try #require(definition.modes[ModeNames.shifted])
        #expect(shifted.keys[GridSlot.center]?.bindings[.swipeUp]?.action == .commitText("Ü"))
    }

    @Test func emptyTextRemovesASharedPunctuationBinding() throws {
        // topCenter swipes left to "+" in the shared set.
        let with = makeCustomLayout().makeDefinition(basedOn: nil)
        #expect(with.modes[ModeNames.main]?.keys[GridSlot.topCenter]?.bindings[.swipeLeft]?.action == .commitText("+"))

        let layout = makeCustomLayout { $0.keys[GridSlot.topCenter]?[.swipeLeft] = CustomBinding("") }
        #expect(layout.validate().isEmpty)
        let without = layout.makeDefinition(basedOn: nil)
        #expect(without.modes[ModeNames.main]?.keys[GridSlot.topCenter]?.bindings[.swipeLeft] == nil)
    }

    @Test func withoutSharedSymbolsOnlyTheShiftAffordanceRemains() throws {
        let layout = makeCustomLayout { $0.usesSharedSymbols = false }
        let main = try #require(layout.makeDefinition(basedOn: nil).modes[ModeNames.main])
        #expect(main.keys[GridSlot.topCenter]?.bindings.keys.sorted { $0.rawValue < $1.rawValue } == [.tap])
        #expect(main.keys[GridSlot.midRight]?.bindings[.swipeUp]?.action == .switchMode(ModeNames.shifted))
    }

    @Test func circlesAndLongPressBindToTheirOwnText() throws {
        let layout = makeCustomLayout {
            $0.keys[GridSlot.center]?[.circularClockwise] = CustomBinding("1")
            $0.keys[GridSlot.center]?[.circularCounterclockwise] = CustomBinding("2")
            $0.keys[GridSlot.center]?[.longPress] = CustomBinding("3")
        }
        #expect(layout.validate().isEmpty)
        let center = try #require(layout.makeDefinition(basedOn: nil).modes[ModeNames.main]?.keys[GridSlot.center])
        #expect(center.bindings[.circularClockwise]?.action == .commitText("1"))
        #expect(center.bindings[.circularCounterclockwise]?.action == .commitText("2"))
        #expect(center.bindings[.longPress]?.action == .commitText("3"))
    }

    @Test func aReturnSwipeTypesItsOwnText() throws {
        let layout = makeCustomLayout {
            $0.keys[GridSlot.midLeft]?[.swipeRight] = CustomBinding("k", returnText: "K!")
        }
        #expect(layout.validate().isEmpty)
        let binding = try #require(
            layout.makeDefinition(basedOn: nil).modes[ModeNames.main]?.keys[GridSlot.midLeft]?.bindings[.swipeRight]
        )
        #expect(binding.returnAction == .commitText("K!"))
    }

    @Test func aCaselessLayoutHasNoShiftedMode() {
        let definition = makeCustomLayout { $0.supportsCapitalization = false }.makeDefinition(basedOn: nil)
        #expect(definition.modes[ModeNames.shifted] == nil)
        #expect(!definition.settings.autoCapitalize)
        #expect(definition.validate().isEmpty)
    }

    @Test func settingsOfTheBaseLayoutCarryOver() throws {
        let vietnamese = try #require(KeyboardRegistry.load(id: "vi_VN"))
        let hebrew = try #require(KeyboardRegistry.load(id: "he_IL"))
        let layout = makeCustomLayout()
        let telex = layout.makeDefinition(basedOn: vietnamese)
        #expect(telex.settings.inputMethod == .telex)
        #expect(layout.makeDefinition(basedOn: hebrew).numericBackToAlphaLabel == hebrew.numericBackToAlphaLabel)
        #expect(layout.makeDefinition(basedOn: nil).settings.inputMethod == .direct)
    }

    // MARK: - Reading a shipped keyboard back

    /// The promise of "Duplicate": a copy types exactly what its original does,
    /// in every mode, for every shipped layout — and survives the JSON round
    /// trip and validation on the way.
    ///
    /// One test over all layouts rather than one per layout: each check builds
    /// a few definitions, and running 27 of them side by side competes with the
    /// timing-sensitive concurrency tests for the same cores.
    @Test func duplicatingAShippedLayoutRebuildsItExactly() throws {
        for descriptor in LanguageDefinitions.all {
            let original = descriptor.makeDefinition()
            let copy = CustomLayout(duplicating: original, id: "custom-copy", title: "Copy")
            #expect(copy.validate().isEmpty, "\(descriptor.id): \(copy.validate())")
            #expect(copy.makeDefinition(basedOn: nil).validate().isEmpty, "\(descriptor.id) structure")

            let rebuilt = copy.makeDefinition(basedOn: original)
            #expect(rebuilt.modes == original.modes, "\(descriptor.id) differs after duplicating")
            #expect(rebuilt.settings == original.settings, "\(descriptor.id) settings")
            #expect(rebuilt.numericDigits == original.numericDigits)
            #expect(rebuilt.numericBackToAlphaLabel == original.numericBackToAlphaLabel)
            #expect(rebuilt.localeIdentifier == original.localeIdentifier)

            let decoded = try CustomLayoutCodec.decode(CustomLayoutCodec.encode(copy))
            #expect(decoded == copy, "\(descriptor.id) JSON round trip")
        }
    }

    @Test func duplicatingThumbKeyDropsTheSharedSymbols() {
        let copy = CustomLayout(duplicating: LanguageDefinitions.thumbKeyEnglish.makeDefinition(), id: "custom-tk", title: "TK")
        #expect(!copy.usesSharedSymbols)
        #expect(copy.basedOn == "en_US_thumbkey")
        #expect(copy.keys[GridSlot.center]?[.swipeUp]?.text == "q")
    }

    @Test func duplicatingEnglishKeepsTheSharedSymbolsAndJustTheLetters() {
        let copy = CustomLayout(duplicating: LanguageDefinitions.english.makeDefinition(), id: "custom-en", title: "EN")
        #expect(copy.usesSharedSymbols)
        #expect(copy.supportsCapitalization)
        #expect(copy.tapText(of: GridSlot.topLeft) == "a")
        #expect(copy.keys[GridSlot.center]?[.swipeUp]?.text == "u")
        // No entry for the shared punctuation that is simply inherited.
        #expect(copy.keys[GridSlot.topCenter]?[.swipeLeft] == nil)
    }

    @Test func hebrewFinalFormsSurviveAsReturnSwipes() throws {
        let hebrew = LanguageDefinitions.hebrew.makeDefinition()
        let copy = CustomLayout(duplicating: hebrew, id: "custom-he", title: "HE")
        #expect(!copy.supportsCapitalization)
        let withReturn = copy.keys.values.flatMap(\.values).filter { $0.returnText != nil }
        #expect(!withReturn.isEmpty)
    }
}

// MARK: - JSON

struct CustomLayoutCodecTests {
    @Test func roundTripsAHandWrittenLayout() throws {
        let layout = makeCustomLayout {
            $0.basedOn = "de_DE"
            $0.keys[GridSlot.midLeft]?[.swipeRight] = CustomBinding("k", returnText: "K!")
            $0.keys[GridSlot.center]?[.swipeDown] = CustomBinding("")
        }
        let decoded = try CustomLayoutCodec.decode(CustomLayoutCodec.encode(layout))
        #expect(decoded == layout)
    }

    @Test func writesTheDocumentedShape() throws {
        let layout = makeCustomLayout {
            $0.keys[GridSlot.midLeft]?[.swipeRight] = CustomBinding("k", returnText: "K!")
        }
        let json = try #require(
            JSONSerialization.jsonObject(with: CustomLayoutCodec.encode(layout)) as? [String: Any]
        )
        #expect(json["schemaVersion"] as? Int == 1)
        #expect(json["id"] as? String == "custom-test-layout")
        #expect(json["locale"] as? String == "en_US")
        #expect(json["capitalization"] as? Bool == true)
        #expect(json["sharedSymbols"] as? Bool == true)
        let keys = try #require(json["keys"] as? [String: [String: Any]])
        #expect(keys["topLeft"]?["tap"] as? String == "q")
        #expect((keys["midLeft"]?["swipeRight"] as? [String: String]) == ["text": "k", "return": "K!"])
    }

    @Test func missingOptionalFieldsTakeTheirDefaults() throws {
        let json = """
        {"schemaVersion": 1, "id": "custom-min", "title": "Min", "locale": "en",
         "keys": {"topLeft":{"tap":"a"},"topCenter":{"tap":"b"},"topRight":{"tap":"c"},
                  "midLeft":{"tap":"d"},"center":{"tap":"e"},"midRight":{"tap":"f"},
                  "bottomLeft":{"tap":"g"},"bottomCenter":{"tap":"h"},"bottomRight":{"tap":"i"}}}
        """
        let layout = try CustomLayoutCodec.decode(Data(json.utf8))
        #expect(layout.supportsCapitalization)
        #expect(layout.usesSharedSymbols)
        #expect(layout.basedOn == nil)
    }

    // MARK: Schema version

    private func document(version: String) -> Data {
        let tap = { (letter: String) in "{\"tap\":\"\(letter)\"}" }
        let keys = zip(CustomLayout.slots, "abcdefghi").map { "\"\($0)\":\(tap(String($1)))" }.joined(separator: ",")
        return Data("{\(version)\"id\":\"custom-v\",\"title\":\"V\",\"locale\":\"en\",\"keys\":{\(keys)}}".utf8)
    }

    @Test func acceptsTheCurrentSchemaVersion() throws {
        #expect(CustomLayoutCodec.currentSchemaVersion == 1)
        #expect(try CustomLayoutCodec.decode(document(version: "\"schemaVersion\":1,")).id == "custom-v")
    }

    @Test(arguments: [2, 3, 99])
    func refusesANewerSchema(version: Int) {
        #expect(throws: CustomLayoutError.unsupportedSchema(version: version)) {
            try CustomLayoutCodec.decode(document(version: "\"schemaVersion\":\(version),"))
        }
    }

    @Test(arguments: [0, -1])
    func refusesAnImpossibleSchema(version: Int) {
        #expect(throws: CustomLayoutError.unsupportedSchema(version: version)) {
            try CustomLayoutCodec.decode(document(version: "\"schemaVersion\":\(version),"))
        }
    }

    @Test func refusesADocumentWithoutAVersion() {
        #expect(throws: CustomLayoutError.notALayout) { try CustomLayoutCodec.decode(document(version: "")) }
        #expect(throws: CustomLayoutError.notALayout) {
            try CustomLayoutCodec.decode(document(version: "\"schemaVersion\":\"1\","))
        }
    }

    // MARK: Hostile input

    @Test(arguments: ["", "not json", "[]", "null", "{}", "{\"schemaVersion\":1}", "\u{0}\u{1}\u{2}"])
    func refusesDocumentsThatAreNotLayouts(text: String) {
        #expect(throws: CustomLayoutError.notALayout) { try CustomLayoutCodec.decode(Data(text.utf8)) }
    }

    @Test func refusesAnOversizedDocumentBeforeParsingIt() {
        let big = Data(repeating: 0x20, count: CustomLayoutCodec.maxDocumentBytes + 1)
        #expect(throws: CustomLayoutError.tooLarge(bytes: CustomLayoutCodec.maxDocumentBytes + 1)) {
            try CustomLayoutCodec.decode(big)
        }
    }

    @Test func refusesAnUnknownGestureAndAnUnknownSlot() throws {
        let valid = String(decoding: try CustomLayoutCodec.encode(makeCustomLayout()), as: UTF8.self)
        let badGesture = valid.replacingOccurrences(of: "\"swipeUp\"", with: "\"swipeSideways\"")
        #expect(throws: CustomLayoutError.unknownGesture(slot: GridSlot.center, gesture: "swipeSideways")) {
            try CustomLayoutCodec.decode(Data(badGesture.utf8))
        }
        let badSlot = valid.replacingOccurrences(of: "\"bottomRight\"", with: "\"topFar\"")
        #expect(throws: CustomLayoutError.unknownSlot("topFar")) { try CustomLayoutCodec.decode(Data(badSlot.utf8)) }
    }

    @Test func refusesADocumentWithAnEmptyBindingObject() {
        let json = String(decoding: document(version: "\"schemaVersion\":1,"), as: UTF8.self)
            .replacingOccurrences(of: "{\"tap\":\"a\"}", with: "{\"tap\":{}}")
        #expect(throws: CustomLayoutError.notALayout) { try CustomLayoutCodec.decode(Data(json.utf8)) }
    }
}

// MARK: - Validation

struct CustomLayoutValidationTests {
    private func problems(_ edit: (inout CustomLayout) -> Void) -> [CustomLayoutError] {
        makeCustomLayout(edit: edit).validate()
    }

    /// Whether editing the valid layout makes validation report `error`.
    /// (Spelled as a helper because `#expect` cannot expand a trailing closure
    /// followed by a member access.)
    private func reports(_ error: CustomLayoutError, _ edit: (inout CustomLayout) -> Void) -> Bool {
        problems(edit).contains(error)
    }

    private func isClean(_ edit: (inout CustomLayout) -> Void) -> Bool {
        problems(edit).isEmpty
    }

    @Test func aValidLayoutHasNoProblems() {
        #expect(makeCustomLayout().validate().isEmpty)
    }

    @Test(arguments: ["", "ab", "Has Space", "UPPER", "a/b", "../etc", ".hidden", "trailing.", "ünï-code",
                      String(repeating: "x", count: 65)])
    func refusesAnId(id: String) {
        #expect(reports(.invalidId(id)) { $0.id = id })
    }

    @Test(arguments: ["custom-abc", "x.y_z-1", "abc", "my_layout.v2"])
    func acceptsAnId(id: String) {
        #expect(isClean { $0.id = id })
    }

    /// Shipped ids are mostly `en_US`-style mixed case, which the slug rule
    /// already refuses; `ur` and `ar` are lowercase, so only the reserved check
    /// keeps a custom layout off them — and off the cache cell they own.
    @Test(arguments: ["ur", "ar"])
    func shortLowercaseShippedIdsAreNotSlugs(id: String) {
        #expect(KeyboardRegistry.isShippedID(id))
        #expect(CustomLayout.isValidID(id) == false) // too short for a slug
        let longer = makeCustomLayout { $0.id = id }
        #expect(longer.validate().contains(.invalidId(id)))
    }

    @Test func everyShippedIdIsEitherNotASlugOrReserved() {
        for shipped in KeyboardRegistry.available {
            let layout = makeCustomLayout { $0.id = shipped.id }
            #expect(!layout.validate().isEmpty, "\(shipped.id) would be accepted as a custom id")
        }
    }

    @Test(arguments: ["", "   ", "\n", String(repeating: "x", count: 41)])
    func refusesATitle(title: String) {
        #expect(reports(.invalidTitle) { $0.title = title })
    }

    @Test(arguments: ["", "e", "english", "en_", "_US", "en__US", "en_US_x_y", "en US", "EN"])
    func refusesALocale(locale: String) {
        #expect(reports(.invalidLocale(locale)) { $0.localeIdentifier = locale })
    }

    @Test(arguments: ["en", "en_US", "en-US", "zh-Hans_CN", "fil"])
    func acceptsALocale(locale: String) {
        #expect(isClean { $0.localeIdentifier = locale })
    }

    @Test func requiresATapOnEveryKey() {
        #expect(reports(.missingTap(slot: GridSlot.center)) { $0.keys[GridSlot.center]?[.tap] = nil })
        #expect(reports(.missingTap(slot: GridSlot.center)) { $0.keys[GridSlot.center]?[.tap] = CustomBinding("") })
        #expect(reports(.missingTap(slot: GridSlot.topLeft)) { $0.keys[GridSlot.topLeft] = nil })
    }

    @Test func refusesAKeyTheGridDoesNotHave() {
        #expect(reports(.unknownSlot("nowhere")) { $0.keys["nowhere"] = [.tap: CustomBinding("x")] })
        #expect(reports(.unknownSlot(GridSlot.zero)) { $0.keys[GridSlot.zero] = [.tap: CustomBinding("0")] })
    }

    @Test(arguments: ["abcdefghi", "a\u{0}", "a\nb", "\t", "x\u{7}"])
    func refusesTextThatIsTooLongOrHasControlCharacters(text: String) {
        let result = problems { $0.keys[GridSlot.center]?[.swipeLeft] = CustomBinding(text) }
        #expect(result.contains(.invalidText(slot: GridSlot.center, gesture: .swipeLeft)))
    }

    @Test(arguments: ["a", "ß", "qu", "👍🏽", "e\u{301}", "ǆ", "אב", "한"])
    func acceptsText(text: String) {
        #expect(isClean { $0.keys[GridSlot.center]?[.swipeLeft] = CustomBinding(text) })
        #expect(isClean { $0.keys[GridSlot.center]?[.tap] = CustomBinding(text) })
    }

    @Test func refusesAReturnSwipeThatHasNothingToReturnFrom() {
        // On a tap, on a circle, and on a swipe whose own text is empty.
        #expect(reports(.returnWithoutBinding(slot: GridSlot.center, gesture: .tap)) { $0.keys[GridSlot.center]?[.tap] = CustomBinding("o", returnText: "O") })
        #expect(reports(.returnWithoutBinding(slot: GridSlot.center, gesture: .circularClockwise)) { $0.keys[GridSlot.center]?[.circularClockwise] = CustomBinding("1", returnText: "2") })
        #expect(reports(.returnWithoutBinding(slot: GridSlot.center, gesture: .swipeUp)) { $0.keys[GridSlot.center]?[.swipeUp] = CustomBinding("", returnText: "x") })
    }

    @Test func aBadLayoutIsReportedNotTrapped() {
        // Several problems at once, including the ones the factory would trap on.
        let result = problems {
            $0.keys[GridSlot.center]?[.tap] = nil
            $0.keys[GridSlot.center]?[.swipeUp] = CustomBinding("", returnText: "x")
        }
        #expect(result.count >= 2)
    }

    @Test func structuralValidatorsRejectAHandBrokenDefinitionDerivedFromACustomLayout() throws {
        // Pins the wiring of `ValidationError` into `invalidDefinition`: a mode
        // that points at a missing target is exactly what `validate()` reports.
        let definition = makeCustomLayout().makeDefinition(basedOn: nil)
        let main = try #require(definition.modes[ModeNames.main])
        let broken = KeyboardDefinition(
            title: definition.title, id: definition.id, localeIdentifier: definition.localeIdentifier,
            modes: [ModeNames.main: main], defaultMode: ModeNames.main, settings: definition.settings
        )
        #expect(broken.validate().contains(.missingMode(ModeNames.shifted)))
    }
}
