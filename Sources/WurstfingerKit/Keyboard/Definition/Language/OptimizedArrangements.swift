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
    static func applying(
        toId id: String,
        centerCharacters: [[String]],
        directionalOverrides: [String: [GestureType: String]]
    ) -> (centerCharacters: [[String]], directionalOverrides: [String: [GestureType: String]]) {
        guard let arrangement = table[id] else { return (centerCharacters, directionalOverrides) }
        var centers = centerCharacters
        var overrides = directionalOverrides
        for (rowIndex, row) in GridSlot.allSlots.enumerated() {
            for (columnIndex, slot) in row.enumerated() {
                for (gesture, letter) in arrangement[slot] ?? [:] {
                    if gesture == .tap {
                        centers[rowIndex][columnIndex] = letter
                    } else {
                        overrides[slot, default: [:]][gesture] = letter
                    }
                }
            }
        }
        return (centers, overrides)
    }
}
