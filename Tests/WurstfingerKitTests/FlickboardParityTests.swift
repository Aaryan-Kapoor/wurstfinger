//
//  FlickboardParityTests.swift
//  WurstfingerTests
//
//  Capability parity with Flickboard (docs/layout-parity.md): what the new
//  bindings and actions do, and the guard that matters most — no binding
//  MessagEase users already know has moved.
//

import Foundation
import Testing
@testable import WurstfingerKit
@testable import WurstfingerScenarioKit

// MARK: - Nothing that was there moved

/// The English main mode as it shipped before the parity work: one row per
/// binding of the nine grid keys (key, gesture, hint label, action, return
/// swipe). Every row must still be present and unchanged, with the single,
/// deliberate exception named in `knownChanges`.
private let englishBindingsBeforeParity: [(String, GestureType, String, KeyAction, KeyAction?)] = [
        ("bottomCenter", .tap, "e", .commitText("e"), nil),
        ("bottomCenter", .swipeUp, "w", .commitText("w"), .commitText("W")),
        ("bottomCenter", .swipeDown, ".", .commitText("."), .commitText("…")),
        ("bottomCenter", .swipeRight, "z", .commitText("z"), .commitText("Z")),
        ("bottomCenter", .swipeUpLeft, "\"", .commitText("\""), .commitText("“")),
        ("bottomCenter", .swipeUpRight, "'", .commitText("'"), .commitText("”")),
        ("bottomCenter", .swipeDownLeft, ",", .commitText(","), .commitText(",")),
        ("bottomCenter", .swipeDownRight, ":", .commitText(":"), .commitText("„")),
        ("bottomLeft", .tap, "t", .commitText("t"), nil),
        ("bottomLeft", .swipeUp, "¨", .compose(trigger: "¨"), .commitText("˝")),
        ("bottomLeft", .swipeLeft, "<", .commitText("<"), .commitText("‹")),
        ("bottomLeft", .swipeRight, "*", .commitText("*"), .commitText("†")),
        ("bottomLeft", .swipeUpLeft, "~", .compose(trigger: "~"), .commitText("˜")),
        ("bottomLeft", .swipeUpRight, "y", .commitText("y"), .commitText("Y")),
        ("bottomLeft", .swipeDownRight, "⇥", .commitText("\t"), .commitText("\t")),
        ("bottomRight", .tap, "s", .commitText("s"), nil),
        ("bottomRight", .swipeUp, "&", .commitText("&"), .commitText("§")),
        ("bottomRight", .swipeLeft, "#", .commitText("#"), .commitText("£")),
        ("bottomRight", .swipeRight, ">", .commitText(">"), .commitText("›")),
        ("bottomRight", .swipeUpLeft, "f", .commitText("f"), .commitText("F")),
        ("bottomRight", .swipeUpRight, "°", .compose(trigger: "°"), .commitText("º")),
        ("bottomRight", .swipeDownLeft, ";", .commitText(";"), .commitText(";")),
        ("bottomRight", .swipeDownRight, "", .commitText(" "), .commitText(" ")),
        ("center", .tap, "o", .commitText("o"), nil),
        ("center", .swipeUp, "u", .commitText("u"), .commitText("U")),
        ("center", .swipeDown, "d", .commitText("d"), .commitText("D")),
        ("center", .swipeLeft, "c", .commitText("c"), .commitText("C")),
        ("center", .swipeRight, "b", .commitText("b"), .commitText("B")),
        ("center", .swipeUpLeft, "q", .commitText("q"), .commitText("Q")),
        ("center", .swipeUpRight, "p", .commitText("p"), .commitText("P")),
        ("center", .swipeDownLeft, "g", .commitText("g"), .commitText("G")),
        ("center", .swipeDownRight, "j", .commitText("j"), .commitText("J")),
        ("midLeft", .tap, "h", .commitText("h"), nil),
        ("midLeft", .swipeLeft, "(", .commitText("("), .commitText(")")),
        ("midLeft", .swipeRight, "k", .commitText("k"), .commitText("K")),
        ("midLeft", .swipeUpLeft, "{", .commitText("{"), .commitText("}")),
        ("midLeft", .swipeUpRight, "%", .commitText("%"), .commitText("‰")),
        ("midLeft", .swipeDownLeft, "[", .commitText("["), .commitText("]")),
        ("midLeft", .swipeDownRight, "_", .commitText("_"), .commitText("¬")),
        ("midRight", .tap, "r", .commitText("r"), nil),
        ("midRight", .swipeUp, "⇧", .switchMode("shifted"), .capitalizeWord(uppercased: true)),
        ("midRight", .swipeLeft, "m", .commitText("m"), .commitText("M")),
        ("midRight", .swipeRight, ")", .commitText(")"), .commitText("(")),
        ("midRight", .swipeUpLeft, "|", .commitText("|"), .commitText("¶")),
        ("midRight", .swipeUpRight, "}", .commitText("}"), .commitText("{")),
        ("midRight", .swipeDownLeft, "@", .commitText("@"), .commitText("ª")),
        ("midRight", .swipeDownRight, "]", .commitText("]"), .commitText("[")),
        ("topCenter", .tap, "n", .commitText("n"), nil),
        ("topCenter", .swipeUp, "^", .compose(trigger: "^"), .compose(trigger: "ˇ")),
        ("topCenter", .swipeDown, "l", .commitText("l"), .commitText("L")),
        ("topCenter", .swipeLeft, "+", .commitText("+"), .commitText("×")),
        ("topCenter", .swipeRight, "!", .commitText("!"), .commitText("¡")),
        ("topCenter", .swipeUpLeft, "`", .compose(trigger: "ˋ"), .commitText("‘")),
        ("topCenter", .swipeUpRight, "´", .compose(trigger: "´"), .commitText("’")),
        ("topCenter", .swipeDownLeft, "/", .commitText("/"), .commitText("–")),
        ("topCenter", .swipeDownRight, "\\", .commitText("\\"), .commitText("—")),
        ("topLeft", .tap, "a", .commitText("a"), nil),
        ("topLeft", .swipeRight, "-", .commitText("-"), .commitText("÷")),
        ("topLeft", .swipeUpLeft, "🅒", .cycleAccents, .cycleAccents),
        ("topLeft", .swipeDownLeft, "$", .compose(trigger: "$"), .commitText("¥")),
        ("topLeft", .swipeDownRight, "v", .commitText("v"), .commitText("V")),
        ("topRight", .tap, "i", .commitText("i"), nil),
        ("topRight", .swipeDown, "=", .commitText("="), .commitText("±")),
        ("topRight", .swipeLeft, "?", .commitText("?"), .commitText("¿")),
        ("topRight", .swipeUpRight, "", .commitText("\n"), .commitText("\n")),
        ("topRight", .swipeDownLeft, "x", .commitText("x"), .commitText("X")),
        ("topRight", .swipeDownRight, "€", .commitText("€"), .commitText("£")),
]

