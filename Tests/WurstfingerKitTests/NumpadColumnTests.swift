//
//  NumpadColumnTests.swift
//  WurstfingerTests
//
//  The always-available numpad column: its keys (digits in the layout's own
//  script, symbols by position), where its arrangement puts it beside the
//  letters and the utility column, which modes carry it, and that a definition
//  with it compiles to tables that type the digits.
//

import CoreGraphics
import Foundation
import Testing
@testable import WurstfingerKit

// MARK: - Keys

struct NumpadColumnKeyTests {
    private let gestures: [GestureType] = [.tap] + GestureType.allCases.filter(\.isSwipe)

    @Test func phoneStyleReadsOneTwoThreeOnTop() {
        let rows = NumpadColumn.rows(digits: NumericLayouts.westernDigits, style: .phone)
        #expect(rows == [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], [",", "0", "."]])
    }

    @Test func classicStyleReadsSevenEightNineOnTop() {
        let rows = NumpadColumn.rows(digits: NumericLayouts.westernDigits, style: .classic)
        #expect(rows == [["7", "8", "9"], ["4", "5", "6"], ["1", "2", "3"], [",", "0", "."]])
    }

    @Test func nativeDigitSetsAreUsed() {
        let arabic = NumpadColumn.rows(digits: NumericLayouts.arabicIndicDigits, style: .phone)
        #expect(arabic[0] == ["١", "٢", "٣"])
        #expect(arabic[3][1] == "٠")
        let devanagari = NumpadColumn.rows(digits: NumericLayouts.devanagariDigits, style: .classic)
        #expect(devanagari[0] == ["७", "८", "९"])
        let thai = NumpadColumn.rows(digits: NumericLayouts.thaiDigits, style: .phone)
        #expect(thai[1] == ["๔", "๕", "๖"])
    }

    @Test func aMalformedDigitSetFallsBackToWestern() {
        let rows = NumpadColumn.rows(digits: ["a"], style: .phone)
        #expect(rows[0] == ["1", "2", "3"])
    }

    @Test func eachKeyCarriesThreeDigitsAndSixSymbols() {
        let keys = NumpadColumn.keys(digits: NumericLayouts.westernDigits, style: .phone)
        #expect(Set(keys.keys) == Set(NumpadColumn.keyIds))
        for id in NumpadColumn.keyIds {
            let key = keys[id]
            #expect(key?.style == .numpad)
            #expect(key?.swipeMode == .eightWay)
            // Tap, eight swipes: nothing unbound, nothing circular or held.
            for gesture in gestures {
                #expect(key?.bindings[gesture] != nil, "\(id) has no \(gesture)")
            }
            #expect(key?.bindings[.circularClockwise] == nil)
            #expect(key?.bindings[.longPress] == nil)
        }
    }

    @Test func tapIsTheMiddleDigitAndSwipesTypeTheSides() throws {
        let keys = NumpadColumn.keys(digits: NumericLayouts.westernDigits, style: .phone)
        let second = try #require(keys[NumpadColumn.keyIds[1]])
        #expect(second.bindings[.swipeLeft]?.action == .commitText("4"))
        #expect(second.bindings[.tap]?.action == .commitText("5"))
        #expect(second.bindings[.swipeRight]?.action == .commitText("6"))
        // The digits are drawn exactly as they are typed.
        #expect(second.bindings[.tap]?.label == "5")
    }

    @Test func digitsAreDigitsAndSymbolsAreSymbols() throws {
        let keys = NumpadColumn.keys(digits: NumericLayouts.westernDigits, style: .phone)
        let top = try #require(keys[NumpadColumn.keyIds[0]])
        #expect(top.bindings[.tap]?.resolvedCategory == .digit)
        #expect(top.bindings[.swipeUp]?.resolvedCategory == .symbol)
        // The bottom row's comma and full stop are punctuation, not digits.
        let bottom = try #require(keys[NumpadColumn.keyIds[3]])
        #expect(bottom.bindings[.swipeLeft]?.action == .commitText(","))
        #expect(bottom.bindings[.swipeLeft]?.resolvedCategory == .symbol)
        #expect(bottom.bindings[.swipeRight]?.action == .commitText("."))
    }

