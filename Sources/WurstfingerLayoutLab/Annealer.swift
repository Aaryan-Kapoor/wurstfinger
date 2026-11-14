//
//  Annealer.swift
//  WurstfingerLayoutLab
//
//  Simulated annealing over the arrangements of a language's letters, under the
//  rules that keep a layout recognisably the same keyboard. Deterministic: every
//  random number comes from a seeded LayoutLabRandom.
//

import Foundation
@testable import WurstfingerKit

/// LayoutLabRandom (Steele, Lea & Flood 2014): a tiny seeded generator whose stream
/// is the same on every machine and Swift version, unlike `SystemRandomNumberGenerator`.
struct LayoutLabRandom {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    /// Uniform in 0 ..< bound.
    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }
}

/// A scored arrangement.
struct ScoredLayout: Equatable {
    var assignment: LetterAssignment
    /// Bits per typed character.
    var cost: Double
    /// Letters that sit in a different slot than in the shipped layout.
    var moved: [String]
}

/// Search settings.
struct AnnealingSettings: Equatable {
    var restarts = 240
    var steps = 40_000
    var seed: UInt64 = 0
}

/// The optimization of one language.
struct LayoutOptimizer {
    let problem: LayoutProblem
    let text: TextModel
    let model: CostModel

    private let positionSlots: [LabSlot]
    /// Slot-to-slot cost in bits, `positionCount x positionCount`, row = from.
    private let transition: [Double]
    private let letterCount: Int
    private let tokenCount: Int
    /// Positions on each grid key: `[key][0]` is the tap, the rest swipes.
    private let keyPositions: [[Int]]
    private let keyOfPosition: [Int]

    init(problem: LayoutProblem, text: TextModel, model: CostModel = CostModel()) {
        self.problem = problem
        self.text = text
        self.model = model
        positionSlots = problem.movableSlots + text.fixedSlots
        letterCount = text.letterCount
        tokenCount = text.tokenCount
        let count = positionSlots.count
        var matrix = [Double](repeating: 0, count: count * count)
        for from in 0 ..< count {
            for to in 0 ..< count {
                matrix[from * count + to] = model.transitionBits(from: positionSlots[from], to: positionSlots[to])
            }
        }
        transition = matrix
        var perKey = [[Int]](repeating: [], count: 9)
        for (index, slot) in problem.movableSlots.enumerated() {
            if slot.gesture == .tap { perKey[slot.key].insert(index, at: 0) } else { perKey[slot.key].append(index) }
        }
        keyPositions = perKey
        keyOfPosition = problem.movableSlots.map(\.key)
    }

    // MARK: Cost

    /// Cost in bits per character of letter token `i` at position `position[i]`.
    func cost(of position: [Int]) -> Double {
        var total = 0.0
        let count = tokenCount
        for a in 0 ..< count {
            let pa = a < letterCount ? position[a] : a
            for b in 0 ..< count {
                let weight = text.weights[a * count + b]
                if weight == 0 { continue }
                let pb = b < letterCount ? position[b] : b
                total += weight * transition[pa * count + pb]
            }
        }
        return total
    }

    func score(_ assignment: LetterAssignment) -> ScoredLayout {
        var position = [Int](repeating: 0, count: letterCount)
        var indexOfSlot: [LabSlot: Int] = [:]
        for (index, slot) in problem.movableSlots.enumerated() { indexOfSlot[slot] = index }
        var letterIndex: [String: Int] = [:]
        for (index, letter) in text.letters.enumerated() { letterIndex[letter] = index }
        for (slot, letter) in assignment { position[letterIndex[letter]!] = indexOfSlot[slot]! }
        return scored(position)
    }

    private func scored(_ position: [Int]) -> ScoredLayout {
        var assignment: LetterAssignment = [:]
        var moved: [String] = []
        for (token, p) in position.enumerated() {
            assignment[problem.movableSlots[p]] = text.letters[token]
            if p != token { moved.append(text.letters[token]) }
        }
        return ScoredLayout(assignment: assignment, cost: cost(of: position), moved: moved.sorted())
    }

    // MARK: Rules

    /// The readability rule: on every key the tap letter is at least as
    /// frequent as each swipe letter, so the large label the eye sees is the
    /// commonest of its key.
    private func keyIsReadable(_ key: Int, _ position: [Int], _ holder: [Int]) -> Bool {
        let positions = keyPositions[key]
        guard let tap = positions.first else { return true }
        let tapOccurrences = text.letterOccurrences[holder[tap]]
        for swipe in positions.dropFirst() where text.letterOccurrences[holder[swipe]] > tapOccurrences {
            return false
        }
        return true
    }

