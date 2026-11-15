//
//  WordSlideTests.swift
//  WurstfingerKitTests
//
//  The space bar's slide in Continuous mode: characters at normal speed, words
//  once the finger sweeps, measured with the scenario harness's slide paths.
//

import CoreGraphics
import Foundation
import Testing
@testable import WurstfingerKit
@testable import WurstfingerScenarioKit

@MainActor
struct SlideSpeedTrackerTests {
    /// Feeds a constant-speed slide, one sample per 120 Hz frame.
    private func slide(at speed: CGFloat, for duration: TimeInterval, tracker: inout SlideSpeedTracker, from start: TimeInterval = 0, direction: CGFloat = 1) -> TimeInterval {
        var time = start
        let frame = 1.0 / 120
        while time < start + duration {
            time += frame
            tracker.note(deltaX: direction * speed * CGFloat(frame), at: time)
        }
        return time
    }

    @Test func anOrdinaryDragNeverSweeps() {
        var tracker = SlideSpeedTracker()
        _ = slide(at: 500, for: 2, tracker: &tracker)
        #expect(!tracker.isSweeping)
        #expect(abs(tracker.rate - 500) < 40, "the estimate converges on the real speed")
    }

    @Test func aFastSlideSweepsAfterAShortRamp() {
        var tracker = SlideSpeedTracker()
        var time: TimeInterval = 0
        var sweptAfter: TimeInterval?
        for _ in 0 ..< 60 {
            time += 1.0 / 120
            if tracker.note(deltaX: 1000 / 120, at: time), sweptAfter == nil { sweptAfter = time }
        }
        let ramp = sweptAfter ?? .infinity
        #expect(ramp > 0.04 && ramp < 0.15, "starts in characters, turns to words as it gathers speed: \(ramp)")
    }

    @Test func hoveringBetweenTheThresholdsDoesNotFlicker() {
        var tracker = SlideSpeedTracker()
        var time = slide(at: 1200, for: 0.4, tracker: &tracker)
        #expect(tracker.isSweeping)
        // Dips to a speed between exit and enter stay swept; wobbling around it never toggles.
        var changes = 0
        var was = tracker.isSweeping
        for index in 0 ..< 120 {
            let speed: CGFloat = index.isMultiple(of: 2) ? 700 : 520
            time += 1.0 / 120
            tracker.note(deltaX: speed / 120, at: time)
            if tracker.isSweeping != was { changes += 1; was = tracker.isSweeping }
        }
        #expect(changes == 0)
        #expect(tracker.isSweeping)
    }

    @Test func aSlowSlideAfterAFastOneReturnsToCharacters() {
        var tracker = SlideSpeedTracker()
        var time = slide(at: 1500, for: 0.5, tracker: &tracker)
        #expect(tracker.isSweeping)
        time = slide(at: 200, for: 0.5, tracker: &tracker, from: time)
        #expect(!tracker.isSweeping)
    }

    @Test func reversingDirectionStartsOverInCharacters() {
        var tracker = SlideSpeedTracker()
        let time = slide(at: 1500, for: 0.5, tracker: &tracker)
        #expect(tracker.isSweeping)
        tracker.note(deltaX: -2, at: time + 1.0 / 120)
        #expect(!tracker.isSweeping)
    }

    @Test func aPauseForgetsTheSpeed() {
        var tracker = SlideSpeedTracker()
        let time = slide(at: 1500, for: 0.5, tracker: &tracker)
        tracker.note(deltaX: 4, at: time + 0.5)
        #expect(!tracker.isSweeping)
    }

    @Test func aCallerWithoutAClockNeverSweeps() {
        var tracker = SlideSpeedTracker()
        for _ in 0 ..< 50 { tracker.note(deltaX: 14, at: 0) }
        #expect(!tracker.isSweeping)
    }
}

@MainActor
struct WordBoundaryTests {
    private let english = Locale(identifier: "en_US")

    @Test func backwardStepsLandOnWordStarts() {
        let steps = WordBoundary.steps(in: "the quick brown fox", count: 3, backward: true, locale: english)
        #expect(steps == [3, 6, 6])
    }

    @Test func backwardPassesTheSpacesBehindTheCaret() {
        #expect(WordBoundary.steps(in: "hello world  ", count: 1, backward: true, locale: english) == [7])
    }