struct NothingMovedTests {
    /// Rows whose *return swipe* changed on purpose. The key, direction, hint and
    /// main action are untouched; what the return swipe types is the same
    /// character when nothing precedes it, and composes when a letter does.
    private static let knownChanges: [String: KeyAction?] = [
        // `¨`'s return swipe was the plain character `˝`; it is now the dead key
        // that makes ő and ű (and still types `˝` after anything else).
        "bottomLeft.swipeUp": .compose(trigger: "˝"),
    ]

    @Test func everyShippedEnglishBindingIsStillWhereItWas() throws {
        let definition = try #require(KeyboardRegistry.load(id: "en_US"))
        let main = try #require(definition.mode(ModeNames.main))
        var checked = 0
        for (keyId, gesture, label, action, returnAction) in englishBindingsBeforeParity {
            let binding = try #require(main.keys[keyId]?.bindings[gesture], "\(keyId).\(gesture) is gone")
            #expect(binding.label == label, "\(keyId).\(gesture) label")
            #expect(binding.action == action, "\(keyId).\(gesture) action")
            let expectedReturn = Self.knownChanges["\(keyId).\(gesture.rawValue)"] ?? returnAction
            #expect(binding.returnAction == expectedReturn, "\(keyId).\(gesture) return swipe")
            checked += 1
        }
        #expect(checked == englishBindingsBeforeParity.count)
        #expect(checked == 67)
    }

    @Test func theSameHoldsForEveryOtherLatinLayoutsLetters() throws {
        // Language overrides replace the shared defaults, so a new default can
        // never displace a letter: every letter a layout binds is still bound.
        for language in KeyboardRegistry.available {
            let definition = try #require(KeyboardRegistry.load(id: language.id))
            let main = try #require(definition.mode(ModeNames.main))
            for (keyId, key) in main.keys where GridSlot.allSlots.joined().contains(keyId) {
                for (gesture, binding) in key.bindings {
                    guard case let .commitText(text) = binding.action, text.first?.isLetter == true else { continue }
                    #expect(binding.label == text, "\(language.id) \(keyId).\(gesture)")
                }
            }
        }
    }
}

// MARK: - Every character Flickboard's English keyboard types

struct FlickboardCharacterCoverageTests {
    /// Every character Flickboard's English layout reaches, transcribed from its
    /// letter layer, shifted letter layer, symbol layer (plain and shifted), mini
    /// numbers layer and numeric layers (docs/layout-parity.md, section 3).
    private static let flickboardCharacters: Set<Character> = {
        let letters = "abcdefghijklmnopqrstuvwxyz"
        let digits = "0123456789"
        let symbols = "$…-`^´+!/\\?=€{%([˛_})]|@~¨<ˇ*\"',.:&°#>;"
        let shifted = "¥•÷‘˘’×¡–—¿±£‰¬¶ª˜˝‹†«“”‚„§º›¸»"
        return Set(letters + letters.uppercased() + digits + symbols + shifted + " \n\t")
    }()

