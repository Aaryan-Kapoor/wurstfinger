//
//  GestureLab.swift
//  WurstfingerScenarioKit
//
//  The gesture accuracy lab: a deterministic generator of labelled touch
//  paths made the way real thumbs make them, and a confusion matrix over what
//  `KeyGestureRecognizer.classify` (production thresholds) says about them.
//
//  `TouchSynthesizer` writes the idealised path a scenario needs to type a
//  key. This is its adversary: it adds everything a hand does that a drawing
//  of a gesture does not — bowed strokes, settling hooks at touch-down and
//  flick-off hooks at lift, overshoot, uneven speed, a digitizer that drops,
//  repeats or spikes a sample — and keeps the intended gesture as the label,
//  so a recogniser's accuracy is a number rather than an impression.
//
//  Everything is a pure function of a seed: the same seed produces the same
//  paths on every run and machine (SplitMix64 and Box-Muller, no system
//  generator), which is what lets the tests assert accuracy floors and lets a
//  change to the classifier be judged by the matrix it moves.
//

import CoreGraphics
import Foundation
@testable import WurstfingerKit

// MARK: - Labels

/// What a lab gesture was *meant* to be, in the vocabulary the classifier
/// answers in: a gesture and whether it is the return (out-and-back) form.
struct LabLabel: Hashable, Sendable, CustomStringConvertible {
    var gesture: GestureType
    var isReturn = false

    /// The eight flick directions, clockwise from the right.
    static let directions: [GestureType] = [
        .swipeRight, .swipeDownRight, .swipeDown, .swipeDownLeft,
        .swipeLeft, .swipeUpLeft, .swipeUp, .swipeUpRight,
    ]

    static let tap = LabLabel(gesture: .tap)
    static let clockwise = LabLabel(gesture: .circularClockwise)
    static let counterclockwise = LabLabel(gesture: .circularCounterclockwise)

    /// Every class, in matrix order: tap, the eight flicks, the eight return
    /// swipes, the two circles.
    static let all: [LabLabel] =
        [tap]
        + directions.map { LabLabel(gesture: $0) }
        + directions.map { LabLabel(gesture: $0, isReturn: true) }
        + [clockwise, counterclockwise]

    static let flicks: [LabLabel] = directions.map { LabLabel(gesture: $0) }
    static let returns: [LabLabel] = directions.map { LabLabel(gesture: $0, isReturn: true) }
    static let circles: [LabLabel] = [clockwise, counterclockwise]

    init(gesture: GestureType, isReturn: Bool = false) {
        self.gesture = gesture
        self.isReturn = isReturn
    }

    /// What the classifier said, as a label.
    init(_ classification: GestureClassification) {
        self.init(
            gesture: classification.gesture,
            isReturn: classification.isReturn && classification.gesture.isSwipe
        )
    }

    /// The direction's centre on screen, degrees, `atan2` convention
    /// (0 = right, 90 = down). Nil for the classes without a direction.
    var centerDegrees: Double? {
        guard let index = Self.directions.firstIndex(of: gesture) else { return nil }
        return Double(index) * 45
    }

    /// Short column heading: `R`, `DR`, … for a flick, `rR`, … for a return
    /// swipe.
    var abbreviation: String {
        let names = ["R", "DR", "D", "DL", "L", "UL", "U", "UR"]
        if let index = Self.directions.firstIndex(of: gesture) {
            return (isReturn ? "r" : "") + names[index]
        }
        switch gesture {
        case .tap: return "tap"
        case .circularClockwise: return "cw"
        case .circularCounterclockwise: return "ccw"
        default: return gesture.rawValue
        }
    }

    var description: String { abbreviation }
}

// MARK: - Samples

/// One generated gesture: the path a key would receive, and what it was meant
/// to be.
struct LabGesture: Sendable {
    let label: LabLabel
    /// Origin-anchored translations from touch-down, in screen points.
    let positions: [CGPoint]
    /// The key's width over its height; the classifier normalises with it.
    let aspectRatio: CGFloat
    /// The reach the generator aimed for, in normalised points: the flick's
    /// length, the return swipe's outward leg, the circle's major diameter.
    /// Zero for taps. Lets a report slice accuracy by size.
    let reach: Double
    /// The arc a circle was drawn through, degrees. Zero for the others.
    let sweepDegrees: Double
    /// What was drawn into it, by name (hook sizes, overshoot, the ellipse's
    /// ratio, whether a sample spiked, …), for slicing a report.
    let details: [String: Double]
}

