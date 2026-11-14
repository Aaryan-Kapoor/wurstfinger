//
//  LayoutMotionTests.swift
//  WurstfingerKitTests
//
//  How geometry changes move: which ones animate, and with which motion.
//

import CoreGraphics
import Foundation
import Testing
@testable import WurstfingerKit

@MainActor
struct LayoutMotionClockTests {
    private final class Clock {
        var time: TimeInterval = 100
    }

    private func signature(width: CGFloat) -> KeyboardGeometrySignature {
        let base = StandardArrangements.grid3x3[.portrait]!
        let plan = KeyboardLayoutPlan.resolve(KeyboardLayoutPlan.Inputs(
            base: base, hasNumpadKeys: false, numpadColumn: .off, isUtilityLeading: false, isSplitEnabled: false,
            wishWidth: width, aspectRatio: 1, spacing: 5, containerWidth: 1000, widthCap: 1000,
            screen: CGSize(width: 1000, height: 2000)
        ))
        return KeyboardGeometrySignature(plan)
    }

    private func makeClock() -> (LayoutMotionClock, Clock) {
        let time = Clock()
        return (LayoutMotionClock(now: { time.time }), time)
    }

    @Test func theFirstGeometryAppearsWithoutAnimation() {
        let (clock, _) = makeClock()
        #expect(clock.motion(for: signature(width: 270), reduceMotion: false) == nil)
    }

    @Test func aChangeOnItsOwnSettles() {
        let (clock, time) = makeClock()
        _ = clock.motion(for: signature(width: 270), reduceMotion: false)
        time.time += 2
        #expect(clock.motion(for: signature(width: 300), reduceMotion: false) == .settle(duration: LayoutMotion.settleDuration))
    }

    @Test func framesOfAContinuousChangeFollow() {
        let (clock, time) = makeClock()
        _ = clock.motion(for: signature(width: 270), reduceMotion: false)
        time.time += 2
        _ = clock.motion(for: signature(width: 272), reduceMotion: false)
        time.time += 1.0 / 60
        #expect(clock.motion(for: signature(width: 274), reduceMotion: false) == .follow)
        time.time += 1.0 / 60
        #expect(clock.motion(for: signature(width: 276), reduceMotion: false) == .follow)
    }

    /// The root view and the controller both ask for the same change; the
    /// second ask must not turn it into a "continuous" one.
    @Test func askingAgainForTheSameGeometryKeepsTheAnswer() {
        let (clock, time) = makeClock()
        _ = clock.motion(for: signature(width: 270), reduceMotion: false)
        time.time += 2
        let first = clock.motion(for: signature(width: 300), reduceMotion: false)
        time.time += 0.01
        #expect(clock.motion(for: signature(width: 300), reduceMotion: false) == first)
    }

    @Test func aRotationSettlesInTheSystemsTime() {
        let (clock, time) = makeClock()
        _ = clock.motion(for: signature(width: 270), reduceMotion: false)
        clock.noteSystemTransition(duration: 0.4)
        time.time += 0.05
        #expect(clock.motion(for: signature(width: 300), reduceMotion: false) == .settle(duration: 0.4))
        time.time += 2
        #expect(clock.motion(for: signature(width: 320), reduceMotion: false) == .settle(duration: LayoutMotion.settleDuration))
    }

    @Test func reduceMotionNeverAnimates() {
        let (clock, time) = makeClock()
        _ = clock.motion(for: signature(width: 270), reduceMotion: true)
        time.time += 2
        #expect(clock.motion(for: signature(width: 300), reduceMotion: true) == nil)
    }
}

@MainActor
struct KeyboardGeometrySignatureTests {
    /// Letters ↔ shifted keeps every key where it is: no layout animation,
    /// only the labels' own cross-fade.
    @Test func shiftingMovesNoKeys() throws {
        let (viewModel, _) = makeViewModel(languageId: "en_US")
        let letters = try #require(viewModel.layoutPlan(forContainerWidth: 393))
        viewModel.activeModeName = ModeNames.shifted
        let shifted = try #require(viewModel.layoutPlan(forContainerWidth: 393))
        #expect(KeyboardGeometrySignature(letters) == KeyboardGeometrySignature(shifted))
    }

    /// Letters → numbers narrows the space bar beside the zero: a reshape at
    /// the same key size, which settles quickly.
    @Test func switchingToNumbersReshapesQuickly() throws {
        let (viewModel, _) = makeViewModel(languageId: "en_US")
        var time: TimeInterval = 0
        let clock = LayoutMotionClock(now: { time })
        let letters = KeyboardGeometrySignature(try #require(viewModel.layoutPlan(forContainerWidth: 393)))
        _ = clock.motion(for: letters, reduceMotion: false)
        viewModel.activeModeName = ModeNames.numeric
        let numbers = KeyboardGeometrySignature(try #require(viewModel.layoutPlan(forContainerWidth: 393)))
        #expect(numbers != letters)
        #expect(numbers.metrics == letters.metrics)
        time = 5
        #expect(clock.motion(for: numbers, reduceMotion: false) == .settle(duration: LayoutMotion.reshapeDuration))
    }

    @Test func theUtilitySideMovesKeys() throws {
        let (viewModel, _) = makeViewModel(languageId: "en_US")
        let right = try #require(viewModel.layoutPlan(forContainerWidth: 393))
        viewModel.utilityColumnLeading = true
        let left = try #require(viewModel.layoutPlan(forContainerWidth: 393))
        #expect(KeyboardGeometrySignature(right) != KeyboardGeometrySignature(left))
    }
}

struct KeyboardSpringTests {
    /// The keys (SwiftUI) and the keyboard's frame (UIKit) read the same
    /// spring off the motion, so they cannot drift apart.
    @Test func eachMotionIsOneSpringForBothSides() {
        #expect(LayoutMotion.follow.spring == .follow)
        #expect(LayoutMotion.settle(duration: 0.3).spring == KeyboardSpring(duration: 0.3, bounce: 0))
        #expect(LayoutMotion.follow.animation == KeyboardSpring.follow.animation)
    }

    /// The geometry never overshoots visibly; the feel layer has a little life.
    @Test func geometryGlidesAndFeelBounces() {
        #expect(KeyboardSpring.glide(0.34).bounce == 0)
        #expect(KeyboardSpring.follow.bounce < 0.1)
        for spring in [KeyboardSpring.track, .settle, .land, .unfold, .detent] {
            #expect(spring.bounce > 0 && spring.bounce <= 0.3)
            #expect(spring.duration < 0.3, "a feel spring must finish within a keystroke or two")
        }
        #expect(FeelMotion.track == KeyboardSpring.track.animation)
        #expect(FeelMotion.keyRelease == KeyboardSpring.settle.animation)
    }
}