    /// Cost change of swapping the positions of letters `i` and `k`.
    private func swapDelta(_ i: Int, _ k: Int, _ position: [Int]) -> Double {
        let count = tokenCount
        let pi = position[i], pk = position[k]
        func partial(_ pi: Int, _ pk: Int) -> Double {
            var sum = 0.0
            for b in 0 ..< count {
                let pb: Int
                if b == i { pb = pi } else if b == k { pb = pk } else { pb = b < letterCount ? position[b] : b }
                sum += text.weights[i * count + b] * transition[pi * count + pb]
                sum += text.weights[k * count + b] * transition[pk * count + pb]
                if b != i, b != k {
                    sum += text.weights[b * count + i] * transition[pb * count + pi]
                    sum += text.weights[b * count + k] * transition[pb * count + pk]
                }
            }
            return sum
        }
        return partial(pk, pi) - partial(pi, pk)
    }

    // MARK: Search

    /// One annealing run. `maxMoved` caps how many letters may sit away from
    /// their shipped slot; `scramble` starts from a random readable arrangement
    /// instead of the shipped one.
    private func run(seed: UInt64, steps: Int, maxMoved: Int?, scramble: Bool) -> (position: [Int], cost: Double) {
        var random = LayoutLabRandom(seed: seed)
        var position = Array(0 ..< letterCount)
        var holder = Array(0 ..< letterCount) // position -> letter
        var moved = 0

        func swap(_ i: Int, _ k: Int) {
            let wasI = position[i] != i, wasK = position[k] != k
            position.swapAt(i, k)
            holder[position[i]] = i
            holder[position[k]] = k
            moved += (position[i] != i ? 1 : 0) + (position[k] != k ? 1 : 0) - (wasI ? 1 : 0) - (wasK ? 1 : 0)
        }
        func valid(_ i: Int, _ k: Int) -> Bool {
            swap(i, k)
            defer { swap(i, k) }
            if let maxMoved, moved > maxMoved { return false }
            return keyIsReadable(keyOfPosition[position[i]], position, holder)
                && keyIsReadable(keyOfPosition[position[k]], position, holder)
        }

        if scramble {
            for _ in 0 ..< 6 * letterCount {
                let i = random.below(letterCount), k = random.below(letterCount)
                if i != k, valid(i, k) { swap(i, k) }
            }
        }

        // Temperature from the typical size of a swap, as in the Python search.
        var deltas: [Double] = []
        for _ in 0 ..< 400 {
            let i = random.below(letterCount), k = random.below(letterCount)
            if i != k { deltas.append(abs(swapDelta(i, k, position))) }
        }
        deltas.sort()
        let median = deltas.isEmpty ? 1e-3 : max(deltas[deltas.count / 2], 1e-9)
        let hot = 5 * median, cold = 0.05 * median

        var current = cost(of: position)
        var best = position
        var bestCost = current
        for step in 0 ..< steps {
            let temperature = hot * pow(cold / hot, Double(step) / Double(max(steps - 1, 1)))
            let i = random.below(letterCount), k = random.below(letterCount)
            if i == k || !valid(i, k) { continue }
            let delta = swapDelta(i, k, position)
            if delta <= 0 || random.unit() < exp(-delta / temperature) {
                swap(i, k)
                current += delta
                if current < bestCost - 1e-15 {
                    bestCost = current
                    best = position
                }
            }
        }

        // Steepest descent from the best state: swap the single best pair until none helps.
        position = best
        for token in 0 ..< letterCount { holder[position[token]] = token }
        moved = position.enumerated().filter { $0.offset != $0.element }.count
        while true {
            var bestPair: (Int, Int)?
            var bestGain = -1e-12
            for i in 0 ..< letterCount {
                for k in (i + 1) ..< letterCount where valid(i, k) {
                    let delta = swapDelta(i, k, position)
                    if delta < bestGain { bestGain = delta; bestPair = (i, k) }
                }
            }
            guard let (i, k) = bestPair else { break }
            swap(i, k)
        }
        return (position, cost(of: position))
    }

    /// The best arrangement over `settings.restarts` seeded runs. With
    /// `maxMoved` nil the search is free (readable starts, anything goes); with
    /// a number it starts from the shipped layout and never leaves a ball of that
    /// many moved letters.
    func optimize(maxMoved: Int?, settings: AnnealingSettings = AnnealingSettings()) -> ScoredLayout {
        var best: (position: [Int], cost: Double)?
        for restart in 0 ..< settings.restarts {
            let result = run(
                seed: settings.seed &+ UInt64(restart), steps: settings.steps,
                maxMoved: maxMoved, scramble: maxMoved == nil
            )
            if let current = best {
                if result.cost < current.cost - 1e-12
                    || (abs(result.cost - current.cost) <= 1e-12 && result.position.lexicographicallyPrecedes(current.position)) {
                    best = result
                }
            } else {
                best = result
            }
        }
        return scored(best!.position)
    }
}
