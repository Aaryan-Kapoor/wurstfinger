//
//  LayoutProblem.swift
//  WurstfingerLayoutLab
//
//  What may move in a language's layout and what must stay, read from the real
//  `KeyboardDefinition` rather than transcribed.
//

import Foundation
@testable import WurstfingerKit

/// Why a language cannot be optimized by this model.
enum LabError: Error, CustomStringConvertible {
    case unsupported(String)
    case noCorpus(String)

    var description: String {
        switch self {
        case let .unsupported(reason): "unsupported: \(reason)"
        case let .noCorpus(id): "no corpus table for \(id)"
        }
    }
}

/// The letters of a layout in the slots they occupy.
typealias LetterAssignment = [LabSlot: String]

/// A language's layout as an optimization problem: the slots that hold
/// letters (the only things that move), and everything that stays put.
struct LayoutProblem {
    let languageId: String
    let locale: Locale
    /// Letter slots, sorted: nine taps plus the swipes the layout fills with letters.
    let movableSlots: [LabSlot]
    /// The shipped arrangement.
    let base: LetterAssignment
    /// Slots that repeat a letter another slot already types (the Greek layout
    /// binds ω twice). They stay as they are: only the first slot of a letter
    /// moves, so every letter has exactly one place the model can move.
    let duplicateSlots: [LabSlot: String]
    /// Single non-letter characters a slot commits (`'`, `-`, `.`): fixed.
    let fixedCharacters: [String: LabSlot]
    /// Compose triggers (`´`, `¨`, ...) and the slot that types each: fixed.
    let triggerSlots: [String: LabSlot]
    let composeEngine: ComposeEngine
    /// The 🅒 accent-cycle key, when the layout has one: a character no key or
    /// trigger gives is the base letter plus this key pressed as often as the
    /// cycle needs.
    let cycleSlot: LabSlot?
    /// Vietnamese is typed with Telex: modified vowels are key sequences.
    let usesTelex: Bool

    init(definition: KeyboardDefinition) throws {
        guard definition.settings.autoCapitalize else {
            throw LabError.unsupported("caseless script: return swipes and circles bind per slot (final forms, voicing)")
        }
        guard definition.settings.inputMethod != .hangul, definition.settings.combineRuleSet == nil else {
            throw LabError.unsupported("sequential composition: the character stream is not the key stream")
        }
        guard let main = definition.mode(ModeNames.main) else {
            throw LabError.unsupported("no main mode")
        }
        languageId = definition.id
        locale = definition.locale
        usesTelex = definition.settings.inputMethod == .telex
        composeEngine = definition.settings.composeRuleOverrides
            .map { ComposeEngine.withGlobalRules(overrides: $0) } ?? .shared

        var movable: [LabSlot] = []
        var base: LetterAssignment = [:]
        var duplicates: [LabSlot: String] = [:]
        var fixed: [String: LabSlot] = [:]
        var triggers: [String: LabSlot] = [:]
        var cycle: LabSlot?
        for (keyIndex, keyId) in GridSlot.allSlots.joined().enumerated() {
            guard let key = main.keys[keyId] else { continue }
            let gestures: [GestureType] = [.tap] + GestureType.allCases.filter(\.isSwipe)
            for gesture in gestures {
                guard let binding = key.bindings[gesture] else { continue }
                let slot = LabSlot(key: keyIndex, gesture: gesture)
                switch binding.action {
                case let .commitText(text):
                    guard text.count == 1, let character = text.first, !character.isWhitespace else { continue }
                    if character.isLetter {
                        if base.values.contains(text) {
                            duplicates[slot] = text
                        } else {
                            movable.append(slot)
                            base[slot] = text
                        }
                    } else if fixed[text] == nil || slot < fixed[text]! {
                        fixed[text] = slot
                    }
                case let .compose(trigger):
                    if triggers[trigger] == nil || slot < triggers[trigger]! { triggers[trigger] = slot }
                case .cycleAccents:
                    if cycle == nil || slot < cycle! { cycle = slot }
                default:
                    continue
                }
            }
        }
        movableSlots = movable.sorted()
        self.base = base
        duplicateSlots = duplicates
        fixedCharacters = fixed
        triggerSlots = triggers
        cycleSlot = cycle
    }

    /// Loads language `id` from the registry.
    init(languageId id: String) throws {
        guard let definition = KeyboardRegistry.load(id: id) else {
            throw LabError.unsupported("no such language \(id)")
        }
        try self.init(definition: definition)
    }

    /// Characters of the shipped layout that are letters.
    var letters: [String] { movableSlots.map { base[$0]! } }

    /// Whether `assignment` puts every letter of the language on exactly one of
    /// the language's letter slots.
    func isPermutation(_ assignment: LetterAssignment) -> Bool {
        Set(assignment.keys) == Set(movableSlots) && Set(assignment.values) == Set(letters)
    }
}
