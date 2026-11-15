//
//  GestureLabTests.swift
//  WurstfingerTests
//
//  The gesture accuracy lab (`GestureLab`, in the scenario kit): labelled
//  synthetic thumbs run through the production classifier, asserted as
//  accuracy floors per class. The floors sit just under the measured numbers,
//  so a change to the classifier that costs accuracy anywhere fails here, and
//  a change that buys some can raise them.
//

import CoreGraphics
import Foundation
import Testing
@testable import WurstfingerKit
@testable import WurstfingerScenarioKit

struct GestureLabTests {
    /// Gestures per class. Enough that a floor of 99.5% means something
    /// (five misses in a thousand), few enough to run in about a second.
    private static let perClass = 1000

    /// The `print…` tests are the lab's reports: slow, and for a human. Run them
    /// with `GESTURE_LAB_REPORT=1 swift test --filter GestureLabTests`.
    private static let reports = ProcessInfo.processInfo.environment["GESTURE_LAB_REPORT"] != nil

    private static func matrix(
        _ profile: LabProfile, labels: [LabLabel] = LabLabel.all, count: Int = perClass, seed: UInt64 = 0x1AB_5EED
    ) -> ConfusionMatrix {
        GestureLab(profile: profile, seed: seed).matrix(labels: labels, count: count)
    }

    // MARK: Generator

    @Test func theGeneratorIsDeterministic() {
        let a = GestureLab(seed: 7).gestures(.clockwise, count: 5)
        let b = GestureLab(seed: 7).gestures(.clockwise, count: 5)
        let c = GestureLab(seed: 8).gestures(.clockwise, count: 5)
        #expect(a.map(\.positions) == b.map(\.positions))
        #expect(a.map(\.positions) != c.map(\.positions))
    }

    @Test func everyPathStartsAtTheOriginWithAtLeastThreeSamples() {
        let lab = GestureLab()
        for label in LabLabel.all {
            for gesture in lab.gestures(label, count: 50) {
                #expect(gesture.positions.first == .zero)
                #expect(gesture.positions.count >= 3)
                #expect(gesture.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite })
            }
        }
    }

    @Test func aProfileChangeMovesOnlyTheClassesItTouches() {
        var changed = LabProfile.realistic
        changed.circleSweep = 400 ... 410
        let before = GestureLab(profile: .realistic).gestures(.tap, count: 20)
        let after = GestureLab(profile: changed).gestures(.tap, count: 20)
        #expect(before.map(\.positions) == after.map(\.positions))
    }

    @Test func circlesRunTheWayTheyWereDrawn() {
        // The label's direction is the on-screen one: y points down, so a
        // growing angle is clockwise.
        let clean = GestureLab(profile: .clean)
        for gesture in clean.gestures(.clockwise, count: 20) {
            #expect(signedArea(gesture.positions) > 0)
        }
        for gesture in clean.gestures(.counterclockwise, count: 20) {
            #expect(signedArea(gesture.positions) < 0)
        }
    }