    @Test func theMinusIsDrawnTypographicallyAndTypedAsAHyphen() throws {
        let keys = NumpadColumn.keys(digits: NumericLayouts.westernDigits, style: .phone)
        let top = try #require(keys[NumpadColumn.keyIds[0]])
        #expect(top.bindings[.swipeDown]?.label == "\u{2212}")
        #expect(top.bindings[.swipeDown]?.action == .commitText("-"))
    }

    @Test func theSymbolSetIsByPositionNotByStyle() {
        let phone = NumpadColumn.keys(digits: NumericLayouts.westernDigits, style: .phone)
        let classic = NumpadColumn.keys(digits: NumericLayouts.westernDigits, style: .classic)
        for id in NumpadColumn.keyIds {
            for gesture in [GestureType.swipeUp, .swipeDown, .swipeUpLeft, .swipeUpRight, .swipeDownLeft, .swipeDownRight] {
                #expect(phone[id]?.bindings[gesture] == classic[id]?.bindings[gesture])
            }
        }
    }

    @Test func everySymbolIsTypableAndNoRowRepeatsOne() {
        for row in NumpadColumn.symbols {
            #expect(row.count == 6)
            #expect(Set(row.values).count == 6, "a row repeats a symbol: \(row)")
        }
        let all = NumpadColumn.symbols.flatMap(\.values)
        // Spec: the common math and currency marks are all there.
        for symbol in ["+", "\u{2212}", "×", "÷", "=", "%", "$", "€"] {
            #expect(all.contains(symbol), "\(symbol) is missing")
        }
    }

    /// The tap digit is the key's activation; the side digits and every
    /// symbol are character actions.
    @Test func everyCharacterIsReachableByVoiceOver() throws {
        let keys = NumpadColumn.keys(digits: NumericLayouts.westernDigits, style: .phone)
        let key = try #require(keys[NumpadColumn.keyIds[0]])
        let actions = key.accessibilityActions
        #expect(actions.map(\.name).contains("1, swipe left"))
        #expect(actions.map(\.name).contains("3, swipe right"))
        let reachable = Set(actions.compactMap(\.glyph)).union([key.bindings[.tap]?.action.typedText ?? ""])
        for binding in key.bindings.values {
            let text = try #require(binding.action.typedText)
            #expect(reachable.contains(text), "\(binding.label) is unreachable")
        }
    }

    @Test func isNumpadKeyRecognizesTheIds() {
        #expect(NumpadColumn.keyIds.allSatisfy(NumpadColumn.isNumpadKey))
        #expect(!NumpadColumn.isNumpadKey(GridSlot.topLeft))
    }
}

// MARK: - Arrangement

struct NumpadColumnArrangementTests {
    private func base(utilityLeading: Bool, numeric: Bool = false) throws -> GridArrangement {
        let table = numeric ? StandardArrangements.numeric3x3 : StandardArrangements.grid3x3
        return try #require(table[utilityLeading ? .portraitUtilityLeft : .portrait])
    }

    /// The key ids of one row, left to right, from the solved cells.
    private func rowOrder(_ arrangement: GridArrangement, row: Int) -> [String] {
        GridLayoutSolver.solve(arrangement)
            .filter { $0.row == row }
            .sorted { $0.column < $1.column }
            .map(\.keyId)
    }

    @Test func offLeavesTheArrangementAlone() throws {
        let plain = try base(utilityLeading: false)
        #expect(plain.addingNumpadColumn(.off, keyIds: NumpadColumn.keyIds) == plain)
    }