    /// What the layout can put in the document with one gesture (possibly after
    /// a mode switch): committed text on any gesture's action or return swipe in
    /// any mode, and the plain text of a dead key.
    private static func producible(by definition: KeyboardDefinition) -> Set<Character> {
        var out = Set<Character>()
        func add(_ action: KeyAction?) {
            switch action {
            case let .commitText(text)?: out.formUnion(text)
            case let .compose(trigger)?: out.formUnion(ComposeMiddleware.plainText(for: trigger))
            case .space?: out.insert(" ")
            case .newline?: out.insert("\n")
            case .tab?: out.insert("\t")
            default: break
            }
        }
        for (_, mode) in definition.modes {
            for (_, key) in mode.keys {
                for (_, binding) in key.bindings {
                    add(binding.action)
                    add(binding.returnAction)
                }
            }
        }
        return out
    }

    @Test func everyCharacterFlickboardTypesIsReachableInEnglish() throws {
        let definition = try #require(KeyboardRegistry.load(id: "en_US"))
        let reachable = Self.producible(by: definition)
        let missing = Self.flickboardCharacters.subtracting(reachable).sorted()
        #expect(missing.isEmpty, "Flickboard types these but Wurstfinger English cannot: \(missing)")
        #expect(Self.flickboardCharacters.count > 130)
    }

    @Test func theTranscriptionHoldsTheCharactersTheGapsWereMeasuredOn() {
        // The ones missing before the parity work, so the test above is known to
        // have bitten: a bullet, both guillemets, the low-9 quote, and the dead
        // keys that had no key.
        for character in "•«»‚˘˛¸" {
            #expect(Self.flickboardCharacters.contains(character), "\(character)")
        }
    }
}

// MARK: - The new bindings

struct ParityBindingTests {
    private func binding(_ keyId: String, _ gesture: GestureType, mode: String = ModeNames.main) throws -> KeyBinding {
        let definition = try #require(KeyboardRegistry.load(id: "en_US"))
        return try #require(definition.mode(mode)?.keys[keyId]?.bindings[gesture], "\(keyId).\(gesture)")
    }

    @Test func theSymbolsFlickboardHasAndWurstfingerLackedAreBound() throws {
        let ellipsis = try binding(GridSlot.topLeft, .swipeDown)
        #expect(ellipsis.action == .commitText("…") && ellipsis.returnAction == .commitText("•"))

        let breve = try binding(GridSlot.topLeft, .swipeUpRight)
        #expect(breve.action == .compose(trigger: "˘") && breve.returnAction == .commitText("‚"))

        let ogonek = try binding(GridSlot.midLeft, .swipeDown)
        #expect(ogonek.action == .compose(trigger: "˛") && ogonek.returnAction == .compose(trigger: "¯"))

        let caron = try binding(GridSlot.bottomLeft, .swipeDownLeft)
        #expect(caron.action == .compose(trigger: "ˇ") && caron.returnAction == .commitText("«"))

        let cedilla = try binding(GridSlot.bottomLeft, .swipeDown)
        #expect(cedilla.action == .compose(trigger: "¸") && cedilla.returnAction == .commitText("»"))
    }

    @Test func theLineJumpsSitWhereFlickboardPutsThem() throws {
        #expect(try binding(GridSlot.topRight, .swipeUp).action == .lineUp)
        #expect(try binding(GridSlot.bottomRight, .swipeDown).action == .lineDown)
    }

    @Test func theWordCaseStepDownRidesTheLowercaseReturnSwipeInEveryMode() throws {
        for mode in [ModeNames.main, ModeNames.shifted, ModeNames.capsLock] {
            let lowercase = try binding(GridSlot.midRight, .swipeDown, mode: mode)
            #expect(lowercase.returnAction == .cycleWordCase(ascending: false), "\(mode)")
        }
        // Hidden in main (its tap is a no-op there), shown in the others.
        #expect(try binding(GridSlot.midRight, .swipeDown).label == "")
        #expect(try binding(GridSlot.midRight, .swipeDown, mode: ModeNames.shifted).label == "⇩")
    }

    @Test func theUtilityKeysGainTheirGestures() throws {
        #expect(try binding(UtilitySlot.globe, .swipeUp).action == .switchToPreviousLanguage)
        #expect(try binding(UtilitySlot.return, .swipeLeft).action == .deleteWordBackward)
        #expect(try binding(UtilitySlot.return, .swipeRight).action == .deleteWordForward)
        #expect(try binding(UtilitySlot.symbols, .swipeUpLeft).action == .switchMode(ModeNames.control))
        #expect(try binding(UtilitySlot.symbols, .swipeLeft).action == .switchMode(ModeNames.alt))
        #expect(try binding(UtilitySlot.symbols, .swipeDownLeft).action == .toggleUtilityColumnSide)
    }

