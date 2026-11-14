//
//  GestureForgivenessTests.swift
//  WurstfingerTests
//
//  The mechanisms that make the classifier forgiving, each pinned on a hand-made
//  path (the gesture lab, `GestureLabTests`, measures them in aggregate):
//  quick short flicks versus slow drift, thresholds that follow the key's size,
//  a direction read from the body of the stroke, a circle fit that tells a
//  flat loop from a circle, and the spike filter.
//

import CoreGraphics
import Foundation
import Testing
@testable import WurstfingerKit
@testable import WurstfingerScenarioKit

// MARK: - Helpers

private func line(length: CGFloat, degrees: CGFloat = 0, samples: Int = 6) -> [CGPoint] {
    let radians = degrees * .pi / 180
    return (0 ..< samples).map {
        let t = length * CGFloat($0) / CGFloat(samples - 1)
        return CGPoint(x: cos(radians) * t, y: sin(radians) * t)
    }
}

private let referenceKey = CGSize(width: 62, height: 58)

private func classify(
    _ points: [CGPoint], peakTime: TimeInterval = 0, keySize: CGSize = referenceKey,
    tuning: GestureTuning = .default
) -> GestureClassification {
    KeyGestureRecognizer.classify(positions: points, tuning: tuning, keySize: keySize, peakTime: peakTime)
}

// MARK: - Quick flicks and slow drift

struct FastSwipeTests {
    @Test func aQuick15PointFlickIsAFlick() {
        #expect(classify(line(length: 15), peakTime: 0.06).gesture == .swipeRight)
    }

    @Test func aSlow15PointDriftIsATap() {
        #expect(classify(line(length: 15), peakTime: 0.35).gesture == .tap)
    }

    @Test func withoutATimeTheOldThresholdHolds() {
        // Every caller that does not know the time (tests, tools, the array entry
        // points) gets exactly the 20 point rule.
        #expect(classify(line(length: 15)).gesture == .tap)
        #expect(classify(line(length: 22)).gesture == .swipeRight)
    }

    @Test func aQuickStrokeBelowTheFastLengthIsStillATap() {
        let floor = GestureClassificationThresholds.default.fastSwipeLength
        #expect(classify(line(length: floor - 2), peakTime: 0.04).gesture == .tap)
    }

    @Test func aGlitchInATapIsNotAFastFlick() {
        // One stray sample jumps 14 points away and straight back: the finger
        // never ended out there.
        let points: [CGPoint] = [.zero, CGPoint(x: 0.5, y: 0.3), CGPoint(x: 14, y: 2), CGPoint(x: 1, y: 0.5), CGPoint(x: 0.8, y: 0.2)]
        #expect(classify(points, peakTime: 0.03).gesture == .tap)
    }

    @Test func theSpeedIsTheReachOverTheTimeToGetThere() {
        // 16 points in 0.1 s is 160 pt/s: quick. In 0.2 s it is 80: a drift.
        #expect(classify(line(length: 16), peakTime: 0.1).gesture == .swipeRight)
        #expect(classify(line(length: 16), peakTime: 0.2).gesture == .tap)
    }

    @Test func theFastRuleRidesTheExpertThresholds() {
        var tuning = GestureTuning.default
        tuning.thresholds.fastSwipeSpeed = 400
        #expect(classify(line(length: 15), peakTime: 0.06, tuning: tuning).gesture == .tap)
        tuning.thresholds.fastSwipeSpeed = 100
        tuning.thresholds.fastSwipeLength = 18
        #expect(classify(line(length: 15), peakTime: 0.06, tuning: tuning).gesture == .tap)
    }
}

// MARK: - The key's size

struct KeyScaleTests {
    @Test func theThresholdsFollowTheKeyHeight() {
        // A 17 point stroke is a third of a 50 point key and a swipe there, a
        // sixth of a 100 point one and a tap there.
        let small = CGSize(width: 40, height: 38)
        let large = CGSize(width: 100, height: 100)
        #expect(classify(line(length: 17), keySize: small).gesture == .swipeRight)
        #expect(classify(line(length: 17), keySize: referenceKey).gesture == .tap)
        #expect(classify(line(length: 24), keySize: referenceKey).gesture == .swipeRight)
        #expect(classify(line(length: 24), keySize: large).gesture == .tap)
        #expect(classify(line(length: 42), keySize: large).gesture == .swipeRight)
    }

    @Test func theScaleIsClampedAndNeutralWhenUnknown() {
        #expect(GestureFeatures.keyScale(for: .zero) == 1)
        #expect(GestureFeatures.keyScale(for: CGSize(width: 10, height: 10)) == 0.7)
        #expect(GestureFeatures.keyScale(for: CGSize(width: 400, height: 400)) == 1.6)
        #expect(GestureFeatures.keyScale(for: CGSize(width: 90, height: GestureFeatures.referenceKeyHeight)) == 1)
    }

