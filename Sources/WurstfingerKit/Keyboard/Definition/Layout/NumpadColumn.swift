//
//  NumpadColumn.swift
//  Wurstfinger
//
//  The always-available numpad column: four flick keys that carry three digits
//  each, so numbers are one gesture away from any letter mode.
//

import Foundation

/// The compact, always-available numpad column (the "Numpad Column" setting).
///
/// Four keys stacked beside the letter grid, one per grid row. Each carries
/// three digits side by side: **tap types the middle digit, a swipe left types
/// the left one, a swipe right the right one** — so the column reads as the
/// numpad rows `1 2 3`, `4 5 6`, `7 8 9` (or `7 8 9` on top for the calculator
/// style) and a bottom row `, 0 .`. The other six directions carry symbols,
/// shown as small hints around the digits.
///
/// The keys are ordinary flick keys: they go through the resolver chain and the
/// compiled tables like every other key, which is also what lets the guide card
/// preview their digits. They are added to a definition's modes
/// (`KeyboardDefinition.addingNumpadColumn`) only while the column is on, so a
/// keyboard with it off is the definition it always was.
enum NumpadColumn {
    /// The key ids, top to bottom — one per grid row. They sit in the first four
    /// rows of the standard arrangement, the last one beside the space bar.
    static let keyIds = (0 ..< 4).map { "numpad\($0)" }

    /// Whether `keyId` names one of the column's keys.
    static func isNumpadKey(_ keyId: String) -> Bool {
        keyIds.contains(keyId)
    }

    // MARK: - Digits

    /// The three glyphs (left, middle, right) of each of the four rows, from the
    /// layout's own digit set — Arabic-Indic, Persian, Devanagari and Thai
    /// layouts get their native numerals, exactly as their numeric mode does.
    ///
    /// The comma and the full stop of the bottom row are the plain ASCII ones:
    /// they are what number fields (and every script's own numeric mode) take.
    static func rows(digits: [String], style: NumpadType) -> [[String]] {
        let digits = digits.count == 10 ? digits : NumericLayouts.westernDigits
        let top = [digits[1], digits[2], digits[3]]
        let middle = [digits[4], digits[5], digits[6]]
        let bottom = [digits[7], digits[8], digits[9]]
        let body = style == .phone ? [top, middle, bottom] : [bottom, middle, top]
        return body + [[",", digits[0], "."]]
    }

    // MARK: - Symbols

    /// The six symbol gestures of each row, top to bottom. The set is by
    /// *position*, so it stays put when the numpad style swaps the digit rows:
    ///
    /// | row | ↑ | ↓ | ↖ | ↗ | ↙ | ↘ |
    /// | --- | --- | --- | --- | --- | --- | --- |
    /// | top | + | − | × | ÷ | ( | ) |
    /// | second | % | = | $ | € | £ | ¥ |
    /// | third | # | * | / | ^ | < | > |
    /// | bottom | : | ; | ° | ± | √ | π |
    ///
    /// Operators and brackets on top, where a calculator keeps them; currencies
    /// in the middle; the rest of ASCII's arithmetic punctuation third; and the
    /// bottom row, beside the space bar, carries the marks that follow a number.
    /// The minus is *drawn* as the typographic U+2212 but *types* the ASCII
    /// hyphen-minus: that is the one number fields and spreadsheets parse.
    static let symbols: [[GestureType: String]] = [
        [.swipeUp: "+", .swipeDown: "\u{2212}", .swipeUpLeft: "×", .swipeUpRight: "÷",
         .swipeDownLeft: "(", .swipeDownRight: ")"],
        [.swipeUp: "%", .swipeDown: "=", .swipeUpLeft: "$", .swipeUpRight: "€",
         .swipeDownLeft: "£", .swipeDownRight: "¥"],
        [.swipeUp: "#", .swipeDown: "*", .swipeUpLeft: "/", .swipeUpRight: "^",
         .swipeDownLeft: "<", .swipeDownRight: ">"],
        [.swipeUp: ":", .swipeDown: ";", .swipeUpLeft: "°", .swipeUpRight: "±",
         .swipeDownLeft: "√", .swipeDownRight: "π"],
    ]

    // MARK: - Keys

    /// The four key definitions for a digit set and numpad style, by key id.
    static func keys(digits: [String], style: NumpadType) -> [String: KeyDefinition] {
        let digitRows = rows(digits: digits, style: style)
        var keys: [String: KeyDefinition] = [:]
        for (index, id) in keyIds.enumerated() {
            let row = digitRows[index]
            var bindings: [GestureType: KeyBinding] = [:]
            for (gesture, symbol) in symbols[index] {
                let typed = symbol == "\u{2212}" ? "-" : symbol
                bindings[gesture] = KeyBinding(
                    label: symbol, action: .commitText(typed),
                    category: .symbol, returnAction: nil, accessibilityLabel: nil
                )
            }
            // The side digits carry their own name for VoiceOver: that is what
            // makes them reachable as custom actions (`accessibilityActions`).
            bindings[.swipeLeft] = digitBinding(row[0])
            bindings[.tap] = digitBinding(row[1])
            bindings[.swipeRight] = digitBinding(row[2])
            keys[id] = KeyDefinition(
                id: id, bindings: bindings, swipeMode: .eightWay,
                slideType: .none, style: .numpad, tapCycleActions: nil
            )
        }
        return keys
    }

    /// A digit binding. The bottom row's `,` and `.` are punctuation and take
    /// the symbol category. Unnamed: VoiceOver offers every character on the
    /// key by its glyph and gesture (`KeyDefinition.accessibilityActions`).
    private static func digitBinding(_ glyph: String) -> KeyBinding {
        let isDigit = glyph.first?.isNumber == true
        return KeyBinding(
            label: glyph, action: .commitText(glyph),
            category: isDigit ? .digit : .symbol, returnAction: nil,
            accessibilityLabel: nil
        )
    }
}

// MARK: - Definition

extension KeyboardDefinition {
    /// A copy whose letter-like modes also carry the numpad column's keys, with
    /// the digits in this definition's own script and in `style` order.
    ///
    /// Every mode but the numeric one gets them: the numeric mode is all digits
    /// already, so the column would only repeat it. The arrangement is not
    /// touched — whether and where the column is drawn is decided at layout time
    /// (`GridArrangement.addingNumpadColumn`), so the keys cost nothing when no
    /// arrangement places them.
    func addingNumpadColumn(style: NumpadType) -> KeyboardDefinition {
        let numpadKeys = NumpadColumn.keys(digits: numericDigits, style: style)
        var updated = modes
        for (name, mode) in modes where name != ModeNames.numeric {
            updated[name] = KeyboardMode(
                name: mode.name,
                keys: mode.keys.merging(numpadKeys) { existing, _ in existing },
                arrangements: mode.arrangements,
                autoTransitions: mode.autoTransitions
            )
        }
        return KeyboardDefinition(
            title: title, id: id, localeIdentifier: localeIdentifier,
            modes: updated, defaultMode: defaultMode, settings: settings,
            numericBackToAlphaLabel: numericBackToAlphaLabel,
            numericDigits: numericDigits
        )
    }
}