    @Test func theLetterGridKeepsItsVoiceOverPolicy() throws {
        // The new grid bindings are unnamed on purpose: only `, . ? ⇧ ⇩` are named
        // (see `CommonKeys.defaultSlotBindings`).
        #expect(try binding(GridSlot.topRight, .swipeUp).accessibilityLabel == nil)
        #expect(try binding(GridSlot.bottomRight, .swipeDown).accessibilityLabel == nil)
    }

    @Test func theNewActionsRoundTripThroughCodable() throws {
        let actions: [KeyAction] = [
            .switchToPreviousLanguage, .toggleUtilityColumnSide, .lineUp, .lineDown,
            .deleteWordForward, .cycleWordCase(ascending: true), .cycleWordCase(ascending: false),
        ]
        for action in actions {
            let data = try JSONEncoder().encode(action)
            #expect(try JSONDecoder().decode(KeyAction.self, from: data) == action)
        }
    }
}

// MARK: - Dead keys

@Suite(.serialized)
@MainActor
struct DeadKeyParityTests {
    @Test func theNewDeadKeysComposeWithTheLettersFlickboardComposesThemWith() {
        let engine = ComposeEngine.shared
        let expected: [(String, String, String)] = [
            ("¯", "a", "ā"), ("¯", "E", "Ē"), ("¯", "y", "ȳ"),
            ("˛", "a", "ą"), ("˛", "e", "ę"), ("˛", "u", "ų"),
            ("¸", "s", "ş"), ("¸", "t", "ţ"), ("¸", "c", "ç"), ("¸", "g", "ģ"),
            ("˝", "o", "ő"), ("˝", "U", "Ű"),
            ("ˇ", "a", "ǎ"), ("ˇ", "u", "ǔ"), ("ˇ", "g", "ǧ"),
            ("˘", "ạ", "ặ"),
        ]
        for (trigger, base, result) in expected {
            #expect(engine.compose(previous: base, trigger: trigger) == result, "\(trigger) + \(base)")
        }
    }

    @Test func theAccentCyclesAreExactlyWhatTheyWereBeforeTheNewRules() {
        // The Unicode-derived rules compose; they must not reorder the 🅒 cycle.
        let before = ComposeEngine(ruleSet: .global)
        var compared = 0
        for (_, table) in ComposeRuleSet.global.rules {
            for (base, result) in table {
                for character in [base, result] where character != " " {
                    #expect(
                        ComposeEngine.shared.cycleAccent(for: character) == before.cycleAccent(for: character),
                        "cycle for \(character)"
                    )
                    compared += 1
                }
            }
        }
        #expect(compared > 400)
    }

    @Test func theNewRulesNeverShadowAHandWrittenOne() {
        for (trigger, table) in ComposeRuleSet.unicodeMarks.rules {
            for (base, result) in table {
                let existing = ComposeRuleSet.global.rules[trigger]?[base]
                #expect(existing == nil, "\(trigger) + \(base) is in both tables (\(existing ?? "") vs \(result))")
            }
        }
    }

    @Test func everyRuleIsASingleCodePointComposition() {
        for (trigger, table) in ComposeRuleSet.unicodeMarks.rules {
            for (base, result) in table {
                #expect(result.unicodeScalars.count == 1, "\(trigger) + \(base)")
                #expect(base.unicodeScalars.count == 1, "\(trigger) + \(base)")
            }
        }
    }

    @Test func theGraveKeyTypesTheAsciiGraveWhenNothingComposes() {
        // The trigger is U+02CB internally; the key shows (and a keyboard is
        // expected to type) U+0060.
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        scenario.swipe(GridSlot.topCenter, .swipeUpLeft)
        #expect(scenario.text == "`")
        #expect(scenario.text.unicodeScalars.map(\.value) == [0x60])
        scenario.type("e")
        scenario.swipe(GridSlot.topCenter, .swipeUpLeft)
        #expect(scenario.text == "`è", "after a letter it still composes")
    }

    @Test func aDeadKeyTypedOnItsOwnStillTypesItself() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        scenario.swipe(GridSlot.midLeft, .swipeDown)
        #expect(scenario.text == "˛")
    }

    @Test func typingALetterThenTheDeadKeyComposes() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        scenario.tap(GridSlot.topLeft)           // a
        scenario.swipe(GridSlot.midLeft, .swipeDown)  // ˛
        #expect(scenario.text == "ą")
        scenario.tap(GridSlot.topLeft)           // a
        scenario.returnSwipe(GridSlot.midLeft, .swipeDown)  // ¯
        #expect(scenario.text == "ąā")
        scenario.swipe(GridSlot.center, .swipeUp)           // u
        scenario.swipe(GridSlot.bottomLeft, .swipeUp)       // ¨ (the double acute is its return swipe)
        #expect(scenario.text == "ąāü")
        scenario.tap(GridSlot.center)                       // o
        scenario.returnSwipe(GridSlot.bottomLeft, .swipeUp) // ˝
        #expect(scenario.text == "ąāüő")
    }
}

