//
//  TextModel.swift
//  WurstfingerLayoutLab
//
//  A corpus table seen through a layout: each character becomes the key presses
//  that type it, and the transitions between presses get their weights.
//

import Foundation
@testable import WurstfingerKit

/// One key press in the stream a corpus turns into.
enum LabToken: Hashable {
    /// A letter of the layout: its slot depends on the arrangement.
    case letter(String)
    /// A press that never moves: space, punctuation, a compose trigger.
    case fixed(LabSlot)
}

/// Weighted transitions between key presses, normalised to sum to one.
struct TextModel {
    /// Movable letters, in the order of `LayoutProblem.letters`; token index i < letterCount.
    let letters: [String]
    /// Fixed presses, after the letters in the token numbering.
    let fixedSlots: [LabSlot]
    /// Row-major `tokenCount x tokenCount` weights.
    let weights: [Double]
    /// Occurrences of each letter, for the readability rule.
    let letterOccurrences: [Double]
    /// Share of the corpus's characters the layout can type.
    let coverage: Double
    /// Characters that could not be typed, with their occurrences.
    let untypable: [String: Int]

    var letterCount: Int { letters.count }
    var tokenCount: Int { letters.count + fixedSlots.count }

    init(table: CorpusTable, problem: LayoutProblem) {
        let letters = problem.letters
        var fixed: [LabSlot] = [.space]
        var letterIndex: [String: Int] = [:]
        for (index, letter) in letters.enumerated() { letterIndex[letter] = index }

        func fixedIndex(_ slot: LabSlot) -> Int {
            if let index = fixed.firstIndex(of: slot) { return letters.count + index }
            fixed.append(slot)
            return letters.count + fixed.count - 1
        }
        func token(_ token: LabToken) -> Int {
            switch token {
            case let .letter(letter): letterIndex[letter]!
            case let .fixed(slot): fixedIndex(slot)
            }
        }

        var expansions: [String: [LabToken]] = [:]
        var untypable: [String: Int] = [:]
        let occurrences = table.occurrences
        for character in occurrences.keys.sorted() {
            if let tokens = Self.expand(character, problem: problem, letterIndex: letterIndex) {
                expansions[character] = tokens
            } else {
                untypable[character] = occurrences[character]!
            }
        }
        // Token indices are assigned in a fixed order so the model is deterministic.
        var pending: [(Int, Int, Double)] = []
        func add(_ from: LabToken, _ to: LabToken, _ weight: Int) {
            pending.append((token(from), token(to), Double(weight)))
        }
        for character in table.initial.keys.sorted() {
            guard let tokens = expansions[character] else { continue }
            add(.fixed(.space), tokens[0], table.initial[character]!)
        }
        for character in table.final.keys.sorted() {
            guard let tokens = expansions[character] else { continue }
            add(tokens[tokens.count - 1], .fixed(.space), table.final[character]!)
        }
        for pair in table.bigrams.keys.sorted(by: { ($0.first, $0.second) < ($1.first, $1.second) }) {
            guard let first = expansions[pair.first], let second = expansions[pair.second] else { continue }
            add(first[first.count - 1], second[0], table.bigrams[pair]!)
        }
        // The presses inside one character: once per occurrence.
        for character in expansions.keys.sorted() {
            let tokens = expansions[character]!
            for index in 1 ..< max(tokens.count, 1) {
                add(tokens[index - 1], tokens[index], occurrences[character]!)
            }
        }

        let count = letters.count + fixed.count
        var weights = [Double](repeating: 0, count: count * count)
        var total = 0.0
        for (from, to, weight) in pending {
            weights[from * count + to] += weight
            total += weight
        }
        if total > 0 { for index in weights.indices { weights[index] /= total } }
        var letterWeights = [Double](repeating: 0, count: letters.count)
        for (index, letter) in letters.enumerated() { letterWeights[index] = Double(occurrences[letter] ?? 0) }

        self.letters = letters
        fixedSlots = fixed
        self.weights = weights
        letterOccurrences = letterWeights
        self.untypable = untypable
        let all = occurrences.values.reduce(0, +)
        coverage = all == 0 ? 0 : Double(all - untypable.values.reduce(0, +)) / Double(all)
    }

    // MARK: Expanding a character into key presses