// MARK: - Profiles

/// How a hand misbehaves, as ranges the generator draws from.
///
/// `clean` is a steady, deliberate thumb; `realistic` is the whole list the
/// lab exists for. Both are plain values so a test can tighten or relax one
/// dimension and keep the rest.
struct LabProfile: Sendable {
    // Tap
    /// Slow drift between touch-down and lift, points.
    var tapDrift: ClosedRange<Double> = 0 ... 6

    // Flick
    var flickLength: ClosedRange<Double> = 20 ... 90
    /// The aim may stray from the direction's centre by up to this many
    /// degrees either way (a sector is ±22.5°).
    var aimSpread: Double = 18
    /// Sideways bow of the stroke as a fraction of its length.
    var bow: Double = 0.12
    /// Chance of a settling hook at touch-down, and its size in points.
    var startHookChance = 0.35
    var startHookSize: ClosedRange<Double> = 2 ... 6
    /// Chance of a flick-off hook at lift, and its size in points.
    var endHookChance = 0.35
    var endHookSize: ClosedRange<Double> = 2 ... 7
    /// Hooks never exceed this fraction of the stroke, so a short flick is
    /// still the flick it was meant to be.
    var hookCap = 0.22
    var overshootChance = 0.25
    /// Overshoot beyond the stroke's end, as a fraction of its length.
    var overshoot: ClosedRange<Double> = 0.05 ... 0.18
    var flickDuration: ClosedRange<Double> = 0.05 ... 0.4

    // Return swipe
    var returnLength: ClosedRange<Double> = 28 ... 80
    /// How far short of the origin the finger comes back, as a fraction of the
    /// outward leg. 0 returns to the origin exactly; the classifier's own
    /// threshold sits near 0.6, so the range stays clear of it.
    var returnResidual: ClosedRange<Double> = 0 ... 0.4
    /// Sideways offset of the way back, as a fraction of the outward leg.
    var returnOffset: ClosedRange<Double> = 0.04 ... 0.3
    var returnDuration: ClosedRange<Double> = 0.15 ... 0.5

    // Circle
    /// The ellipse's major semi-axis, points.
    var circleRadius: ClosedRange<Double> = 14 ... 30
    /// Minor over major; 0.5 is the spec's 2:1 ellipse in either orientation
    /// (the lab turns the ellipse to any angle).
    var circleAspect: ClosedRange<Double> = 0.5 ... 1
    /// The smallest minor semi-axis, points.
    var circleMinorFloor = 8.5
    var circleSweep: ClosedRange<Double> = 270 ... 450
    /// Radial wobble amplitude as a fraction of the radius.
    var circleWobble: ClosedRange<Double> = 0 ... 0.1
    var circleDuration: ClosedRange<Double> = 0.3 ... 0.9

    // Digitizer and sampling
    /// Gaussian jitter, points (one sigma).
    var jitter: ClosedRange<Double> = 0.2 ... 0.9
    var sampleRates: [Double] = [60, 120]
    /// Chance, per interior sample, that it is dropped / repeated.
    var dropChance = 0.02
    var repeatChance = 0.03
    /// Chance, per gesture, of one sample landing far off its place, and how
    /// far.
    var spikeChance = 0.04
    var spikeSize: ClosedRange<Double> = 15 ... 45

    var aspectRatios: ClosedRange<Double> = 0.7 ... 1.4

    /// A steady thumb: no hooks, no overshoot, no digitizer faults.
    static let clean: LabProfile = {
        var p = LabProfile()
        p.flickLength = 30 ... 90
        p.aimSpread = 12
        p.bow = 0.05
        p.startHookChance = 0
        p.endHookChance = 0
        p.overshootChance = 0
        p.returnLength = 35 ... 80
        p.returnOffset = 0.04 ... 0.15
        p.returnResidual = 0 ... 0.25
        p.circleAspect = 0.7 ... 1
        p.circleSweep = 330 ... 420
        p.circleWobble = 0 ... 0.04
        p.tapDrift = 0 ... 3
        p.jitter = 0.2 ... 0.6
        p.dropChance = 0
        p.repeatChance = 0
        p.spikeChance = 0
        return p
    }()