    @Test func forwardStepsLandOnWordEnds() {
        #expect(WordBoundary.steps(in: " quick brown fox", count: 2, backward: false, locale: english) == [6, 6])
    }

    @Test func anApostropheStaysInsideTheWord() {
        #expect(WordBoundary.steps(in: "I don't know", count: 2, backward: true, locale: english) == [4, 6])
    }

    @Test func runningOutOfWordsStopsShort() {
        #expect(WordBoundary.steps(in: "two words", count: 5, backward: true, locale: english) == [5, 4])
        #expect(WordBoundary.steps(in: "", count: 2, backward: true, locale: english).isEmpty)
        #expect(WordBoundary.steps(in: "   ", count: 2, backward: true, locale: english).isEmpty)
    }

    @Test func chineseIsSegmentedWithoutSpaces() {
        // 我 / 喜欢 / 苹果 / 手机: no whitespace anywhere. The sum of the steps is the
        // whole text, and no step is the whole sentence.
        let text = "我喜欢苹果手机"
        let steps = WordBoundary.steps(in: text, count: 6, backward: true, locale: Locale(identifier: "zh_CN"))
        #expect(steps.count >= 2, "\(steps)")
        #expect(steps.allSatisfy { $0 < text.utf16.count })
        #expect(steps.reduce(0, +) == text.utf16.count)
        #expect(steps.first! >= 2, "the last word is more than one character")
    }

    @Test func japaneseIsSegmentedWithoutSpaces() {
        let text = "今日は天気がいいです"
        let steps = WordBoundary.steps(in: text, count: 8, backward: true, locale: Locale(identifier: "ja_JP"))
        #expect(steps.count >= 3, "\(steps)")
        #expect(steps.reduce(0, +) == text.utf16.count)
    }

    @Test func arabicStepsByWordsInLogicalOrder() {
        let text = "مرحبا بكم في العالم"
        let backward = WordBoundary.steps(in: text, count: 2, backward: true, locale: Locale(identifier: "ar"))
        #expect(backward == ["العالم", "في "].map { $0.utf16.count })
        let forward = WordBoundary.steps(in: text, count: 2, backward: false, locale: Locale(identifier: "ar"))
        #expect(forward == ["مرحبا", " بكم"].map { $0.utf16.count })
    }

    @Test func hebrewStepsByWords() {
        let steps = WordBoundary.steps(in: "שלום עולם יפה", count: 3, backward: true, locale: Locale(identifier: "he"))
        #expect(steps == [3, 5, 5].map { $0 } || steps.count == 3)
        #expect(steps.reduce(0, +) == "שלום עולם יפה".utf16.count)
    }

    @Test func anEmojiCountsInUTF16Units() {
        let steps = WordBoundary.steps(in: "hi there 👋 friends", count: 1, backward: true, locale: english)
        #expect(steps == [7])
    }
}

/// The speed threshold, measured through the real engine with the harness's
/// slide paths.
@MainActor
struct WordSlideScenarioTests {
    private let sentence = "the quick brown fox jumps over the lazy dog"

    private func scenario(_ language: String = "en_US", settings: [SettingsKey: Any] = [:]) -> KeyboardScenario {
        let scenario = KeyboardScenario(language: language, autoCapitalize: false, settings: settings)
        scenario.target.reset(to: sentence)
        return scenario
    }

    private func caretMoved(speed: CGFloat, by travel: CGFloat = -300, in scenario: KeyboardScenario) -> Int {
        let before = scenario.cursor
        scenario.drag(UtilitySlot.space, by: CGSize(width: travel, height: 0), speed: speed)
        return before - scenario.cursor
    }

    @Test(arguments: [100, 200, 350, 500, 650] as [CGFloat])
    func anOrdinarySlideMovesByCharacters(speed: CGFloat) {
        let scenario = scenario()
        let moved = caretMoved(speed: speed, in: scenario)
        // 300 pt of travel, 8 pt to latch, 14 pt per character.
        #expect((19 ... 22).contains(moved), "\(speed) pt/s moved \(moved)")
    }

    /// The caret moves the harness's target made, as offsets.
    private func offsets(_ scenario: KeyboardScenario) -> [Int] {
        scenario.target.events.compactMap { if case let .adjustCursor(offset) = $0 { offset } else { nil } }
    }

