//
//  OptimizedArrangements.swift
//  Wurstfinger
//
//  The per-language optimized layouts: how they are declared and applied.
//

import Foundation

/// Optimized arrangements of a language's letters, produced by `layoutlab`
/// from the language's own text (docs/layout-science.md) and checked in as data
/// (`OptimizedArrangements+Data.generated.swift`).
///
/// A variant is the language's layout with its letters in other slots. Nothing
/// else changes: punctuation, compose triggers, utility gestures and every
/// accent route sit where they always do, because the search only permutes the
/// slots that hold letters.
enum OptimizedArrangements {
    /// The variants every base language may have, in the order the language
    /// list offers them, with the suffix of their id.
    static let variants: [(variant: LayoutVariant, suffix: String)] = [
        (.optimized, "optimized"), (.full, "full"),
    ]

    /// The id of `base`'s `variant`.
    static func id(of variant: LayoutVariant, base: String) -> String {
        variant == .standard ? base : "\(base)_\(variants.first { $0.variant == variant }!.suffix)"
    }

    /// Descriptors of the variants that have data and are not declared by hand
    /// (the hand-declared English one predates the pipeline and is frozen).
    static func descriptors(for bases: [LanguageDescriptor]) -> [LanguageDescriptor] {
        let declared = Set(bases.map(\.id))
        var out: [LanguageDescriptor] = []
        for base in bases where base.variantOf == nil {
            for (variant, _) in variants {
                let id = id(of: variant, base: base.id)
                guard table[id] != nil, !declared.contains(id) else { continue }
                let name = variant == .full ? String(localized: "Fully optimized") : String(localized: "Optimized")
                let mark = LanguageSettings.label(for: Locale(identifier: base.localeIdentifier))
                out.append(base.variant(
                    variant, id: id, title: "\(base.title) · \(name)",
                    globeLabel: mark + (variant == .full ? "++" : "+")
                ))
            }
        }
        return out
    }

    /// The letters of a variant substituted into a layout declaration. A
    /// declaration whose id has no data comes back unchanged.
    ///
    /// What a letter's slot types besides the letter itself travels with it: the
    /// return swipe of a swipe slot (`returnOverrides`: Hebrew כ and its final
    /// ך, a Greek letter and its accented capital) and the circle of a tap slot
    /// (`circularOverrides`). Moving ך's base letter to another key therefore
    /// moves ך with it, and a letter that lands on a tap gets the same glyph on
    /// its circle, since a tap has no return swipe.
    static func applying(
        toId id: String,
        centerCharacters: [[String]],
        directionalOverrides: [String: [GestureType: String]],
        returnOverrides: [String: [GestureType: String]] = [:],
        circularOverrides: [String: String] = [:]
    ) -> (
        centerCharacters: [[String]],
        directionalOverrides: [String: [GestureType: String]],
        returnOverrides: [String: [GestureType: String]],
        circularOverrides: [String: String]
    ) {
        guard let arrangement = table[id] else {
            return (centerCharacters, directionalOverrides, returnOverrides, circularOverrides)
        }
        var centers = centerCharacters
        var overrides = directionalOverrides
        var returns = returnOverrides
        var circles = circularOverrides

        // What each moving letter carries, read before anything is rewritten.
        var formOfLetter: [String: String] = [:]
        for (rowIndex, row) in GridSlot.allSlots.enumerated() {
            for (columnIndex, slot) in row.enumerated() {
                for gesture in arrangement[slot]?.keys.sorted(by: { $0.rawValue < $1.rawValue }) ?? [] {
                    if gesture == .tap {
                        if let form = circularOverrides[slot] { formOfLetter[centerCharacters[rowIndex][columnIndex]] = form }
                    } else if let letter = directionalOverrides[slot]?[gesture], let form = returnOverrides[slot]?[gesture] {
                        formOfLetter[letter] = form
                    }
                }
            }
        }
        for (rowIndex, row) in GridSlot.allSlots.enumerated() {
            for (columnIndex, slot) in row.enumerated() {
                for (gesture, letter) in arrangement[slot] ?? [:] {
                    if gesture == .tap {
                        centers[rowIndex][columnIndex] = letter
                        circles[slot] = formOfLetter[letter]
                    } else {
                        overrides[slot, default: [:]][gesture] = letter
                        returns[slot, default: [:]][gesture] = formOfLetter[letter]
                    }
                }
            }
        }
        return (centers, overrides, returns, circles)
    }
}