    /// Everything the lab models.
    static let realistic = LabProfile()
}

// MARK: - Generator

/// Produces labelled gestures. Deterministic in `seed` and the class asked
/// for: one class's paths do not move when another's profile changes.
struct GestureLab: Sendable {
    var profile: LabProfile = .realistic
    var seed: UInt64 = 0x1AB_5EED

    /// Key height every lab key shares; the width follows from the drawn
    /// aspect ratio. Only the circle and the classifier's aspect
    /// normalisation read it.
    static let keyHeight: CGFloat = 58

    /// `count` gestures of `label`.
    func gestures(_ label: LabLabel, count: Int) -> [LabGesture] {
        let classIndex = LabLabel.all.firstIndex(of: label) ?? 0
        var random = LabRandom(seed: seed &+ UInt64(classIndex + 1) &* 0x9E37_79B9)
        return (0 ..< count).map { _ in gesture(label, using: &random) }
    }

    /// One gesture of `label`.
    func gesture(_ label: LabLabel, using random: inout LabRandom) -> LabGesture {
        let aspect = random.range(profile.aspectRatios)
        let rate = random.pick(profile.sampleRates)
        let kind: Shape
        switch label.gesture {
        case .tap:
            kind = tapShape(using: &random)
        case .circularClockwise:
            kind = circleShape(clockwise: true, using: &random)
        case .circularCounterclockwise:
            kind = circleShape(clockwise: false, using: &random)
        default:
            kind = label.isReturn
                ? returnShape(label, using: &random)
                : flickShape(label, using: &random)
        }
        // Samples at the display rate over the gesture's duration, at least the
        // touch-down, one move and the lift.
        let count = max(Int((kind.duration * rate).rounded()) + 1, 3)
        var points = (0 ..< count).map { kind.shape(Double($0) / Double(count - 1)) }
        let isTap = label.gesture == .tap
        let spiked = degrade(&points, isTap: isTap, using: &random)
        // Intent space → screen: the aim is key-relative, so x widens with the
        // key (`GesturePreprocessor.normalizeAspectRatio` divides it back).
        let screen = points.map { CGPoint(x: $0.x * aspect, y: $0.y) }
        return LabGesture(
            label: label, positions: screen, aspectRatio: CGFloat(aspect),
            reach: kind.reach, sweepDegrees: kind.sweep, details: kind.details.merging(spiked) { $1 }.merging(["rate": rate]) { $1 }
        )
    }

    /// What a shape function hands back: the path, how long it takes, and the
    /// facts about it a report can slice by.
    struct Shape {
        var shape: (Double) -> CGPoint
        var duration: Double
        var reach: Double
        var sweep: Double
        var details: [String: Double] = [:]
    }

    // MARK: Shapes
    //
    // Each returns a position function over progress 0...1 in key-relative
    // ("intent") space, starting at the origin.

    private func tapShape(using random: inout LabRandom) -> Shape {
        let drift = random.range(profile.tapDrift)
        let heading = random.range(0 ... 2 * .pi)
        let target = CGPoint(x: cos(heading) * drift, y: sin(heading) * drift)
        return Shape(shape: { t in CGPoint(x: target.x * t, y: target.y * t) }, duration: random.range(0.04 ... 0.25), reach: 0, sweep: 0, details: ["drift": drift])
    }