    private func signedArea(_ points: [CGPoint]) -> Double {
        var area = 0.0
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            area += Double(a.x * b.y - b.x * a.y)
        }
        return area / 2
    }

    // MARK: Accuracy floors
    //
    // Measured with the final recogniser at 1000 gestures per class from the
    // default seed, then set a little under: clean thumbs are perfect, the
    // realistic profile (hooks, bow, overshoot, spikes, dropped samples, 60 and
    // 120 Hz, ellipses, 270-450 degree arcs) loses a point on its short flicks.
    // Before the lab-driven changes the same profile read circles at 96.7% /
    // 95.2% (clockwise / counter-clockwise) and returns at 97.6-98.5%.

    private func expect(
        _ matrix: ConfusionMatrix, _ labels: [LabLabel], atLeast floor: Double,
        _ context: Comment, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for label in labels {
            #expect(
                matrix.accuracy(of: label) >= floor,
                "\(context): \(label) \(matrix.accuracy(of: label) * 100)% < \(floor * 100)%\n\(matrix.render())",
                sourceLocation: sourceLocation
            )
        }
    }

    @Test func aSteadyThumbIsReadPerfectly() {
        let matrix = Self.matrix(.clean)
        expect(matrix, LabLabel.all, atLeast: 0.995, "clean")
    }

    @Test func everyClassOfARealisticThumbClearsItsFloor() {
        let matrix = Self.matrix(.realistic)
        expect(matrix, [.tap], atLeast: 0.995, "realistic")
        expect(matrix, LabLabel.flicks, atLeast: 0.98, "realistic")
        expect(matrix, LabLabel.returns, atLeast: 0.99, "realistic")
        expect(matrix, LabLabel.circles, atLeast: 0.995, "realistic")
        #expect(matrix.accuracy(of: LabLabel.flicks) >= 0.989)
        #expect(matrix.accuracy(of: LabLabel.returns) >= 0.995)
        #expect(matrix.accuracy(of: LabLabel.circles) >= 0.997)
    }

    @Test func circlesHoldAtScaleInBothDirections() {
        // 6000 per direction: at a thousand a single spiked circle is a tenth of
        // a percent. Measured cw 99.70%, ccw 99.65%.
        let matrix = Self.matrix(.realistic, labels: LabLabel.circles, count: 6000)
        expect(matrix, LabLabel.circles, atLeast: 0.995, "realistic circles at 6000")
    }

    /// The sloppiness profiles, with the floors each must clear: taps, flicks,
    /// returns, circles. Measured at 1500 per class, set a few tenths under. Before the forgiveness mechanisms (quick-flick rule, key scaling,
    /// direction from the body of the stroke, circle fit, spike filter) the same
    /// profiles read: fast typing flicks 74.0%, small keys flicks 84.6%, boundary
    /// aim returns 94.3%, fast typing returns 95.1%, leaning returns 98.1%.
    private static let sloppinessFloors: [(name: String, floors: (tap: Double, flick: Double, ret: Double, circle: Double))] = [
        ("fast typing", (0.995, 0.97, 0.985, 0.985)),
        ("hooky", (0.995, 0.99, 0.995, 0.995)),
        ("leaning", (0.995, 0.993, 0.98, 0.995)),
        ("small keys", (0.992, 0.985, 0.988, 0.99)),
        ("large keys", (0.995, 0.995, 0.995, 0.992)),
        ("boundary aim", (0.995, 0.99, 0.99, 0.995)),
    ]

    @Test(arguments: sloppinessFloors.map(\.name))
    func aSloppyThumbClearsItsFloors(_ name: String) throws {
        let entry = try #require(Self.sloppinessFloors.first { $0.name == name })
        let profile = try #require(LabProfile.sloppiness.first { $0.name == name }).profile
        let matrix = Self.matrix(profile, count: 1500)
        #expect(matrix.accuracy(of: [.tap]) >= entry.floors.tap, "\(name) taps\n\(matrix.render())")
        #expect(matrix.accuracy(of: LabLabel.flicks) >= entry.floors.flick, "\(name) flicks\n\(matrix.render())")
        #expect(matrix.accuracy(of: LabLabel.returns) >= entry.floors.ret, "\(name) returns\n\(matrix.render())")
        #expect(matrix.accuracy(of: LabLabel.circles) >= entry.floors.circle, "\(name) circles\n\(matrix.render())")
    }

    @Test func aHesitantFingersDriftStaysATap() {
        let matrix = Self.matrix(.slowDrift, labels: [.tap], count: 3000)
        #expect(matrix.accuracy(of: .tap) >= 0.995, "\(matrix.render())")
    }

    @Test func aTraceReplaysThroughTheLab() throws {
        // A recorded gesture, as JSON, classifies exactly like the one it was
        // recorded from.
        let source = GestureLab(profile: .realistic).gestures(.counterclockwise, count: 5)
        for gesture in source {
            let trace = GestureTrace(gesture)
            let data = try JSONEncoder().encode(trace)
            let replayed = try JSONDecoder().decode(GestureTrace.self, from: data).gesture
            #expect(replayed.positions == gesture.positions)
            #expect(LabLabel(GestureLab.classify(replayed)) == LabLabel(GestureLab.classify(gesture)))
        }
    }

    @Test func flicksLongerThanAThirdOfAKeyAreReadAlmostAlways() {
        // Below ~28 points a flick sits on the 20 point tap threshold, where
        // a verdict of "tap" is the recogniser doing what it is told; above, the
        // only misses are aim within a few degrees of a sector line plus a
        // lift-off hook.
        var profile = LabProfile.realistic
        profile.flickLength = 30 ... 90
        let matrix = Self.matrix(profile, labels: LabLabel.flicks)
        expect(matrix, LabLabel.flicks, atLeast: 0.993, "flicks >= 30")
    }

    @Test func aTapNeverBecomesAFlickWhateverTheHandDoes() {
        // The one error that types a wrong letter from a deliberate tap. Drift
        // up to the swipe length's third, jitter and a digitizer spike.
        var profile = LabProfile.realistic
        profile.tapDrift = 0 ... 8
        let matrix = Self.matrix(profile, labels: [.tap], count: 3000)
        #expect(matrix.accuracy(of: .tap) >= 0.998, "\(matrix.render())")
    }

    @Test func smallEllipsesAreStillCircles() {
        // The farthest point of a 34 x 17 point ellipse from where it began can
        // be under the 20 point swipe length; the circle must win over the tap.
        var profile = LabProfile.realistic
        profile.circleRadius = 17 ... 20
        profile.circleAspect = 0.5 ... 0.55
        profile.circleSweep = 360 ... 420
        profile.spikeChance = 0
        let matrix = Self.matrix(profile, labels: LabLabel.circles)
        expect(matrix, LabLabel.circles, atLeast: 0.97, "small ellipses")
    }

    @Test func circlesAtHighSampleRatesAreNotLostToTremor() {
        // 120 Hz samples a slow circle every point or two, where sub-point
        // jitter flips a third of the raw turns; the count must see through it.
        var profile = LabProfile.clean
        profile.sampleRates = [120]
        profile.circleDuration = 0.7 ... 0.9
        profile.jitter = 0.6 ... 0.9
        let matrix = Self.matrix(profile, labels: LabLabel.circles)
        expect(matrix, LabLabel.circles, atLeast: 0.985, "slow 120 Hz circles")
    }

    @Test func cSizedArcsAreCirclesButAHalfTurnIsNot() {
        var arcs = LabProfile.clean
        arcs.circleSweep = 290 ... 310
        arcs.circleAspect = 0.85 ... 1
        expect(Self.matrix(arcs, labels: LabLabel.circles), LabLabel.circles, atLeast: 0.97, "290-310 degree arcs")

        // Return swipes whose way back bows wide are not circles, and the
        // rounder of them (offset up to a third of the stroke) stay returns.
        var bowed = LabProfile.clean
        bowed.returnOffset = 0.2 ... 0.32
        expect(Self.matrix(bowed, labels: LabLabel.returns), LabLabel.returns, atLeast: 0.985, "bowed returns")
    }

    @Test func aMatrixCountsAndRenders() {
        var matrix = ConfusionMatrix(labels: [.tap, LabLabel(gesture: .swipeRight)])
        matrix.record(truth: .tap, verdict: .tap)
        matrix.record(truth: .tap, verdict: LabLabel(gesture: .swipeRight))
        matrix.record(truth: .tap, verdict: .clockwise) // outside the matrix: ignored
        #expect(matrix.total(of: .tap) == 2)
        #expect(matrix.accuracy(of: .tap) == 0.5)
        #expect(matrix.worstConfusions().first?.count == 1)
        #expect(matrix.render(title: "t").contains("50.00%"))
    }


    /// Accuracy of `label`'s gestures per bucket of a value, for the report.
    private func slice(_ label: LabLabel, _ lab: GestureLab, by value: (LabGesture) -> Double, edges: [Double], name: String) -> String {
        let gestures = lab.gestures(label, count: 4000)
        var parts: [String] = []
        for (lo, hi) in zip(edges, edges.dropFirst()) {
            let bucket = gestures.filter { value($0) >= lo && value($0) < hi }
            guard !bucket.isEmpty else { continue }
            let hits = bucket.filter { LabLabel(GestureLab.classify($0)) == label }.count
            parts.append(String(format: "[%g,%g) %.1f%% (%d)", lo, hi, 100 * Double(hits) / Double(bucket.count), bucket.count))
        }
        return "\(label) by \(name): " + parts.joined(separator: "  ")
    }

    @Test(.enabled(if: Self.reports)) func printSlices() {
        let lab = GestureLab(profile: .realistic)
        var out: [String] = ["\n== LAB slices =="]
        for l in [LabLabel.clockwise, .counterclockwise] {
            out.append(slice(l, lab, by: { $0.sweepDegrees }, edges: [270, 300, 330, 360, 400, 451], name: "sweep"))
            out.append(slice(l, lab, by: { $0.details["ellipse"] ?? 1 }, edges: [0.5, 0.6, 0.7, 0.8, 0.9, 1.01], name: "ellipse"))
            out.append(slice(l, lab, by: { $0.details["radius"] ?? 1 }, edges: [14, 18, 22, 26, 31], name: "radius"))
            out.append(slice(l, lab, by: { $0.details["wobble"] ?? 0 }, edges: [0, 0.03, 0.06, 0.11], name: "wobble"))
        }
        for l in [LabLabel(gesture: .swipeRight), LabLabel(gesture: .swipeDownRight), LabLabel(gesture: .swipeUp)] {
            out.append(slice(l, lab, by: { $0.reach }, edges: [20, 24, 28, 34, 45, 91], name: "length"))
            out.append(slice(l, lab, by: { $0.details["endHook"] ?? 0 }, edges: [0, 0.01, 3, 5, 8], name: "endHook"))
            out.append(slice(l, lab, by: { $0.details["startHook"] ?? 0 }, edges: [0, 0.01, 3, 5, 7], name: "startHook"))
            out.append(slice(l, lab, by: { $0.details["aim"] ?? 0 }, edges: [0, 6, 12, 15, 19], name: "aim"))
            out.append(slice(l, lab, by: { $0.details["spike"] ?? 0 }, edges: [0, 0.01, 30, 46], name: "spike"))
        }
        for l in [LabLabel(gesture: .swipeRight, isReturn: true), LabLabel(gesture: .swipeUpLeft, isReturn: true)] {
            out.append(slice(l, lab, by: { $0.reach }, edges: [28, 35, 45, 60, 81], name: "reach"))
            out.append(slice(l, lab, by: { $0.details["offset"] ?? 0 }, edges: [0, 0.1, 0.2, 0.31], name: "offset"))
            out.append(slice(l, lab, by: { $0.details["residual"] ?? 0 }, edges: [0, 0.1, 0.2, 0.3, 0.41], name: "residual"))
            out.append(slice(l, lab, by: { $0.details["turn"] ?? 0 }, edges: [0.38, 0.45, 0.55, 0.63], name: "turn"))
        }
        print(out.joined(separator: "\n"))
    }

    @Test(.enabled(if: Self.reports)) func printAblation() {
        var out: [String] = ["\n== LAB ablation (accuracy: flicks / returns / circles / taps) =="]
        func row(_ name: String, _ edit: (inout LabProfile) -> Void) {
            var p = LabProfile.realistic
            edit(&p)
            let m = Self.matrix(p, count: 1500)
            out.append(String(format: "%-28@ %.2f%% / %.2f%% / %.2f%% / %.2f%%", name as NSString,
                100 * m.accuracy(of: LabLabel.flicks), 100 * m.accuracy(of: LabLabel.returns),
                100 * m.accuracy(of: LabLabel.circles), 100 * m.accuracy(of: [.tap])))
        }
        row("realistic") { _ in }
        row("no spikes") { $0.spikeChance = 0 }
        row("no drops/repeats") { $0.dropChance = 0; $0.repeatChance = 0 }
        row("no hooks") { $0.startHookChance = 0; $0.endHookChance = 0 }
        row("no overshoot") { $0.overshootChance = 0 }
        row("no bow") { $0.bow = 0 }
        row("aim spread 8") { $0.aimSpread = 8 }
        row("flicks >= 30") { $0.flickLength = 30 ... 90 }
        row("sweep >= 330") { $0.circleSweep = 330 ... 450 }
        row("circle aspect >= .8") { $0.circleAspect = 0.8 ... 1 }
        row("no wobble") { $0.circleWobble = 0 ... 0 }
        row("return offset <= .15") { $0.returnOffset = 0.04 ... 0.15 }
        row("jitter 0.2-0.4") { $0.jitter = 0.2 ... 0.4 }
        row("only 120Hz") { $0.sampleRates = [120] }
        row("only 60Hz") { $0.sampleRates = [60] }
        print(out.joined(separator: "\n"))
    }

    /// The features of the gestures of `label` the classifier read as something
    /// else, with what it said: where a threshold needs to move, it shows.
    private func failures(_ label: LabLabel, said predicate: (LabLabel) -> Bool, limit: Int = 30, reachAtLeast: Double = 0) -> [String] {
        let lab = GestureLab(profile: .realistic)
        var out: [String] = ["\n== LAB failures of \(label) =="]
        for g in lab.gestures(label, count: 6000) where g.details["spike"] == nil && g.reach >= reachAtLeast {
            let c = GestureLab.classify(g)
            guard LabLabel(c) != label, predicate(LabLabel(c)), out.count <= limit else { continue }
            let cfg = GestureTuning.default.config.with(aspectRatio: g.aspectRatio)
            let pre = GesturePreprocessor(config: cfg).preprocess(g.positions)
            let f = GestureFeatures.extract(from: pre, thresholds: .default)
            out.append(String(format: "said %@ n=%d->%d aim=%.0f sh=%.1f eh=%.1f ov=%.2f bow=%.2f reach=%.0f sweep=%.0f off=%.2f res=%.2f ell=%.2f | span=%.0f circ=%.2f turn=%.2f compact=%.2f len=%.0f ret=%.2f prog=%.2f",
                LabLabel(c).abbreviation as NSString, g.positions.count, pre.count, g.details["aim"] ?? 0, g.details["startHook"] ?? 0,
                g.details["endHook"] ?? 0, g.details["overshoot"] ?? 0, g.details["bow"] ?? 0, g.reach, g.sweepDegrees,
                g.details["offset"] ?? 0, g.details["residual"] ?? 0, g.details["ellipse"] ?? 0,
                f.angularSpan * 180 / .pi, f.circularity, f.turnConsistency, f.orientedCompactness,
                f.pathLength, f.returnRatio, f.maxDisplacementProgress))
        }
        return out
    }

    @Test(.enabled(if: Self.reports)) func printFailures() {
        var out = failures(LabLabel(gesture: .swipeRight), said: { _ in true }, reachAtLeast: 30)
        out += failures(LabLabel(gesture: .swipeDownRight), said: { _ in true }, reachAtLeast: 30)
        out += failures(.counterclockwise, said: { _ in true })
        out += failures(LabLabel(gesture: .swipeUpLeft, isReturn: true), said: { $0.gesture.isCircular })
        out += failures(LabLabel(gesture: .swipeDown, isReturn: true), said: { !$0.gesture.isCircular }, limit: 12)
        print(out.joined(separator: "\n"))
    }

    @Test(.enabled(if: Self.reports)) func printThresholdSweep() {
        var out = ["\n== LAB threshold sweep: flicks / returns / circles / taps =="]
        let base = GestureClassificationThresholds.default
        for span in [270.0, 255] {
            for compact in [0.4, 0.45, 0.5] {
                let t = GestureClassificationThresholds(
                    minSwipeLength: base.minSwipeLength, maxReturnRatio: base.maxReturnRatio,
                    returnDisplacementRange: base.returnDisplacementRange, minCircularity: base.minCircularity,
                    minAngularSpan: span * .pi / 180, minPathSeparation: base.minPathSeparation,
                    minTurnConsistency: base.minTurnConsistency, minOrientedCompactness: compact
                )
                var tuning = GestureTuning.default
                tuning.thresholds = t
                let m = GestureLab(profile: .realistic).matrix(count: 1500, tuning: tuning)
                var wide = LabProfile.realistic
                wide.returnOffset = 0.35 ... 0.7
                let u = GestureLab(profile: wide).matrix(labels: LabLabel.returns, count: 1500, tuning: tuning)
                out.append(String(format: "span %.0f compact %.2f: %.2f%% / %.2f%% / %.2f%% / %.2f%%   wide U-bends kept as returns: %.2f%%", span, compact,
                    100 * m.accuracy(of: LabLabel.flicks), 100 * m.accuracy(of: LabLabel.returns),
                    100 * m.accuracy(of: LabLabel.circles), 100 * m.accuracy(of: [.tap]),
                    100 * u.accuracy(of: LabLabel.returns)))
            }
        }
        print(out.joined(separator: "\n"))
    }

    /// Every profile's matrix, in full, plus a one-line summary each: the
    /// before/after report. `GESTURE_LAB_OUT=<file>` also writes it to a file.
    @Test(.enabled(if: Self.reports)) func printProfiles() {
        var named: [(String, LabProfile)] = [("clean", .clean), ("realistic", .realistic), ("slow drift", .slowDrift)]
        named += LabProfile.sloppiness.map { ($0.name, $0.profile) }
        var summary = ["\n== LAB profiles: taps / flicks / returns / circles =="]
        var full: [String] = []
        for (name, profile) in named {
            let m = Self.matrix(profile, count: 1500)
            summary.append(String(format: "%-14@ %6.2f%% / %6.2f%% / %6.2f%% / %6.2f%%", name as NSString,
                100 * m.accuracy(of: [.tap]), 100 * m.accuracy(of: LabLabel.flicks),
                100 * m.accuracy(of: LabLabel.returns), 100 * m.accuracy(of: LabLabel.circles)))
            full.append(m.render(title: "\n== \(name) =="))
        }
        let text = (summary + full).joined(separator: "\n")
        print(text)
        if let path = ProcessInfo.processInfo.environment["GESTURE_LAB_OUT"] {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Direction estimators (research)

    private func degrees(_ v: CGVector) -> Double {
        var d = atan2(Double(v.dy), Double(v.dx)) * 180 / .pi
        if d < 0 { d += 360 }
        return d
    }

    private func sector(_ degrees: Double) -> GestureType {
        KeyGestureRecognizer.gestureType(forDegrees: CGFloat(degrees))
    }

    /// The point at arc length `fraction` of the way along `path[0...upTo]`.
    private func point(at fraction: Double, along path: [CGPoint], upTo: Int) -> CGPoint {
        var total = 0.0
        for i in 1 ... upTo { total += Double(path[i - 1].distance(to: path[i])) }
        var walked = 0.0
        for i in 1 ... upTo {
            let step = Double(path[i - 1].distance(to: path[i]))
            if walked + step >= fraction * total, step > 0 {
                let t = (fraction * total - walked) / step
                return CGPoint(x: path[i - 1].x + (path[i].x - path[i - 1].x) * t, y: path[i - 1].y + (path[i].y - path[i - 1].y) * t)
            }
            walked += step
        }
        return path[upTo]
    }

    private func estimates(for path: [CGPoint]) -> [String: Double] {
        guard path.count >= 3 else { return [:] }
        var f = 0
        var best: CGFloat = 0
        for i in path.indices where hypot(path[i].x, path[i].y) > best { best = hypot(path[i].x, path[i].y); f = i }
        guard f >= 2 else { return [:] }
        var out: [String: Double] = [:]
        let o = path[0]
        func angle(from a: CGPoint, to b: CGPoint) -> Double { degrees(CGVector(dx: b.x - a.x, dy: b.y - a.y)) }
        out["maxdisp"] = angle(from: o, to: path[f])
        out["chord-end"] = angle(from: o, to: path[path.count - 1])
        for frac in [0.7, 0.85] {
            out["arc\(Int(frac * 100))"] = angle(from: o, to: point(at: frac, along: path, upTo: f))
        }
        // Principal axis of the cruise (15%-90% of the way to the farthest point).
        var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0, n = 0.0
        for k in 0 ... 40 {
            let q = point(at: 0.15 + 0.75 * Double(k) / 40, along: path, upTo: f)
            sx += Double(q.x); sy += Double(q.y); n += 1
            sxx += Double(q.x * q.x); syy += Double(q.y * q.y); sxy += Double(q.x * q.y)
        }
        let cxx = sxx / n - (sx / n) * (sx / n), cyy = syy / n - (sy / n) * (sy / n), cxy = sxy / n - (sx / n) * (sy / n)
        var theta = 0.5 * atan2(2 * cxy, cxx - cyy)
        if cos(theta) * Double(path[f].x) + sin(theta) * Double(path[f].y) < 0 { theta += .pi }
        out["pca"] = (theta * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        // Dominant two-step window: the fastest part of the stroke.
        var windowBest = 0.0, window = (0, 2)
        for i in 0 ..< path.count - 2 {
            let len = Double(path[i].distance(to: path[i + 1]) + path[i + 1].distance(to: path[i + 2]))
            if len > windowBest { windowBest = len; window = (i, i + 2) }
        }
        out["fastest"] = angle(from: path[window.0], to: path[window.1])
        // Settle-trimmed origin: where the finger first left a 5 pt disc.
        var j = 0
        while j < f - 1, hypot(path[j].x - o.x, path[j].y - o.y) < 5 { j += 1 }
        out["settle"] = angle(from: path[max(j - 1, 0)], to: path[f])
        out["settle+arc85"] = angle(from: path[max(j - 1, 0)], to: point(at: 0.85, along: path, upTo: f))
        // Length-weighted mean of step directions over the cruise.
        var wx = 0.0, wy = 0.0
        for i in 1 ... f {
            let mid = Double(path[i - 1].distance(to: path[i]))
            guard mid > 0 else { continue }
            let dx = Double(path[i].x - path[i - 1].x), dy = Double(path[i].y - path[i - 1].y)
            wx += dx * mid; wy += dy * mid
        }
        out["step-mean"] = degrees(CGVector(dx: wx, dy: wy))
        func mean(_ names: [String]) -> Double {
            var x = 0.0, y = 0.0
            for n in names { let r = (out[n] ?? 0) * .pi / 180; x += cos(r); y += sin(r) }
            return degrees(CGVector(dx: x, dy: y))
        }
        out["ens(max,pca,s85)"] = mean(["maxdisp", "pca", "settle+arc85"])
        out["ens(+chord)"] = mean(["maxdisp", "pca", "settle+arc85", "chord-end"])
        out["ens(pca,s85)"] = mean(["pca", "settle+arc85"])
        out["ens(max,chord)"] = mean(["maxdisp", "chord-end"])
        out["ens(max,pca)"] = mean(["maxdisp", "pca"])
        return out
    }

    @Test(.enabled(if: Self.reports)) func printEstimators() {
        printEstimators(labels: LabLabel.flicks, title: "flicks")
        printEstimators(labels: LabLabel.returns, title: "returns (outbound leg)")
    }

    private func printEstimators(labels: [LabLabel], title: String) {
        var rows: [String: [String: (hit: Int, total: Int)]] = [:]
        var order: [String] = []
        var named: [(String, LabProfile)] = [("realistic", .realistic)]
        named += LabProfile.sloppiness.map { ($0.name, $0.profile) }
        for (name, profile) in named {
            order.append(name)
            let lab = GestureLab(profile: profile)
            for label in labels {
                for g in lab.gestures(label, count: 1500) {
                    let cfg = GestureTuning.default.config.with(aspectRatio: g.aspectRatio)
                    let pre = GesturePreprocessor(config: cfg).preprocess(g.positions)
                    guard pre.map({ hypot($0.x, $0.y) }).max() ?? 0 >= 20 else { continue }
                    for (estimator, angle) in estimates(for: pre) {
                        var cell = rows[estimator, default: [:]][name, default: (0, 0)]
                        cell.total += 1
                        if sector(angle) == label.gesture { cell.hit += 1 }  // direction only; the return flag is not asked
                        rows[estimator, default: [:]][name] = cell
                    }
                }
            }
        }
        var out = ["\n== LAB direction estimators: \(title) =="]
        out.append("estimator".padding(toLength: 14, withPad: " ", startingAt: 0) + order.map { $0.padding(toLength: 14, withPad: " ", startingAt: 0) }.joined())
        for estimator in rows.keys.sorted() {
            out.append(estimator.padding(toLength: 14, withPad: " ", startingAt: 0) + order.map {
                let c = rows[estimator]?[$0] ?? (0, 1)
                return String(format: "%.2f%%", 100 * Double(c.hit) / Double(max(c.total, 1))).padding(toLength: 14, withPad: " ", startingAt: 0)
            }.joined())
        }
        print(out.joined(separator: "\n"))
    }

    @Test(.enabled(if: Self.reports)) func printFastSweep() {
        var out = ["\n== LAB fast-swipe sweep: per profile taps / flicks =="]
        let profiles: [(String, LabProfile)] = [
            ("fast", .fastTyping), ("slow", .slowDrift), ("small", .smallKeys), ("real", .realistic),
        ]
        for length in [9.0, 11, 13, 15] {
            for speed in [60.0, 90, 120, 160, 220] {
                var tuning = GestureTuning.default
                tuning.thresholds.fastSwipeLength = length
                tuning.thresholds.fastSwipeSpeed = speed
                var line = String(format: "len %2.0f speed %3.0f:", length, speed)
                for (name, profile) in profiles {
                    let m = GestureLab(profile: profile).matrix(labels: [.tap] + LabLabel.flicks, count: 700, tuning: tuning)
                    line += String(format: "  %@ %.1f/%.1f", name as NSString, 100 * m.accuracy(of: [.tap]), 100 * m.accuracy(of: LabLabel.flicks))
                }
                out.append(line)
            }
        }
        print(out.joined(separator: "\n"))
    }

    @Test(.enabled(if: Self.reports)) func printFitSweep() {
        var out = ["\n== LAB circle-fit / compactness sweep: circles / returns per profile =="]
        let profiles: [(String, LabProfile)] = [
            ("real", .realistic), ("lean", .leaning), ("fast", .fastTyping), ("small", .smallKeys), ("large", .largeKeys),
        ]
        for compact in [0.4, 0.45, 0.5] {
            for fit in [0.2, 0.25, 0.3, 0.35, 0.45, 1.0] {
                let base = GestureClassificationThresholds.default
                var tuning = GestureTuning.default
                tuning.thresholds = GestureClassificationThresholds(
                    minSwipeLength: base.minSwipeLength, maxReturnRatio: base.maxReturnRatio,
                    returnDisplacementRange: base.returnDisplacementRange, minCircularity: base.minCircularity,
                    minAngularSpan: base.minAngularSpan, minPathSeparation: base.minPathSeparation,
                    minTurnConsistency: base.minTurnConsistency, minOrientedCompactness: compact,
                    fastSwipeLength: base.fastSwipeLength, fastSwipeSpeed: base.fastSwipeSpeed,
                    maxCircleFitResidual: fit
                )
                var line = String(format: "compact %.2f fit %.2f:", compact, fit)
                var circlesTotal = 0.0, returnsTotal = 0.0
                for (name, profile) in profiles {
                    let m = GestureLab(profile: profile).matrix(labels: LabLabel.returns + LabLabel.circles, count: 1000, tuning: tuning)
                    line += String(format: "  %@ %.2f/%.2f", name as NSString, 100 * m.accuracy(of: LabLabel.circles), 100 * m.accuracy(of: LabLabel.returns))
                    circlesTotal += m.accuracy(of: LabLabel.circles); returnsTotal += m.accuracy(of: LabLabel.returns)
                }
                line += String(format: "  | mean %.2f/%.2f", 20 * circlesTotal, 20 * returnsTotal)
                out.append(line)
            }
        }
        print(out.joined(separator: "\n"))
    }

    @Test(.enabled(if: Self.reports)) func printMechanismAblation() {
        var out = ["\n== LAB mechanism ablation: taps / flicks (fast, small, real, large, slow) =="]
        let profiles: [(String, LabProfile)] = [
            ("fast", .fastTyping), ("small", .smallKeys), ("real", .realistic), ("large", .largeKeys), ("slow", .slowDrift),
        ]
        func row(_ name: String, tuning: GestureTuning, useKeySize: Bool) {
            var line = name.padding(toLength: 22, withPad: " ", startingAt: 0)
            for (pname, profile) in profiles {
                let lab = GestureLab(profile: profile)
                var m = ConfusionMatrix()
                for label in [LabLabel.tap] + LabLabel.flicks {
                    for g in lab.gestures(label, count: 600) {
                        let r = KeyGestureRecognizer.classify(
                            positions: g.positions, aspectRatio: g.aspectRatio, tuning: tuning,
                            keySize: useKeySize ? g.keySize : CGSize(width: 58, height: 58), peakTime: g.peakTime
                        )
                        m.record(truth: label, verdict: LabLabel(r))
                    }
                }
                line += String(format: "  %@ %.1f/%.1f", pname as NSString, 100 * m.accuracy(of: [.tap]), 100 * m.accuracy(of: LabLabel.flicks))
            }
            out.append(line)
        }
        row("all mechanisms", tuning: .default, useKeySize: true)
        row("no key scaling", tuning: .default, useKeySize: false)
        var noFast = GestureTuning.default
        noFast.thresholds.fastSwipeSpeed = 100_000
        row("no fast-swipe rule", tuning: noFast, useKeySize: true)
        row("neither", tuning: noFast, useKeySize: false)
        print(out.joined(separator: "\n"))
    }

    @Test(.enabled(if: Self.reports)) func printCircleMissCauses() {
        var out = ["\n== LAB circle misses by cause (realistic, 6000 per direction) =="]
        let lab = GestureLab(profile: .realistic)
        for label in LabLabel.circles {
            var miss = 0, spiked = 0, dropped = 0, short = 0, total = 0
            var rows: [String] = []
            for g in lab.gestures(label, count: 6000) {
                total += 1
                let said = LabLabel(GestureLab.classify(g))
                guard said != label else { continue }
                miss += 1
                if g.details["spike"] != nil { spiked += 1 } else if g.sweepDegrees < 300 { short += 1 } else {
                    dropped += 1
                    if rows.count < 12 { rows.append(String(format: "  said %@ n=%d sweep=%.0f ell=%.2f R=%.0f rate=%.0f jit=%.2f", said.abbreviation as NSString, g.positions.count, g.sweepDegrees, g.details["ellipse"] ?? 0, g.details["radius"] ?? 0, g.details["rate"] ?? 0, g.details["jitter"] ?? 0)) }
                }
            }
            out.append("\(label): \(miss)/\(total) missed; \(spiked) with a spike, \(short) arcs under 300 degrees, \(dropped) other")
            out += rows
        }
        print(out.joined(separator: "\n"))
    }

    @Test(.enabled(if: Self.reports)) func printMatrices() {
        let clean = Self.matrix(.clean)
        let realistic = Self.matrix(.realistic)
        print(clean.render(title: "\n== LAB clean thumb =="))
        print(realistic.render(title: "\n== LAB realistic thumb =="))
        for c in realistic.worstConfusions(limit: 10) { print("  \(c.meant) -> \(c.said): \(c.count)") }
    }
}