    @Test func theReferenceKeyKeepsTheExpertMinimumExactly() {
        var tuning = GestureTuning.default
        tuning.thresholds = GestureClassificationThresholds(
            minSwipeLength: 30, maxReturnRatio: 0.5, returnDisplacementRange: 0.2 ... 0.8, minCircularity: 0.3,
            minAngularSpan: .pi * 1.5, minPathSeparation: 0.5, minTurnConsistency: 0.8, minOrientedCompactness: 0.4
        )
        let key = CGSize(width: 80, height: GestureFeatures.referenceKeyHeight)
        #expect(classify(line(length: 28), keySize: key, tuning: tuning).gesture == .tap)
        #expect(classify(line(length: 38), keySize: key, tuning: tuning).gesture == .swipeRight)
    }
}

// MARK: - Direction from the body of the stroke

struct RobustDirectionTests {
    /// A stroke aimed 28° (down-right) whose last sample is flicked off toward
    /// 17°: the farthest point reads right, the stroke was down-right.
    private let hooked: [CGPoint] = {
        var points = (0 ... 5).map { i -> CGPoint in
            let t = CGFloat(i) / 5 * 0.8 * 44
            return CGPoint(x: t * cos(28 * .pi / 180), y: t * sin(28 * .pi / 180))
        }
        points.append(CGPoint(x: 40, y: 12))
        return points
    }()

    @Test func aLiftOffHookDoesNotTurnTheSector() {
        let features = GestureFeatures.extract(from: GesturePreprocessor().preprocess(hooked))
        #expect(KeyGestureRecognizer.angleToGestureType(features.maxDisplacementAngle) == .swipeRight)
        #expect(classify(hooked).gesture == .swipeDownRight)
    }

    @Test func aCleanStrokeIsReadExactlyAsBefore() {
        for degrees in stride(from: CGFloat(0), to: 360, by: 45) {
            let expected = KeyGestureRecognizer.angleToGestureType(degrees * .pi / 180)
            #expect(classify(line(length: 50, degrees: degrees, samples: 8)).gesture == expected, "\(degrees)")
        }
    }

    @Test func aReturnSwipeIsReadFromItsOutwardLeg() {
        // Out toward 40° (down-right) 50 points, back along a path bowed 14 points
        // to the side: the tip is rounded off toward the way back.
        var points: [CGPoint] = []
        let radians: CGFloat = 40 * CGFloat.pi / 180
        let out = CGVector(dx: cos(radians), dy: sin(radians))
        let side = CGVector(dx: -out.dy, dy: out.dx)
        for i in 0 ... 5 { points.append(CGPoint(x: out.dx * 50 * CGFloat(i) / 5, y: out.dy * 50 * CGFloat(i) / 5)) }
        for i in 1 ... 5 {
            let u = CGFloat(i) / 5
            points.append(CGPoint(
                x: out.dx * 50 * (1 - u) + side.dx * 14 * sin(.pi * u),
                y: out.dy * 50 * (1 - u) + side.dy * 14 * sin(.pi * u)
            ))
        }
        let result = classify(points)
        #expect(result.isReturn)
        #expect(result.gesture == .swipeDownRight)
    }

    @Test func tooShortALegToJudgeFallsBackToTheFarthestPoint() {
        #expect(GestureCalculations.robustDirection(of: [CGPoint.zero, CGPoint(x: 30, y: 1)], farthest: 1) == nil)
    }
}

// MARK: - The circle fit

struct CircleFitTests {
    private func ellipse(major: CGFloat, minor: CGFloat, turns: CGFloat = 1.05, samples: Int = 48) -> [CGPoint] {
        let origin = CGPoint(x: major, y: 0)
        return (0 ..< samples).map {
            let phi = turns * 2 * .pi * CGFloat($0) / CGFloat(samples - 1)
            return CGPoint(x: major * cos(phi) - origin.x, y: minor * sin(phi) - origin.y)
        }
    }

    @Test func aCircleFitsItself() {
        let points = ellipse(major: 24, minor: 24)
        #expect(GestureCalculations.circleFitResidual(of: points) < 0.01)
    }

    @Test func theResidualGrowsAsTheLoopFlattens() {
        let round = GestureCalculations.circleFitResidual(of: ellipse(major: 24, minor: 24))
        let oval = GestureCalculations.circleFitResidual(of: ellipse(major: 24, minor: 12))
        let flat = GestureCalculations.circleFitResidual(of: ellipse(major: 24, minor: 6))
        #expect(round < oval)
        #expect(oval < flat)
        #expect(oval < GestureClassificationThresholds.defaultMaxCircleFitResidual)
        #expect(flat > GestureClassificationThresholds.defaultMaxCircleFitResidual)
    }