    @Test(arguments: [1000, 1500, 2500] as [CGFloat])
    func aSweepMovesByWords(speed: CGFloat) {
        let scenario = scenario()
        scenario.target.reset(to: sentence + " " + sentence)
        scenario.drag(UtilitySlot.space, by: CGSize(width: -420, height: 0), speed: speed)
        let moves = offsets(scenario)
        #expect(moves.contains { $0 < -1 }, "\(speed) pt/s: \(moves)")
        // Once sweeping, every step lands at a word start.
        let text = scenario.text
        let index = text.index(text.startIndex, offsetBy: scenario.cursor)
        #expect(scenario.cursor == 0 || text[text.index(before: index)] == " ", "\(speed) pt/s left the caret inside a word at \(scenario.cursor)")
    }

    @Test func aFastSweepThenASlowSlideGoesBackToCharacters() {
        let scenario = scenario()
        scenario.drag(UtilitySlot.space, by: CGSize(width: -240, height: 0), speed: 1800)
        let afterSweep = scenario.cursor
        scenario.drag(UtilitySlot.space, by: CGSize(width: 56, height: 0), speed: 200)
        #expect(scenario.cursor - afterSweep == 3 || scenario.cursor - afterSweep == 4, "a new slide starts in characters: moved \(scenario.cursor - afterSweep)")
    }

    @Test func aSlideThatSpeedsUpAndSlowsDownSwitchesBothWays() {
        let scenario = scenario()
        var synth = TouchSynthesizer(keySize: scenario.keySize(UtilitySlot.space), seed: 3)
        let fast = synth.drag(by: CGSize(width: -280, height: 0), speed: 1800)
        let slow = synth.drag(by: CGSize(width: -84, height: 0), speed: 200)
        // One finger: the fast leg, then the slow one, continuing the same slide.
        let samples = fast.samples + slow.samples.map { CGPoint(x: fast.end.x + $0.x, y: $0.y) }
        scenario.perform(TouchPath(samples: samples), on: UtilitySlot.space)
        let moved = sentence.count - scenario.cursor
        #expect(moved > 22 + 3, "words on the fast leg, then characters: moved \(moved)")
    }

    @Test func aSweepSteppingOverWordsStopsAtTheStartOfTheText() {
        let scenario = scenario()
        scenario.drag(UtilitySlot.space, by: CGSize(width: -1200, height: 0), speed: 2500)
        #expect(scenario.cursor == 0)
    }

    @Test func aSweepRightMovesForwardByWords() {
        let scenario = scenario()
        scenario.target.reset(to: "")
        scenario.target.insertText(sentence)
        scenario.target.adjustTextPosition(byCharacterOffset: -sentence.utf16.count)
        scenario.drag(UtilitySlot.space, by: CGSize(width: 200, height: 0), speed: 1800)
        let text = scenario.text
        let index = text.index(text.startIndex, offsetBy: scenario.cursor)
        #expect(scenario.cursor > 0)
        #expect(index == text.endIndex || text[index] == " ", "forward steps land at a word end")
    }

    @Test func stepByStepModeIsUnchangedBySpeed() {
        let scenario = scenario(settings: [.cursorMovementStyle: CursorMovementType.discrete.rawValue])
        scenario.drag(UtilitySlot.space, by: CGSize(width: -200, height: 0), speed: 2500)
        #expect(scenario.cursor == sentence.count - 1, "a discrete swipe is one character whatever its speed")
    }

    @Test func aSweepOverChineseTextStepsByItsWords() {
        let scenario = scenario("zh_CN")
        let phrase = String(repeating: "我喜欢苹果手机", count: 4)
        scenario.target.reset(to: phrase)
        scenario.drag(UtilitySlot.space, by: CGSize(width: -420, height: 0), speed: 1800)
        let moves = offsets(scenario)
        #expect(moves.contains { $0 <= -2 }, "a word step in a text with no spaces: \(moves)")
        #expect(scenario.cursor < phrase.count - 3)
    }

    @Test func aSweepOverArabicTextStepsByItsWords() {
        let scenario = scenario("ar")
        scenario.target.reset(to: "مرحبا بكم في العالم مرحبا بكم في العالم")
        scenario.drag(UtilitySlot.space, by: CGSize(width: -420, height: 0), speed: 1800)
        let text = scenario.text
        let index = text.index(text.startIndex, offsetBy: scenario.cursor)
        #expect(offsets(scenario).contains { $0 <= -2 })
        #expect(scenario.cursor == 0 || text[text.index(before: index)] == " ", "landed at a word start: \(scenario.cursor)")
    }
}