// MARK: - The terminal modifiers

@Suite(.serialized)
@MainActor
struct TerminalModifierTests {
    private func scenario() -> KeyboardScenario {
        KeyboardScenario(language: "en_US", autoCapitalize: false)
    }

    @Test func controlCodesFollowTheTerminalConvention() {
        let table: [(Unicode.Scalar, UInt32?)] = [
            ("a", 0x01), ("c", 0x03), ("z", 0x1A), ("C", 0x03), ("[", 0x1B), ("\\", 0x1C),
            ("]", 0x1D), ("^", 0x1E), ("_", 0x1F), ("?", 0x7F), ("@", nil), (" ", nil), ("1", nil),
        ]
        for (scalar, code) in table {
            #expect(TerminalModifier.controlCharacter(for: scalar)?.value == code, "\(scalar)")
        }
    }

    @Test func altPrefixesEscapeAndRefusesControlText() {
        #expect(TerminalModifier.alt.transformed("f") == "\u{1B}f")
        #expect(TerminalModifier.alt.transformed("1") == "\u{1B}1")
        #expect(TerminalModifier.alt.transformed("\t") == nil)
        #expect(TerminalModifier.alt.transformed("") == nil)
        #expect(TerminalModifier.control.transformed("é") == nil)
    }

    @Test func swipingUpLeftOnTheNumbersKeyArmsCtrlForOneKey() {
        let scenario = scenario()
        scenario.swipe(UtilitySlot.symbols, .swipeUpLeft)
        #expect(scenario.mode == ModeNames.control)
        scenario.swipe(GridSlot.center, .swipeLeft)   // c
        #expect(scenario.text == "\u{03}")
        #expect(scenario.mode == ModeNames.main, "one key, then back")
        scenario.tap(GridSlot.topLeft)
        #expect(scenario.text == "\u{03}a")
    }

    @Test func ctrlOnTheGridTypesTheControlCodesTerminalsExpect() {
        let scenario = scenario()
        func ctrl(_ keyId: String, _ gesture: GestureType) {
            scenario.swipe(UtilitySlot.symbols, .swipeUpLeft)
            if gesture == .tap { scenario.tap(keyId) } else { scenario.swipe(keyId, gesture) }
        }
        ctrl(GridSlot.topLeft, .tap)              // a
        ctrl(GridSlot.midLeft, .swipeDownLeft)    // [ is ESC
        ctrl(GridSlot.topCenter, .swipeUp)        // ^ is RS
        #expect(scenario.text == "\u{01}\u{1B}\u{1E}")
    }

    @Test func altPrefixesTheNextKeyWithEscape() {
        let scenario = scenario()
        scenario.swipe(UtilitySlot.symbols, .swipeLeft)
        #expect(scenario.mode == ModeNames.alt)
        scenario.swipe(GridSlot.bottomRight, .swipeUpLeft)   // f
        #expect(scenario.text == "\u{1B}f")
        #expect(scenario.mode == ModeNames.main)
    }

    @Test func theKeyThatReplacesNumbersLeavesTheModeWithoutTyping() {
        let scenario = scenario()
        scenario.swipe(UtilitySlot.symbols, .swipeUpLeft)
        scenario.tap(UtilitySlot.symbols)
        #expect(scenario.mode == ModeNames.main)
        #expect(scenario.text.isEmpty)
    }

    @Test func anAccentKeyIsInertUnderTheModifierAndDoesNotFallThroughToTheNumbers() throws {
        // A binding the modifier cannot act on is inert, not absent: an absent one
        // would fall through to the numeric mode's binding on the same gesture.
        let definition = try #require(KeyboardRegistry.load(id: "en_US"))
        for name in [ModeNames.control, ModeNames.alt] {
            let mode = try #require(definition.mode(name))
            let accent = try #require(mode.keys[GridSlot.topCenter]?.bindings[.swipeUpRight])
            #expect(accent.action == .none, "\(name): the acute dead key is inert")
        }
        let scenario = scenario()
        scenario.swipe(UtilitySlot.symbols, .swipeUpLeft)
        scenario.swipe(GridSlot.topCenter, .swipeUpRight)
        #expect(scenario.text.isEmpty)
    }

    @Test func theModesExistOnlyWhereTheLettersAreLatin() throws {
        let english = try #require(KeyboardRegistry.load(id: "en_US"))
        #expect(english.mode(ModeNames.control) != nil && english.mode(ModeNames.alt) != nil)
        let russian = try #require(KeyboardRegistry.load(id: "ru_RU"))
        #expect(russian.mode(ModeNames.control) == nil && russian.mode(ModeNames.alt) == nil)
        #expect(russian.mode(ModeNames.main)?.keys[UtilitySlot.symbols]?.bindings[.swipeUpLeft] == nil)
    }