    private func flickShape(_ label: LabLabel, using random: inout LabRandom) -> Shape {
        let length = random.range(profile.flickLength)
        let aimOffset = random.range(-profile.aimSpread ... profile.aimSpread)
        let aim = ((label.centerDegrees ?? 0) + aimOffset) * .pi / 180
        let direction = CGPoint(x: cos(aim), y: sin(aim))
        let normal = CGPoint(x: -direction.y, y: direction.x)
        let bow = random.range(-profile.bow ... profile.bow) * length

        let hookCap = profile.hookCap * length
        let startHook = random.chance(profile.startHookChance)
            ? min(random.range(profile.startHookSize), hookCap) : 0
        let startHeading = random.range(0 ... 2 * .pi)
        let endHook = random.chance(profile.endHookChance)
            ? min(random.range(profile.endHookSize), hookCap) : 0
        let endHeading = random.range(0 ... 2 * .pi)
        let overshoot = random.chance(profile.overshootChance) ? random.range(profile.overshoot) : 0

        let shape: (Double) -> CGPoint = { t in
            // Progress along the stroke: smooth, with an optional overshoot
            // that settles back to the end by the last sample.
            var along = Self.smootherstep(overshoot > 0 ? t / 0.8 : t)
            if overshoot > 0 {
                along = t < 0.8
                    ? along * (1 + overshoot)
                    : (1 + overshoot) + (1 - (1 + overshoot)) * Self.smootherstep((t - 0.8) / 0.2)
            }
            let sideways = bow * sin(.pi * t)
            var x = direction.x * length * along + normal.x * sideways
            var y = direction.y * length * along + normal.y * sideways
            // Settling at touch-down: a bump that is gone by 20% of the way.
            if startHook > 0, t < 0.2 {
                let bump = sin(.pi * t / 0.2) * startHook
                x += cos(startHeading) * bump
                y += sin(startHeading) * bump
            }
            // Flick-off at lift: a deflection that grows until the last sample.
            if endHook > 0, t > 0.85 {
                let u = (t - 0.85) / 0.15
                x += cos(endHeading) * endHook * u * u
                y += sin(endHeading) * endHook * u * u
            }
            return CGPoint(x: x, y: y)
        }
        return Shape(
            shape: shape, duration: random.range(profile.flickDuration), reach: length, sweep: 0,
            details: ["startHook": startHook, "endHook": endHook, "overshoot": overshoot, "bow": abs(bow) / length, "aim": abs(aimOffset)]
        )
    }

    private func returnShape(_ label: LabLabel, using random: inout LabRandom) -> Shape {
        let length = random.range(profile.returnLength)
        let aim = ((label.centerDegrees ?? 0) + random.range(-profile.aimSpread ... profile.aimSpread)) * .pi / 180
        let direction = CGPoint(x: cos(aim), y: sin(aim))
        let normal = CGPoint(x: -direction.y, y: direction.x)
        let residual = random.range(profile.returnResidual)
        let offset = random.range(profile.returnOffset) * length * (random.chance(0.5) ? 1 : -1)
        let turn = random.range(0.38 ... 0.62)
        let bow = random.range(-profile.bow ... profile.bow) * length

        let shape: (Double) -> CGPoint = { t in
            let along: Double
            var sideways = bow * sin(.pi * min(t / turn, 1))
            if t < turn {
                along = Self.smootherstep(t / turn)
            } else {
                let u = (t - turn) / (1 - turn)
                along = 1 - Self.smootherstep(u) * (1 - residual)
                // The way back runs beside the way out, not on it.
                sideways += offset * sin(.pi * u)
            }
            return CGPoint(
                x: direction.x * length * along + normal.x * sideways,
                y: direction.y * length * along + normal.y * sideways
            )
        }
        return Shape(
            shape: shape, duration: random.range(profile.returnDuration), reach: length, sweep: 0,
            details: ["residual": residual, "offset": abs(offset) / length, "turn": turn]
        )
    }