    @Test func aFlatLoopIsAReturnSwipeAndAnOvalIsACircle() {
        #expect(classify(ellipse(major: 26, minor: 12)).gesture == .circularClockwise)
        #expect(!classify(ellipse(major: 30, minor: 5)).gesture.isCircular)
    }

    @Test func collinearPointsFitNoCircle() {
        #expect(GestureCalculations.circleFitResidual(of: line(length: 40, samples: 10)) == 1)
        #expect(GestureCalculations.circleFitResidual(of: [CGPoint.zero, CGPoint(x: 1, y: 1)]) == 1)
    }

    @Test func aSpiralIsExemptFromTheFit() {
        // Winding a turn and a half or more is no return swipe, whatever it fits.
        var spiral: [CGPoint] = []
        for i in 0 ..< 40 {
            let phi = CGFloat(i) * .pi / 8
            let r = 6 + CGFloat(i) * 0.9
            spiral.append(CGPoint(x: r * cos(phi), y: r * sin(phi)))
        }
        #expect(GestureFeatures.extract(from: spiral).isCircular)
    }

    @Test func theFitLimitRidesTheExpertThreshold() {
        let points = GesturePreprocessor().preprocess(ellipse(major: 26, minor: 13))
        let residual = GestureCalculations.circleFitResidual(of: points)
        var thresholds = GestureClassificationThresholds.default
        thresholds.maxCircleFitResidual = residual + 0.02
        #expect(GestureFeatures.extract(from: points, thresholds: thresholds).isCircular)
        thresholds.maxCircleFitResidual = residual - 0.02
        let strict = GestureFeatures.extract(from: points, thresholds: thresholds)
        #expect(strict.passesCircleGates)
        #expect(!strict.isCircular)
    }
}

// MARK: - The spike filter

struct SpikeFilterTests {
    private let filter = GesturePreprocessor()

    @Test func aLoneSidewaysSampleIsCut() {
        var points = line(length: 80, samples: 9)
        points[4].y += 30
        let cleaned = filter.filterSpikes(points)
        #expect(cleaned.count == 8)
        #expect(!cleaned.contains { $0.y > 20 })
    }

    @Test func aSampleThatJumpsAheadAndFallsBackIsCut() {
        var points = line(length: 80, samples: 9)
        points[4].x += 40
        #expect(filter.filterSpikes(points).count == 8)
    }

    @Test func aReturnSwipesTipIsNotASpike() {
        let out = line(length: 50, samples: 6)
        let back = Array(out.dropLast().reversed())
        #expect(filter.filterSpikes(out + back).count == out.count + back.count)
    }

    @Test func aWideTurnIsNotASpike() {
        // A circle sampled five times a turn bends at every sample.
        let circle = (0 ..< 11).map { i -> CGPoint in
            let phi = CGFloat(i) * 2 * CGFloat.pi / 5
            return CGPoint(x: 25 * cos(phi), y: 25 * sin(phi))
        }
        #expect(filter.filterSpikes(circle).count == circle.count)
    }

    @Test func theEndsAreLeftAlone() {
        var points = line(length: 80, samples: 9)
        points[7].y += 30
        #expect(filter.filterSpikes(points).count == 9)
    }

    @Test func theBufferFormEqualsTheArrayForm() {
        var points = line(length: 80, samples: 12)
        points[5].y -= 28
        let expected = filter.filterSpikes(points)
        var buffer = points
        let count = buffer.withUnsafeMutableBufferPointer { filter.filterSpikes($0) }
        #expect(Array(buffer.prefix(count)) == expected)
    }

    @Test func aSpikedCircleIsStillACircle() {
        var circle = (0 ..< 40).map { i -> CGPoint in
            let phi = CGFloat(i) * 2.1 * .pi / 39
            return CGPoint(x: 22 * cos(phi) - 22, y: 22 * sin(phi))
        }
        circle[18].x += 35
        #expect(classify(circle).gesture == .circularClockwise)
    }
}

// MARK: - Time, as the engine hands it over

struct StrokeTimingTests {
    @Test func theSequenceKeepsWhenItReachedItsFarthestPoint() {
        var sequence = KeyGestureSequence()
        _ = sequence.handleChanged(translation: .zero, elapsed: 0)
        _ = sequence.handleChanged(translation: CGSize(width: 8, height: 0), elapsed: 0.02)
        _ = sequence.handleChanged(translation: CGSize(width: 16, height: 0), elapsed: 0.05)
        // A long rest at the same place does not move the peak.
        _ = sequence.handleChanged(translation: CGSize(width: 15, height: 0), elapsed: 0.4)
        #expect(sequence.peakElapsed == 0.05)
        sequence.handleCancelled()
        #expect(sequence.peakElapsed == 0)
    }