    @Test func everyLayoutWithTheModesValidates() throws {
        for language in KeyboardRegistry.available {
            let definition = try #require(KeyboardRegistry.load(id: language.id))
            #expect(definition.validate().isEmpty, "\(language.id)")
        }
    }

    @Test func theLongSwipeChoicesReachTheModesToo() {
        let scenario = KeyboardScenario(
            language: "en_US", autoCapitalize: false,
            settings: [
                .expertModeEnabled: true, .isLongSwipeEnabled: true,
                .longSwipeUpRight: LongSwipeAction.control.rawValue,
                .longSwipeUpLeft: LongSwipeAction.alt.rawValue,
                .longSwipeDownLeft: LongSwipeAction.shiftOn.rawValue,
                .longSwipeDownRight: LongSwipeAction.shiftOff.rawValue,
            ]
        )
        scenario.swipe(GridSlot.center, .swipeUpRight, fraction: 2)
        #expect(scenario.mode == ModeNames.control)
        scenario.swipe(GridSlot.center, .swipeUpLeft, fraction: 2)
        #expect(scenario.mode == ModeNames.alt)
        scenario.swipe(UtilitySlot.symbols, .swipeDownLeft, fraction: 2)
        #expect(scenario.mode == ModeNames.shifted)
        scenario.swipe(GridSlot.center, .swipeDownRight, fraction: 2)
        #expect(scenario.mode == ModeNames.main)
    }
}

// MARK: - Editing actions

@Suite(.serialized)
@MainActor
struct ParityEditingTests {
    private func scenario(_ text: String, cursorBack: Int = 0) -> KeyboardScenario {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        scenario.target.reset(to: text)
        if cursorBack > 0 { scenario.target.adjustTextPosition(byCharacterOffset: -cursorBack) }
        return scenario
    }

    // Line up / down

    @Test func lineOffsetsKeepTheColumn() {
        // "one\ntwo three\nx", cursor after "two t" (column 5 of line 2).
        let before = "one\ntwo t"
        let after = "hree\nx"
        // Up onto "one" (3 characters): column 5 is clamped to its end, so the
        // cursor crosses "t", "w", "o", " ", "t" and the break: 6 units.
        #expect(AdvancedTextMiddleware.lineJumpOffset(up: true, before: before, after: after) == -6)
    }

    @Test func lineUpLandsAtTheSameColumnOrTheEndOfAShorterLine() {
        // Column 5 up onto a 3-character line: lands at its end.
        #expect(AdvancedTextMiddleware.lineJumpOffset(up: true, before: "abc\nxy123", after: "") == -(5 + 1))
        // Column 2 up onto a long line: two characters in.
        #expect(AdvancedTextMiddleware.lineJumpOffset(up: true, before: "abcdef\nxy", after: "") == -(2 + 1 + 4))
        // Column 0 (just after the break) up: to the line start.
        #expect(AdvancedTextMiddleware.lineJumpOffset(up: true, before: "abc\n", after: "z") == -4)
    }

    @Test func lineDownLandsAtTheSameColumnOrTheEndOfAShorterLine() {
        // Column 3 on "abcdef", down onto "xy": its end, 2 in.
        #expect(AdvancedTextMiddleware.lineJumpOffset(up: false, before: "abc", after: "def\nxy") == 3 + 1 + 2)
        // Down onto a longer line: three in.
        #expect(AdvancedTextMiddleware.lineJumpOffset(up: false, before: "abc", after: "\nwxyz") == 0 + 1 + 3)
        // Cursor at the very end of the line, next line empty.
        #expect(AdvancedTextMiddleware.lineJumpOffset(up: false, before: "ab", after: "\n\nq") == 1)
    }

    @Test func noLineInThatDirectionIsNil() {
        #expect(AdvancedTextMiddleware.lineJumpOffset(up: true, before: "only line", after: "") == nil)
        #expect(AdvancedTextMiddleware.lineJumpOffset(up: false, before: "", after: "only line") == nil)
    }

    @Test func columnsAndDistancesCountClustersAndUTF16Units() {
        // An emoji is one column but two UTF-16 units.
        // Column 2 (c, 😀) onto "a😀b" (3 clusters): lands before "b", having
        // crossed b (1), the break (1), c (1) and 😀 (2).
        #expect(AdvancedTextMiddleware.lineJumpOffset(up: true, before: "a😀b\nc😀", after: "") == -5)
    }

    @Test func swipingOnTheLineKeysMovesTheCursor() {
        let scenario = scenario("alpha\nbeta gamma\nom", cursorBack: 0)
        // Cursor at the end of "om" (column 2 of line 3): up → 2 into "beta gamma".
        scenario.swipe(GridSlot.topRight, .swipeUp)
        #expect(scenario.cursor == 6 + 2)
        // Down again: two columns into "om" (its end).
        scenario.swipe(GridSlot.bottomRight, .swipeDown)
        #expect(scenario.cursor == scenario.text.count)
        // Up twice from there: the second goes to "alpha", column 2.
        scenario.swipe(GridSlot.topRight, .swipeUp)
        scenario.swipe(GridSlot.topRight, .swipeUp)
        #expect(scenario.cursor == 2)
        #expect(scenario.text == "alpha\nbeta gamma\nom", "moving never edits")
    }