    private func circleShape(clockwise: Bool, using random: inout LabRandom) -> Shape {
        let ratio = random.range(profile.circleAspect)
        // The minor semi-axis keeps a floor: a 2:1 ellipse 14 points tall is a
        // twitch of the thumb, not a circle anyone draws on purpose.
        let major = max(random.range(profile.circleRadius), profile.circleMinorFloor / ratio)
        let minor = major * ratio
        let tilt = random.range(0 ... .pi)
        let start = random.range(0 ... 2 * .pi)
        let sweep = random.range(profile.circleSweep)
        let wobble = random.range(profile.circleWobble)
        let wobbleLobes = Double(random.pick([2, 3, 4]))
        let wobblePhase = random.range(0 ... 2 * .pi)
        let direction: Double = clockwise ? 1 : -1

        // Screen y points down, so a growing angle runs clockwise.
        func point(_ phi: Double) -> CGPoint {
            let radial = 1 + wobble * sin(wobbleLobes * phi + wobblePhase)
            let ex = major * radial * cos(phi)
            let ey = minor * radial * sin(phi)
            return CGPoint(
                x: ex * cos(tilt) - ey * sin(tilt),
                y: ex * sin(tilt) + ey * cos(tilt)
            )
        }
        let origin = point(start)
        let shape: (Double) -> CGPoint = { t in
            let p = point(start + direction * sweep * .pi / 180 * Self.smootherstep(t))
            return CGPoint(x: p.x - origin.x, y: p.y - origin.y)
        }
        return Shape(
            shape: shape, duration: random.range(profile.circleDuration), reach: 2 * major, sweep: sweep,
            details: ["ellipse": minor / major, "wobble": wobble, "radius": major]
        )
    }

    // MARK: Digitizer

    /// Jitter, dropped and repeated samples, one spike. The first sample stays
    /// the origin: translations are measured from touch-down.
    @discardableResult
    private func degrade(_ points: inout [CGPoint], isTap: Bool, using random: inout LabRandom) -> [String: Double] {
        var details: [String: Double] = [:]
        let sigma = random.range(profile.jitter)
        details["jitter"] = sigma
        for i in 1 ..< points.count {
            points[i].x += random.gaussian() * sigma
            points[i].y += random.gaussian() * sigma
        }
        if points.count > 4, random.chance(profile.spikeChance) {
            let i = 1 + random.index(points.count - 2)
            // A tap's spike stays below the swipe threshold: a recogniser is
            // not asked to see through a finger that really moved.
            let size = isTap ? random.range(8 ... 14) : random.range(profile.spikeSize)
            let heading = random.range(0 ... 2 * .pi)
            points[i].x += cos(heading) * size
            points[i].y += sin(heading) * size
            details["spike"] = size
        }
        var kept: [CGPoint] = [points[0]]
        for i in 1 ..< points.count - 1 {
            if random.chance(profile.dropChance) { continue }
            kept.append(points[i])
            if random.chance(profile.repeatChance) { kept.append(points[i]) }
        }
        kept.append(points[points.count - 1])
        points = kept
        return details
    }

    private static func smootherstep(_ t: Double) -> Double {
        let c = min(max(t, 0), 1)
        return c * c * c * (c * (c * 6 - 15) + 10)
    }
}

// MARK: - Randomness

/// SplitMix64 with the draws the generator needs, kept apart from the
/// scenario kit's `SplitMix64` conformance so the lab's sequences are defined
/// here and nowhere else.
struct LabRandom: Sendable {
    private var base: SplitMix64