    @Test func trailingSitsBetweenTheLettersAndTheUtilityKeys() throws {
        let arrangement = try base(utilityLeading: false)
            .addingNumpadColumn(.trailing, keyIds: NumpadColumn.keyIds)
        #expect(arrangement.columns == 5)
        #expect(rowOrder(arrangement, row: 0) == [
            GridSlot.topLeft, GridSlot.topCenter, GridSlot.topRight, "numpad0", UtilitySlot.globe,
        ])
        // Beside the space bar in the bottom row.
        #expect(rowOrder(arrangement, row: 3) == [UtilitySlot.space, "numpad3", UtilitySlot.return])
    }

    @Test func leadingIsTheKeyboardsLeftEdgeWithUtilityKeysOnTheRight() throws {
        let arrangement = try base(utilityLeading: false)
            .addingNumpadColumn(.leading, keyIds: NumpadColumn.keyIds)
        #expect(rowOrder(arrangement, row: 1) == [
            "numpad1", GridSlot.midLeft, GridSlot.center, GridSlot.midRight, UtilitySlot.symbols,
        ])
        #expect(rowOrder(arrangement, row: 3) == ["numpad3", UtilitySlot.space, UtilitySlot.return])
    }

    @Test func theUtilityColumnKeepsItsOuterEdgeWhenItIsOnTheLeft() throws {
        let leading = try base(utilityLeading: true)
            .addingNumpadColumn(.leading, keyIds: NumpadColumn.keyIds)
        #expect(rowOrder(leading, row: 2) == [
            UtilitySlot.delete, "numpad2", GridSlot.bottomLeft, GridSlot.bottomCenter, GridSlot.bottomRight,
        ])
        let trailing = try base(utilityLeading: true)
            .addingNumpadColumn(.trailing, keyIds: NumpadColumn.keyIds)
        #expect(rowOrder(trailing, row: 2) == [
            UtilitySlot.delete, GridSlot.bottomLeft, GridSlot.bottomCenter, GridSlot.bottomRight, "numpad2",
        ])
        #expect(rowOrder(trailing, row: 3) == [UtilitySlot.return, UtilitySlot.space, "numpad3"])
    }

    @Test(arguments: [NumpadColumnPlacement.leading, .trailing], [false, true])
    func everyKeyIsPlacedOnceAndTheGridIsFull(placement: NumpadColumnPlacement, utilityLeading: Bool) throws {
        let plain = try base(utilityLeading: utilityLeading)
        let arrangement = plain.addingNumpadColumn(placement, keyIds: NumpadColumn.keyIds)
        let cells = GridLayoutSolver.solve(arrangement)
        // The plain keys survive and the four numpad keys are added.
        #expect(cells.count == GridLayoutSolver.solve(plain).count + 4)
        #expect(Set(cells.map(\.keyId)).count == cells.count)
        for id in NumpadColumn.keyIds {
            #expect(cells.filter { $0.keyId == id }.count == 1)
        }
        // Every one of the 5 × 4 grid cells is covered exactly once.
        var covered = Set<[Int]>()
        for cell in cells {
            for row in cell.row ..< cell.row + cell.rowSpan {
                for column in cell.column ..< cell.column + cell.columnSpan {
                    #expect(covered.insert([row, column]).inserted, "cell \(row),\(column) is covered twice")
                }
            }
        }
        #expect(covered.count == 5 * 4)
    }

    @Test func theNumpadKeysStackInOneColumn() throws {
        for placement in [NumpadColumnPlacement.leading, .trailing] {
            let cells = GridLayoutSolver.solve(
                try base(utilityLeading: false).addingNumpadColumn(placement, keyIds: NumpadColumn.keyIds)
            )
            let numpad = NumpadColumn.keyIds.compactMap { id in cells.first { $0.keyId == id } }
            #expect(Set(numpad.map(\.column)).count == 1)
            #expect(numpad.map(\.row) == [0, 1, 2, 3])
        }
    }

    @Test func aModeWithoutNumpadKeysReservesTheColumnWithAGap() throws {
        let numeric = try base(utilityLeading: false, numeric: true)
            .addingNumpadColumn(.trailing, keyIds: nil)
        #expect(numeric.columns == 5)
        let cells = GridLayoutSolver.solve(numeric)
        #expect(cells.allSatisfy { !NumpadColumn.isNumpadKey($0.keyId) && $0.keyId != KeyPlacement.gapKeyId })
        // The keys keep the places they have in the letter modes, so the
        // keyboard does not jump when the mode changes: the globe is still in
        // the last column, the third letter column still in column 2.
        #expect(cells.first { $0.keyId == UtilitySlot.globe }?.column == 4)
        #expect(cells.first { $0.keyId == GridSlot.topRight }?.column == 2)
    }

    @Test func utilityKeysSitInTheSameColumnAsWithoutTheNumpadForTheLeadingSide() throws {
        // Trailing numpad: the utility column moves out by one; a leading numpad
        // moves the letters in by one and the utility column too.
        let plain = GridLayoutSolver.solve(try base(utilityLeading: false))
        let leading = GridLayoutSolver.solve(
            try base(utilityLeading: false).addingNumpadColumn(.leading, keyIds: NumpadColumn.keyIds)
        )
        let plainGlobe = try #require(plain.first { $0.keyId == UtilitySlot.globe })
        let leadingGlobe = try #require(leading.first { $0.keyId == UtilitySlot.globe })
        #expect(leadingGlobe.column == plainGlobe.column + 1)
    }
}

