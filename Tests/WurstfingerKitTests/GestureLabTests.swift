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
        expect(matrix, LabLabel.flicks, atLeast: 0.975, "realistic")
        expect(matrix, LabLabel.returns, atLeast: 0.98, "realistic")
        expect(matrix, LabLabel.circles, atLeast: 0.985, "realistic")
        #expect(matrix.accuracy(of: LabLabel.flicks) >= 0.983)
        #expect(matrix.accuracy(of: LabLabel.returns) >= 0.988)
        #expect(matrix.accuracy(of: LabLabel.circles) >= 0.988)
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

    @Test(.enabled(if: Self.reports)) func printMatrices() {
        let clean = Self.matrix(.clean)
        let realistic = Self.matrix(.realistic)
        print(clean.render(title: "\n== LAB clean thumb =="))
        print(realistic.render(title: "\n== LAB realistic thumb =="))
        for c in realistic.worstConfusions(limit: 10) { print("  \(c.meant) -> \(c.said): \(c.count)") }
    }
}