    @Test func onTheFirstLineUpGoesToTheStartAndOnTheLastDownToTheEnd() {
        let scenario = scenario("one two", cursorBack: 3)
        scenario.swipe(GridSlot.topRight, .swipeUp)
        #expect(scenario.cursor == 0)
        scenario.swipe(GridSlot.bottomRight, .swipeDown)
        #expect(scenario.cursor == scenario.text.count)
    }

    // Delete word ahead

    @Test func deleteWordForwardRemovesTheNextWordAndTheSpaceBeforeIt() {
        let scenario = scenario("one two three", cursorBack: 10)   // after "one"
        scenario.swipe(UtilitySlot.return, .swipeRight)
        #expect(scenario.text == "one three")
        #expect(scenario.cursor == 3)
    }

    @Test func deleteWordForwardOnAWordStartTakesThatWord() {
        let scenario = scenario("one two", cursorBack: 3)
        scenario.swipe(UtilitySlot.return, .swipeRight)
        #expect(scenario.text == "one ")
    }

    @Test func deleteWordForwardAtTheEndDoesNothing() {
        let scenario = scenario("one two")
        scenario.swipe(UtilitySlot.return, .swipeRight)
        #expect(scenario.text == "one two")
    }

    @Test func deleteWordBackwardOnTheReturnKey() {
        let scenario = scenario("one two")
        scenario.swipe(UtilitySlot.return, .swipeLeft)
        #expect(scenario.text == "one ")
    }

    @Test func wordSpanSkipsLeadingWhitespaceThenTheWord() {
        #expect(AdvancedTextMiddleware.wordSpan(startingAt: "  ab cd").clusters == 4)
        #expect(AdvancedTextMiddleware.wordSpan(startingAt: "😀x y").utf16Length == 3)
        #expect(AdvancedTextMiddleware.wordSpan(startingAt: "").clusters == 0)
    }

    // Word case

    @Test func theLowercaseReturnSwipeStepsTheWordDownUntilItIsLowercase() {
        let scenario = scenario("say HELLO")
        func down() { scenario.returnSwipe(GridSlot.midRight, .swipeDown) }
        down()
        #expect(scenario.text == "say Hello")
        down()
        #expect(scenario.text == "say hello")
        down()
        #expect(scenario.text == "say hello", "a step past the end does nothing")
    }

    @Test func mixedCaseStepsToTitleDownAndUpperUp() {
        let target = MockTextTarget()
        target.documentContextBeforeInput = "say hELLo"
        let middleware = AdvancedTextMiddleware(target: { target }, locale: { Locale(identifier: "en_US") })
        middleware.process(ActionContext(action: .cycleWordCase(ascending: false), binding: nil, mode: "main")) { _ in }
        #expect(target.documentContextBeforeInput == "say Hello")

        target.documentContextBeforeInput = "say hELLo"
        middleware.process(ActionContext(action: .cycleWordCase(ascending: true), binding: nil, mode: "main")) { _ in }
        #expect(target.documentContextBeforeInput == "say HELLO")
    }

    @Test func ascendingStepsLowerToTitleToUpper() {
        let target = MockTextTarget()
        target.documentContextBeforeInput = "hello"
        let middleware = AdvancedTextMiddleware(target: { target }, locale: { Locale(identifier: "en_US") })
        func up() { middleware.process(ActionContext(action: .cycleWordCase(ascending: true), binding: nil, mode: "main")) { _ in } }
        up()
        #expect(target.documentContextBeforeInput == "Hello")
        up()
        #expect(target.documentContextBeforeInput == "HELLO")
        up()
        #expect(target.documentContextBeforeInput == "HELLO")
    }

    @Test func aSelectionIsSteppedAsAWhole() {
        let target = MockTextTarget()
        target.selectedText = "two words"
        let middleware = AdvancedTextMiddleware(target: { target }, locale: { Locale(identifier: "en_US") })
        middleware.process(ActionContext(action: .cycleWordCase(ascending: true), binding: nil, mode: "main")) { _ in }
        #expect(target.events == [.insertText("Two words")])
    }

    @Test func noWordMeansNoChange() {
        let target = MockTextTarget()
        target.documentContextBeforeInput = "123 "
        let middleware = AdvancedTextMiddleware(target: { target }, locale: { Locale(identifier: "en_US") })
        middleware.process(ActionContext(action: .cycleWordCase(ascending: true), binding: nil, mode: "main")) { _ in }
        #expect(target.events.isEmpty)
    }

    // The new actions are text-neutral where the policies say so