    init(seed: UInt64) {
        base = SplitMix64(seed: seed)
        // The first outputs of nearby seeds are correlated; skip them.
        for _ in 0 ..< 4 { _ = base.next() }
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double {
        Double(base.next() >> 11) / Double(1 << 53)
    }

    mutating func range(_ r: ClosedRange<Double>) -> Double {
        r.lowerBound + (r.upperBound - r.lowerBound) * unit()
    }

    mutating func chance(_ p: Double) -> Bool {
        unit() < p
    }

    /// Uniform in 0 ..< n.
    mutating func index(_ n: Int) -> Int {
        min(Int(unit() * Double(n)), n - 1)
    }

    mutating func pick<T>(_ values: [T]) -> T {
        values[index(values.count)]
    }

    /// Standard normal (Box-Muller).
    mutating func gaussian() -> Double {
        let u1 = max(unit(), 1e-12)
        let u2 = unit()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}

// MARK: - Confusion matrix

/// Truth against verdict over a set of lab gestures.
struct ConfusionMatrix: Sendable {
    private(set) var labels: [LabLabel]
    /// `counts[truth][verdict]`, indexed like `labels`.
    private(set) var counts: [[Int]]

    init(labels: [LabLabel] = LabLabel.all) {
        self.labels = labels
        counts = Array(repeating: Array(repeating: 0, count: labels.count), count: labels.count)
    }

    /// Runs `gestures` through `classify` and tallies the verdicts.
    init(
        gestures: [LabGesture],
        labels: [LabLabel] = LabLabel.all,
        classify: (LabGesture) -> GestureClassification
    ) {
        self.init(labels: labels)
        for gesture in gestures { record(truth: gesture.label, verdict: LabLabel(classify(gesture))) }
    }

    mutating func record(truth: LabLabel, verdict: LabLabel) {
        guard let row = labels.firstIndex(of: truth), let column = labels.firstIndex(of: verdict) else { return }
        counts[row][column] += 1
    }

    func total(of label: LabLabel) -> Int {
        guard let row = labels.firstIndex(of: label) else { return 0 }
        return counts[row].reduce(0, +)
    }

    func correct(of label: LabLabel) -> Int {
        guard let row = labels.firstIndex(of: label) else { return 0 }
        return counts[row][row]
    }

    /// Fraction of `label`'s gestures classified as `label`.
    func accuracy(of label: LabLabel) -> Double {
        let total = total(of: label)
        return total == 0 ? 1 : Double(correct(of: label)) / Double(total)
    }

    /// Fraction of the gestures of all `labels` classified correctly.
    func accuracy(of group: [LabLabel]) -> Double {
        let total = group.reduce(0) { $0 + self.total(of: $1) }
        let correct = group.reduce(0) { $0 + self.correct(of: $1) }
        return total == 0 ? 1 : Double(correct) / Double(total)
    }

    var overallAccuracy: Double { accuracy(of: labels) }

    /// The matrix as text: rows are what was meant, columns what the
    /// classifier said, zeros as dots, the diagonal bracketed.
    func render(title: String = "") -> String {
        let width = 5
        var lines: [String] = []
        if !title.isEmpty { lines.append(title) }
        let header = "meant \\ said".padding(toLength: 13, withPad: " ", startingAt: 0)
            + labels.map { Self.pad($0.abbreviation, width) }.joined() + "   accuracy"
        lines.append(header)
        for (row, label) in labels.enumerated() {
            let total = counts[row].reduce(0, +)
            guard total > 0 else { continue }
            var line = label.abbreviation.padding(toLength: 13, withPad: " ", startingAt: 0)
            for column in labels.indices {
                let n = counts[row][column]
                let cell = n == 0 ? "." : (row == column ? "[\(n)]" : "\(n)")
                line += Self.pad(cell, width)
            }
            line += String(format: "   %6.2f%%  (%d)", accuracy(of: label) * 100, total)
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// The `limit` most frequent mistakes as `meant → said: count`.
    func worstConfusions(limit: Int = 8) -> [(meant: LabLabel, said: LabLabel, count: Int)] {
        var all: [(LabLabel, LabLabel, Int)] = []
        for row in labels.indices {
            for column in labels.indices where row != column && counts[row][column] > 0 {
                all.append((labels[row], labels[column], counts[row][column]))
            }
        }
        return all.sorted { $0.2 > $1.2 }.prefix(limit).map { (meant: $0.0, said: $0.1, count: $0.2) }
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        String(repeating: " ", count: max(0, width - text.count)) + text
    }
}

extension GestureLab {
    /// Classifies `gestures` with the production thresholds and settings
    /// snapshot, as the input engine would on release.
    static func classify(
        _ gesture: LabGesture, tuning: GestureTuning = .default
    ) -> GestureClassification {
        KeyGestureRecognizer.classify(
            positions: gesture.positions, aspectRatio: gesture.aspectRatio, tuning: tuning
        )
    }

    /// The matrix of `count` gestures per class in `labels`.
    func matrix(
        labels: [LabLabel] = LabLabel.all, count: Int, tuning: GestureTuning = .default
    ) -> ConfusionMatrix {
        var matrix = ConfusionMatrix()
        for label in labels {
            let sample = gestures(label, count: count)
            for gesture in sample {
                matrix.record(truth: label, verdict: LabLabel(Self.classify(gesture, tuning: tuning)))
            }
        }
        return matrix
    }
}