// MARK: - Definition

@MainActor
struct NumpadColumnDefinitionTests {
    @Test func addsTheKeysToEveryModeButNumeric() throws {
        let definition = try #require(KeyboardRegistry.load(id: "en_US"))
        let with = definition.addingNumpadColumn(style: .phone)
        for (name, mode) in with.modes {
            let hasKeys = NumpadColumn.keyIds.allSatisfy { mode.keys[$0] != nil }
            #expect(hasKeys == (name != ModeNames.numeric), "mode \(name)")
        }
        // Nothing else changed: same arrangements, same other keys.
        for (name, mode) in with.modes {
            let original = try #require(definition.modes[name])
            #expect(mode.arrangements == original.arrangements)
            for (id, key) in original.keys {
                #expect(mode.keys[id] == key)
            }
        }
    }

    @Test func usesTheLayoutsOwnDigitsAndTheRequestedStyle() throws {
        let arabic = try #require(KeyboardRegistry.load(id: "ar"))
        let with = arabic.addingNumpadColumn(style: .classic)
        let top = try #require(with.mode(ModeNames.main)?.keys[NumpadColumn.keyIds[0]])
        #expect(top.bindings[.swipeLeft]?.label == "٧")
        #expect(top.bindings[.tap]?.label == "٨")
        #expect(top.bindings[.swipeRight]?.label == "٩")
    }

    @Test func aDefinitionWithoutTheColumnStaysExactlyAsItWas() throws {
        let definition = try #require(KeyboardRegistry.load(id: "de_DE"))
        #expect(definition.modes.values.allSatisfy { mode in
            NumpadColumn.keyIds.allSatisfy { mode.keys[$0] == nil }
        })
    }

    @Test func theCompiledTablesResolveTheDigits() throws {
        let definition = try #require(KeyboardRegistry.load(id: "en_US")).addingNumpadColumn(style: .phone)
        let compiled = CompiledDefinition(definition)
        let main = try #require(compiled.mode(ModeNames.main))
        let slot = try #require(main.slot(for: NumpadColumn.keyIds[2]))
        func text(_ gesture: GestureType) -> String? {
            guard let binding = main.binding(slot: slot, gesture: gesture, isReturn: false) else { return nil }
            if case let .commitText(text) = binding.action { return text }
            return nil
        }
        #expect(text(.swipeLeft) == "7")
        #expect(text(.tap) == "8")
        #expect(text(.swipeRight) == "9")
        #expect(text(.swipeUp) == "#")
        // A circle has no meaning on a numpad key and types nothing.
        #expect(main.circular(slot: slot, clockwise: true) == .none)
    }

    @Test func compiledTablesAreCachedSeparatelyFromThePlainDefinition() {
        let plain = KeyboardRegistry.compiledSignature(languageId: "en_US", numpadType: nil)
        let with = KeyboardRegistry.compiledSignature(languageId: "en_US", numpadType: nil, hasNumpadColumn: true)
        #expect(plain == "en_US|phone")
        #expect(with == "en_US|phone|numpad")
        // Eviction by language still reaches both.
        #expect(with.hasPrefix("en_US|"))
    }

    @Test func theDefinitionSignatureTracksOnOffButNotTheSide() {
        let off = KeyboardViewModel.definitionSignature(languageId: "en_US", numpadType: nil)
        #expect(off == KeyboardViewModel.definitionSignature(languageId: "en_US", numpadType: nil, numpadColumn: "off"))
        let leading = KeyboardViewModel.definitionSignature(languageId: "en_US", numpadType: nil, numpadColumn: "leading")
        let trailing = KeyboardViewModel.definitionSignature(languageId: "en_US", numpadType: nil, numpadColumn: "trailing")
        #expect(leading != off)
        #expect(leading == trailing)
        // A stored value nobody wrote is off.
        #expect(KeyboardViewModel.definitionSignature(languageId: "en_US", numpadType: nil, numpadColumn: "sideways") == off)
    }
}