    private static let markTriggers: [UInt32: String] = [
        0x0300: "ˋ", 0x0301: "´", 0x0302: "^", 0x0303: "~", 0x0304: "¯", 0x0306: "˘",
        0x0308: "¨", 0x030A: "°", 0x030B: "˝", 0x030C: "ˇ", 0x0327: "¸", 0x0328: "˛",
    ]

    /// The key presses that type `character` on this layout, or `nil` when it
    /// cannot be typed: a letter on a key, a symbol on a key, a base letter
    /// followed by the layout's compose trigger (the route the app takes), or,
    /// for Vietnamese, a Telex sequence.
    static func expand(
        _ character: String, problem: LayoutProblem, letterIndex: [String: Int]
    ) -> [LabToken]? {
        if letterIndex[character] != nil { return [.letter(character)] }
        if let slot = problem.fixedCharacters[character] { return [.fixed(slot)] }

        func base(_ text: String) -> LabToken? {
            if letterIndex[text] != nil { return .letter(text) }
            if let slot = problem.fixedCharacters[text] { return .fixed(slot) }
            return nil
        }

        // Vietnamese is typed with Telex; the compose triggers are there but unused.
        if problem.usesTelex, let tokens = telex(character, base: base) { return tokens }

        // Canonical decomposition: base letter plus marks, each mark a trigger the layout binds.
        let scalars = Array(character.decomposedStringWithCanonicalMapping.unicodeScalars)
        if scalars.count > 1, let first = scalars.first, let head = base(String(first)) {
            var current = String(first)
            var tokens = [head]
            var typable = true
            for mark in scalars.dropFirst() {
                guard let trigger = markTriggers[mark.value], let slot = problem.triggerSlots[trigger],
                      let next = problem.composeEngine.compose(previous: current, trigger: trigger)
                else { typable = false; break }
                tokens.append(.fixed(slot))
                current = next
            }
            if typable, current.precomposedStringWithCanonicalMapping == character { return tokens }
        }

        // Any compose rule that yields the character from a typable base (ß, ø, œ ...).
        for (trigger, table) in problem.composeEngine.ruleSet.rules.sorted(by: { $0.key < $1.key }) {
            guard let slot = problem.triggerSlots[trigger] else { continue }
            for (from, result) in table.sorted(by: { $0.key < $1.key }) where result == character {
                if let head = base(from) { return [head, .fixed(slot)] }
            }
        }

        // The accent cycle: the base letter, then the cycle key until the
        // character comes up; the fewest presses wins.
        if let cycle = problem.cycleSlot {
            var best: (steps: Int, letter: String)?
            for letter in letterIndex.keys.sorted() {
                var current = letter
                for step in 1 ... 12 {
                    guard let next = problem.composeEngine.cycleAccent(for: current) else { break }
                    if next == character {
                        if best == nil || step < best!.steps { best = (step, letter) }
                        break
                    }
                    current = next
                    if current == letter { break }
                }
            }
            if let best { return [.letter(best.letter)] + Array(repeating: .fixed(cycle), count: best.steps) }
        }
        return nil
    }

    /// Telex: `aa ee oo` circumflex, `aw` breve, `ow uw` horn, `dd` stroke, and
    /// the tone as one of `s f r x j` right after the vowel.
    private static func telex(_ character: String, base: (String) -> LabToken?) -> [LabToken]? {
        let scalars = Array(character.decomposedStringWithCanonicalMapping.unicodeScalars)
        guard let first = scalars.first else { return nil }
        var letters: [String] = []
        var head = String(first)
        if head == "đ" { head = "d"; letters = ["d", "d"] } else { letters = [head] }
        var tone: String?
        for mark in scalars.dropFirst() {
            switch mark.value {
            case 0x0302: letters.append(head) // circumflex: a a, e e, o o
            case 0x0306, 0x031B: letters.append("w") // breve, horn
            case 0x0301: tone = "s"
            case 0x0300: tone = "f"
            case 0x0309: tone = "r"
            case 0x0303: tone = "x"
            case 0x0323: tone = "j"
            default: return nil
            }
        }
        if let tone { letters.append(tone) }
        var tokens: [LabToken] = []
        for letter in letters {
            guard let token = base(letter) else { return nil }
            tokens.append(token)
        }
        return tokens
    }
}
