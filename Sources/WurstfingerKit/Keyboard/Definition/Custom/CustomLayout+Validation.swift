//
//  CustomLayout+Validation.swift
//  Wurstfinger
//
//  Everything a custom layout must satisfy before the app accepts it.
//

import Foundation

extension CustomLayout {
    /// Ids a layout may carry: a lowercase slug, so the id is also a safe file
    /// name (no separators, no dots at either end, no case-folding surprises on
    /// a case-insensitive volume).
    static func isValidID(_ id: String) -> Bool {
        let scalars = Array(id.unicodeScalars)
        guard (3 ... 64).contains(scalars.count), !id.hasPrefix("."), !id.hasSuffix(".") else { return false }
        return scalars.allSatisfy { scalar in
            ("a" ... "z").contains(scalar) || ("0" ... "9").contains(scalar)
                || scalar == "." || scalar == "_" || scalar == "-"
        }
    }

    /// `en`, `en_US`, `zh-Hans_CN`: language, then optional script and region
    /// subtags, joined by `_` or `-`.
    static func isValidLocaleIdentifier(_ identifier: String) -> Bool {
        let parts = identifier.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "_" || $0 == "-" })
        guard (1 ... 3).contains(parts.count) else { return false }
        guard let language = parts.first, (2 ... 3).contains(language.count),
              language.unicodeScalars.allSatisfy({ ("a" ... "z").contains($0) })
        else { return false }
        return parts.dropFirst().allSatisfy { subtag in
            (2 ... 4).contains(subtag.count) && subtag.unicodeScalars.allSatisfy {
                ("a" ... "z").contains($0) || ("A" ... "Z").contains($0) || ("0" ... "9").contains($0)
            }
        }
    }

    /// Whether `text` may be committed by a gesture: short, and free of control
    /// characters (a layout cannot smuggle a newline or tab onto a letter key;
    /// the shared punctuation already carries both where they belong).
    static func isValidBindingText(_ text: String) -> Bool {
        text.count <= maxTextLength && !text.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// Every problem with this layout, in a stable order; empty means it can be
    /// built and will pass `KeyboardDefinition.validate()`.
    ///
    /// Checks the document's own rules first (identity, text, return swipes),
    /// then — only when those hold, because the factory traps on some of them —
    /// assembles the keyboard and runs the same structural validators the
    /// shipped layouts are tested with.
    func validate() -> [CustomLayoutError] {
        var problems: [CustomLayoutError] = []

        if !Self.isValidID(id) {
            problems.append(.invalidId(id))
        } else if KeyboardRegistry.isShippedID(id) {
            problems.append(.reservedId(id))
        }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || title.count > Self.maxTitleLength
            || title.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            problems.append(.invalidTitle)
        }
        if !Self.isValidLocaleIdentifier(localeIdentifier) {
            problems.append(.invalidLocale(localeIdentifier))
        }

        for slot in keys.keys.sorted() where !Self.slots.contains(slot) {
            problems.append(.unknownSlot(slot))
        }

        for slot in Self.slots {
            let bindings = keys[slot] ?? [:]
            if (bindings[.tap]?.text ?? "").isEmpty {
                problems.append(.missingTap(slot: slot))
            }
            for gesture in Self.editableGestures where bindings[gesture] != nil {
                guard let binding = bindings[gesture] else { continue }
                let textOK = Self.isValidBindingText(binding.text)
                    && (binding.returnText.map(Self.isValidBindingText) ?? true)
                if !textOK {
                    problems.append(.invalidText(slot: slot, gesture: gesture))
                }
                if binding.returnText != nil {
                    // The factory attaches a return output to a swipe binding
                    // the layout itself declares, and traps if there is none.
                    if !gesture.isSwipe || binding.text.isEmpty {
                        problems.append(.returnWithoutBinding(slot: slot, gesture: gesture))
                    }
                }
            }
        }

        if problems.isEmpty {
            // Structure only: independent of the layout it is based on.
            let definition = makeDefinition(basedOn: nil)
            let structural = definition.validate()
            if !structural.isEmpty {
                problems.append(.invalidDefinition(structural.map(\.description).joined(separator: "; ")))
            }
        }
        return problems
    }
}