// MARK: - View model

@MainActor
struct NumpadColumnViewModelTests {
    private func makeViewModel(_ settings: [SettingsKey: Any] = [:]) -> KeyboardViewModel {
        let defaults = InMemoryUserDefaults()
        for (key, value) in settings { defaults.set(value, forKey: key.rawValue) }
        let viewModel = KeyboardViewModel(userDefaults: defaults, shouldPersistSettings: false)
        viewModel.loadDefinition(for: "en_US")
        return viewModel
    }

    @Test func offByDefaultAddsNothing() {
        let viewModel = makeViewModel()
        #expect(!viewModel.hasNumpadColumnKeys)
        #expect(viewModel.currentArrangement?.columns == 4)
        #expect(viewModel.loadedDefinitionSignature == "en_US|")
    }

    @Test func onAddsTheKeysAndAFifthColumn() {
        let viewModel = makeViewModel([.numpadColumn: "trailing"])
        #expect(viewModel.hasNumpadColumnKeys)
        #expect(viewModel.currentArrangement?.columns == 5)
        #expect(viewModel.loadedDefinitionSignature == "en_US||numpad")
    }

    @Test func theNumpadStyleSettingOrdersTheColumn() throws {
        let viewModel = makeViewModel([.numpadColumn: "leading", .numpadStyle: "classic"])
        let top = try #require(viewModel.currentDefinition?.mode(ModeNames.main)?.keys[NumpadColumn.keyIds[0]])
        #expect(top.bindings[.tap]?.label == "8")
    }

    @Test func switchingTheColumnOnAndOffReloadsTheDefinitionKeepingTheMode() {
        let viewModel = makeViewModel()
        viewModel.switchToMode(ModeNames.numeric)
        viewModel.numpadColumn = .trailing
        viewModel.reloadDefinitionIfNumpadColumnChanged()
        #expect(viewModel.hasNumpadColumnKeys)
        #expect(viewModel.activeModeName == ModeNames.numeric)

        viewModel.numpadColumn = .off
        viewModel.reloadDefinitionIfNumpadColumnChanged()
        #expect(!viewModel.hasNumpadColumnKeys)
        #expect(viewModel.currentArrangement?.columns == 4)
    }

    @Test func aReloadThatChangedNothingLeavesTheDefinitionAlone() {
        let viewModel = makeViewModel([.numpadColumn: "leading"])
        let before = viewModel.loadedDefinitionSignature
        viewModel.reloadDefinitionIfNumpadColumnChanged()
        #expect(viewModel.loadedDefinitionSignature == before)
    }

    @Test func theNumericModeKeepsTheFiveColumnsWithAnEmptyOne() {
        let viewModel = makeViewModel([.numpadColumn: "trailing"])
        viewModel.switchToMode(ModeNames.numeric)
        #expect(viewModel.currentArrangement?.columns == 5)
        let ids = viewModel.currentArrangement.map { GridLayoutSolver.solve($0).map(\.keyId) } ?? []
        #expect(!ids.contains { NumpadColumn.isNumpadKey($0) })
    }
}