    @Test func aFastFlickThenARestIsStillFast() {
        var sequence = KeyGestureSequence()
        let scratch = ClassificationScratch()
        _ = sequence.handleChanged(translation: .zero, elapsed: 0)
        _ = sequence.handleChanged(translation: CGSize(width: 8, height: 0), elapsed: 0.02)
        _ = sequence.handleChanged(translation: CGSize(width: 16, height: 0), elapsed: 0.05)
        _ = sequence.handleChanged(translation: CGSize(width: 16, height: 0), elapsed: 0.5)
        let result = sequence.handleEnded(
            translation: CGSize(width: 16, height: 0), aspectRatio: 1, tuning: .default,
            keySize: referenceKey, elapsed: 0.6, scratch: scratch
        )
        #expect(result.gesture == .swipeRight)
    }

    @Test func theReleaseSampleCanBeTheFarthest() {
        var sequence = KeyGestureSequence()
        let scratch = ClassificationScratch()
        _ = sequence.handleChanged(translation: .zero, elapsed: 0)
        _ = sequence.handleChanged(translation: CGSize(width: 6, height: 0), elapsed: 0.02)
        let result = sequence.handleEnded(
            translation: CGSize(width: 17, height: 0), aspectRatio: 1, tuning: .default,
            keySize: referenceKey, elapsed: 0.06, scratch: scratch
        )
        #expect(result.gesture == .swipeRight)
    }

    @Test func aSlowDragIsATapThroughTheScratchPathToo() {
        var sequence = KeyGestureSequence()
        let scratch = ClassificationScratch()
        for i in 0 ... 10 {
            _ = sequence.handleChanged(translation: CGSize(width: CGFloat(i) * 1.5, height: 0), elapsed: Double(i) * 0.04)
        }
        let result = sequence.handleEnded(
            translation: CGSize(width: 15, height: 0), aspectRatio: 1, tuning: .default,
            keySize: referenceKey, elapsed: 0.44, scratch: scratch
        )
        #expect(result.gesture == .tap)
    }
}

// MARK: - Through the touch engine

@MainActor
@Suite(.serialized)
struct EngineFastFlickTests {
    private func gesture(of length: CGFloat, over duration: TimeInterval, samples: Int = 6) -> GestureType? {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        var path = TouchPath(samples: (0 ... samples).map { CGPoint(x: length * CGFloat($0) / CGFloat(samples), y: 0) })
        // The scenario spaces samples at 120 Hz; stretch the path in time by
        // padding it with rests at the end, which must not slow the stroke.
        let rests = max(Int((duration * TouchPath.sampleRate).rounded()) - samples, 0)
        path.samples += Array(repeating: path.samples.last ?? .zero, count: rests)
        return scenario.perform(path, on: GridSlot.center).gesture
    }

    @Test func aQuickShortFlickThroughTheEngineIsASwipe() {
        #expect(gesture(of: 15, over: 0.05, samples: 6) == .swipeRight)
    }

    @Test func aSlowDriftOfTheSameLengthIsATap() {
        // Moves in 0.4 s: slow all the way, not a flick followed by a rest.
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        let count = 48
        let path = TouchPath(samples: (0 ... count).map { CGPoint(x: 15 * CGFloat($0) / CGFloat(count), y: 0) })
        #expect(scenario.perform(path, on: GridSlot.center).gesture == .tap)
    }

    @Test func aFlickFollowedByARestStillFires() {
        #expect(gesture(of: 15, over: 0.5, samples: 6) == .swipeRight)
    }
}

// MARK: - Expert thresholds

struct ForgivenessThresholdSettingsTests {
    @Test func theDefaultsAreTheMeasuredOnes() {
        let t = GestureClassificationThresholds.default
        #expect(t.fastSwipeLength == 12)
        #expect(t.fastSwipeSpeed == 100)
        #expect(t.maxCircleFitResidual == 0.3)
    }

    @Test func storedValuesApplyOnlyInExpertModeAndAreClamped() {
        let store = InMemoryUserDefaults()
        store.set(15.0, forKey: GestureClassificationThresholds.fastSwipeLengthKey)
        store.set(9999.0, forKey: GestureClassificationThresholds.fastSwipeSpeedKey)
        store.set(0.42, forKey: GestureClassificationThresholds.maxCircleFitResidualKey)
        #expect(GestureClassificationThresholds.fromUserDefaults(store: store) == .default)

        store.set(true, forKey: SettingsKey.expertModeEnabled.rawValue)
        let loaded = GestureClassificationThresholds.fromUserDefaults(store: store)
        #expect(loaded.fastSwipeLength == 15)
        #expect(loaded.fastSwipeSpeed == CGFloat(GestureClassificationThresholds.fastSwipeSpeedRange.upperBound))
        #expect(abs(loaded.maxCircleFitResidual - 0.42) < 1e-6)
    }
}