    @Test func theNewActionsFollowTheCapitalizationAndInputPolicies() {
        #expect(AutoCapitalizationMiddleware.affectsCapitalization(.deleteWordForward))
        for action in [KeyAction.lineUp, .lineDown, .cycleWordCase(ascending: true),
                       .switchToPreviousLanguage, .toggleUtilityColumnSide] {
            #expect(!AutoCapitalizationMiddleware.affectsCapitalization(action))
        }
        let target = MockTextTarget()
        let middleware = TextInputMiddleware(target: { target })
        for action in [KeyAction.lineUp, .lineDown, .deleteWordForward, .cycleWordCase(ascending: true),
                       .switchToPreviousLanguage, .toggleUtilityColumnSide] {
            middleware.process(ActionContext(action: action, binding: nil, mode: "main")) { _ in }
        }
        #expect(target.events.isEmpty)
    }
}

// MARK: - Copy with nothing selected

@Suite(.serialized)
@MainActor
struct CopyAllTests {
    private func run(
        before: String?, after: String?, selected: String? = nil, fullAccess: Bool = true
    ) -> (clipboard: String?, ticks: Int) {
        let target = MockTextTarget()
        target.documentContextBeforeInput = before
        target.documentContextAfterInput = after
        target.selectedText = selected
        target.hasFullAccess = fullAccess
        let clipboard = MemoryClipboard()
        var ticks = 0
        let middleware = AdvancedTextMiddleware(
            target: { target }, locale: { Locale(identifier: "en_US") },
            onClipboardSuccess: { ticks += 1 }, clipboard: clipboard
        )
        middleware.process(ActionContext(action: .copy, binding: nil, mode: "main")) { _ in }
        return (clipboard.string, ticks)
    }

    @Test func copyWithNothingSelectedCopiesTheTextAroundTheCursor() {
        let result = run(before: "hello ", after: "world")
        #expect(result.clipboard == "hello world")
        #expect(result.ticks == 1)
    }

    @Test func aSelectionStillWinsOverTheSurroundingText() {
        let result = run(before: "a ", after: " d", selected: "bc")
        #expect(result.clipboard == "bc")
    }

    @Test func anEmptyDocumentOrMissingFullAccessCopiesNothing() {
        #expect(run(before: "", after: "").clipboard == nil)
        #expect(run(before: nil, after: nil).clipboard == nil)
        #expect(run(before: "hello", after: "", fullAccess: false).clipboard == nil)
        #expect(run(before: "hello", after: "").ticks == 1)
    }

    @Test func aDocumentPastTheSizeCeilingIsNotCopied() {
        let huge = String(repeating: "x", count: KeyboardConstants.TextInput.maxPasteUTF16Length + 1)
        #expect(run(before: huge, after: "").clipboard == nil)
    }
}

// MARK: - Languages and mirroring

@Suite(.serialized)
@MainActor
struct ParityNavigationTests {
    @Test func previousLanguageWalksTheRingBackwards() {
        let ids = ["en_US", "de_DE", "fr_FR"]
        #expect(LanguageSettings.previousLanguageId(before: "en_US", in: ids) == "fr_FR")
        #expect(LanguageSettings.previousLanguageId(before: "de_DE", in: ids) == "en_US")
        #expect(LanguageSettings.previousLanguageId(before: "xx", in: ids) == "fr_FR")
        #expect(LanguageSettings.previousLanguageId(before: "en_US", in: ["en_US"]) == "en_US")
        // The two directions are inverses.
        for id in ids {
            let next = LanguageSettings.nextLanguageId(after: id, in: ids)
            #expect(LanguageSettings.previousLanguageId(before: next, in: ids) == id)
        }
    }

    @Test func swipingUpOnTheGlobeGoesToThePreviousLanguage() {
        let scenario = KeyboardScenario(
            language: "de_DE", autoCapitalize: false,
            settings: [.enabledLanguageIds: ["en_US", "de_DE", "fr_FR"]]
        )
        scenario.swipe(UtilitySlot.globe, .swipeUp)
        #expect(scenario.viewModel.currentDefinition?.id == "en_US")
        scenario.swipe(UtilitySlot.globe, .swipeUp)
        #expect(scenario.viewModel.currentDefinition?.id == "fr_FR")
        scenario.swipe(UtilitySlot.globe, .swipeRight)
        #expect(scenario.viewModel.currentDefinition?.id == "en_US")
    }

    @Test func swipingDownLeftOnTheNumbersKeyMirrorsTheKeyboard() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        #expect(!scenario.viewModel.utilityColumnLeading)
        scenario.swipe(UtilitySlot.symbols, .swipeDownLeft)
        #expect(scenario.viewModel.utilityColumnLeading)
        #expect(scenario.viewModel.currentContext == .portraitUtilityLeft)
        scenario.swipe(UtilitySlot.symbols, .swipeDownLeft)
        #expect(!scenario.viewModel.utilityColumnLeading)
    }
}
