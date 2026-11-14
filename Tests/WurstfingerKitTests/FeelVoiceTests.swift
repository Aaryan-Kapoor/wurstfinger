//
//  FeelVoiceTests.swift
//  WurstfingerKitTests
//
//  The derived voices: that the mapping from key and gesture to what a moment
//  sounds and feels like is consistent and learnable, that haptics and sound
//  render the same hits, and that the instruments, the mixer and the click
//  bank behave — none of it needs a speaker or a Taptic Engine.
//

import CoreGraphics
import Foundation
import os
import Testing
@testable import WurstfingerKit
@testable import WurstfingerScenarioKit

private let grid = CGSize(width: 300, height: 240)

/// The frame of the key in column `column`, row `row` of a 4×4 grid.
private func cell(_ column: Int, _ row: Int) -> CGRect {
    CGRect(x: CGFloat(column) * 75, y: CGFloat(row) * 60, width: 75, height: 60)
}

private func letterVoice(_ column: Int, _ row: Int, mode: String = ModeNames.main) -> KeyVoice {
    FeelVoiceModel.voice(role: .letter, keyFrame: cell(column, row), gridSize: grid, mode: mode)
}

// MARK: - The mapping

@MainActor
struct FeelVoiceMappingTests {
    @Test func upIsHigherAndRightIsHigher() {
        // Same column, rows going down: the note never rises.
        for column in 0 ..< 3 {
            let pitches = (0 ..< 3).map { letterVoice(column, $0).pitch }
            #expect(pitches == pitches.sorted(by: >), "column \(column)")
        }
        // Same row, columns going right: the note never falls.
        for row in 0 ..< 3 {
            let pitches = (0 ..< 3).map { letterVoice($0, row).pitch }
            #expect(pitches == pitches.sorted(), "row \(row)")
        }
        #expect(letterVoice(2, 0).pitch > letterVoice(0, 2).pitch)
    }

    @Test func theNineLetterKeysPlayAtLeastSixNotesAllOnTheScale() {
        var notes = Set<Float>()
        for column in 0 ..< 3 {
            for row in 0 ..< 3 {
                let pitch = letterVoice(column, row).pitch
                #expect(FeelVoiceModel.scale.contains(pitch))
                notes.insert(pitch)
            }
        }
        #expect(notes.count >= 6, "neighbouring keys should mostly sound different (\(notes.sorted()))")
    }

    @Test func eachRoleHasItsOwnInstrument() {
        let timbres = KeyRole.allCases.map(\.timbre)
        // enter and modifier share the felt; every other role is distinct.
        #expect(Set(timbres).count == KeyRole.allCases.count - 1)
        #expect(KeyRole.letter.timbre == .wood)
        #expect(KeyRole.space.timbre == .thump)
    }

    @Test func keysThatRemoveOrChangeTextSitBelowThoseThatAddIt() {
        func voice(_ role: KeyRole) -> KeyVoice {
            FeelVoiceModel.voice(role: role, keyFrame: cell(1, 1), gridSize: grid, mode: ModeNames.main)
        }
        #expect(voice(.space).pitch < voice(.delete).pitch || voice(.space).pitch < voice(.letter).pitch)
        #expect(voice(.modifier).pitch < voice(.letter).pitch)
        #expect(voice(.space).pitch < voice(.letter).pitch)
    }

    @Test func theModeSetsTheRegisterAndCapitalsAreFirmer() {
        let main = letterVoice(1, 1)
        #expect(letterVoice(1, 1, mode: ModeNames.numeric).pitch == main.pitch + 5)
        #expect(letterVoice(1, 1, mode: ModeNames.symbols).pitch == main.pitch + 7)
        let shifted = letterVoice(1, 1, mode: ModeNames.shifted)
        #expect(shifted.pitch == main.pitch)
        #expect(shifted.weight > main.weight)
    }

    @Test func rolesAreDerivedFromTheKey() throws {
        let definition = try #require(KeyboardRegistry.load(id: "en_US"))
        let main = try #require(definition.mode(ModeNames.main))
        #expect(KeyRole(key: try #require(main.keys[GridSlot.center])) == .letter)
        #expect(KeyRole(key: try #require(main.keys[UtilitySlot.space])) == .space)
        #expect(KeyRole(key: try #require(main.keys[UtilitySlot.delete])) == .delete)
        #expect(KeyRole(key: try #require(main.keys[UtilitySlot.return])) == .enter)
        #expect(KeyRole(key: try #require(main.keys[UtilitySlot.symbols])) == .modifier)
        let numeric = try #require(definition.mode(ModeNames.numeric))
        let digits = numeric.keys.values.filter { KeyRole(key: $0) == .digit }
        #expect(digits.count >= 9)
        #expect(KeyRole(typing: "!") == .punctuation)
        #expect(KeyRole(typing: "ä") == .letter)
    }

    @Test func aFlickMovesTheNoteByItsDirection() {
        let voice = letterVoice(1, 1)
        func note(_ direction: GestureType) -> Float {
            FeelVoiceModel.commit(.swipe, voice: voice, direction: direction, isReturn: false, reach: 0.8, typing: .commitText("x"))
                .first.pitch
        }
        #expect(note(.swipeUp) > voice.pitch)
        #expect(note(.swipeDown) < voice.pitch)
        #expect(note(.swipeRight) > voice.pitch)
        #expect(note(.swipeLeft) < voice.pitch)
        let directions = GestureType.allCases.filter(\.isSwipe)
        #expect(Set(directions.map(note)).count == directions.count, "every direction has its own interval")
    }

    @Test func aReturnSwipeGoesOutAndHome() {
        let voice = letterVoice(1, 1)
        let stroke = FeelVoiceModel.commit(.returnSwipe, voice: voice, direction: .swipeUp, isReturn: true, reach: 0.2, typing: .commitText("x"))
        let hits = stroke.hits
        #expect(hits.count == 2)
        #expect(hits[0].pitch == voice.pitch + FeelVoiceModel.interval(of: .swipeUp))
        #expect(hits[1].pitch == voice.pitch)
        #expect(hits[1].delay > hits[0].delay)
    }

    @Test func aCircleIsAnArpeggioByItsDirection() {
        let voice = letterVoice(1, 1)
        let up = FeelVoiceModel.commit(.circle, voice: voice, direction: .circularClockwise, isReturn: false, reach: 0, typing: .commitText("X")).hits
        let down = FeelVoiceModel.commit(.circle, voice: voice, direction: .circularCounterclockwise, isReturn: false, reach: 0, typing: .commitText("X")).hits
        #expect(up.map(\.pitch) == up.map(\.pitch).sorted())
        #expect(down.map(\.pitch) == down.map(\.pitch).sorted(by: >))
        #expect(up.count == 3)
    }

    @Test func whatGetsTypedPicksTheReleasesInstrument() {
        let voice = letterVoice(1, 1)
        let punctuation = FeelVoiceModel.commit(.swipe, voice: voice, direction: .swipeUp, isReturn: false, reach: 1, typing: .commitText("!"))
        let letter = FeelVoiceModel.commit(.swipe, voice: voice, direction: .swipeUp, isReturn: false, reach: 1, typing: .commitText("q"))
        #expect(punctuation.first.timbre == .glass)
        #expect(letter.first.timbre == .wood)
    }

    @Test func aTapsReleaseIsFeltNotHeardAndSofterThanItsPress() {
        let voice = letterVoice(1, 1)
        let down = FeelVoiceModel.touchDown(voice)
        let up = FeelVoiceModel.commit(.tap, voice: voice, direction: .tap, isReturn: false, reach: 0, typing: .commitText("o"))
        #expect(!up.isAudible)
        #expect(up.first.intensity < down.first.intensity)
        #expect(up.first.sharpness < down.first.sharpness)
    }

    @Test func aLongPressPlaysTheOctaveAbove() {
        let voice = letterVoice(1, 1)
        let stroke = FeelVoiceModel.commit(.longPress, voice: voice, direction: .longPress, isReturn: false, reach: 0, typing: .commitText("5"))
        #expect(stroke.first.pitch == voice.pitch + 12)
        #expect(stroke.first.timbre == .bell)
    }

    @Test func detentsAreFeltOnlyAndLighterThanThePress() {
        let voice = letterVoice(1, 1)
        for cue in [HapticCue.directionDetent, .centerDetent, .returnDetent, .circleClosed] {
            let stroke = FeelVoiceModel.detent(cue, voice: voice, direction: .swipeUp)
            #expect(!stroke.isAudible)
            #expect(stroke.first.intensity < FeelVoiceModel.touchDown(voice).first.intensity)
        }
        // Each direction's detent has its own sharpness: the sectors differ.
        let sharpnesses = GestureType.allCases.filter(\.isSwipe).map {
            FeelVoiceModel.detent(.directionDetent, voice: voice, direction: $0).first.sharpness
        }
        #expect(Set(sharpnesses).count >= 6)
    }

    @Test func modeChangesRiseIntoModesAndFallBack() {
        let into = FeelVoiceModel.modeChange(from: ModeNames.main, to: ModeNames.numeric).hits
        let back = FeelVoiceModel.modeChange(from: ModeNames.numeric, to: ModeNames.main).hits
        #expect(into[1].pitch > into[0].pitch)
        #expect(back[1].pitch < back[0].pitch)
        let shift = FeelVoiceModel.modeChange(from: ModeNames.main, to: ModeNames.shifted).hits
        #expect(shift[1].pitch - shift[0].pitch < into[1].pitch - into[0].pitch, "a neighbouring mode is a smaller step")
    }

    @Test func slideTicksRiseRightFallLeftAndLightenWithPace() {
        let space = FeelVoiceModel.voice(role: .space, keyFrame: cell(1, 3), gridSize: grid, mode: ModeNames.main)
        let right = FeelVoiceModel.slideStep(.moveCursor, voice: space, direction: 1, pace: .deliberate, step: 1)
        let left = FeelVoiceModel.slideStep(.moveCursor, voice: space, direction: -1, pace: .deliberate, step: 1)
        #expect(right.first.pitch > left.first.pitch)
        let weights = SlidePace.allCases.map {
            FeelVoiceModel.slideStep(.moveCursor, voice: space, direction: 1, pace: $0, step: 1).first.weight
        }
        #expect(weights == weights.sorted(by: >))
        let delete = FeelVoiceModel.voice(role: .delete, keyFrame: cell(3, 2), gridSize: grid, mode: ModeNames.main)
        let walk = (1 ... 4).map { FeelVoiceModel.slideStep(.delete, voice: delete, direction: -1, pace: .steady, step: $0).first.pitch }
        #expect(Set(walk).count == 4, "each deleted character sounds a little different")
    }

    @Test func hapticsAndSoundReadTheSameHit() {
        let hit = FeelHit(pitch: 12, weight: 0.6, timbre: .glass)
        let higher = FeelHit(pitch: 19, weight: 0.6, timbre: .glass)
        #expect(higher.sharpness > hit.sharpness, "a higher note feels crisper")
        #expect(higher.rate > hit.rate, "and plays faster")
        #expect(abs(FeelHit(pitch: 12, weight: 1, timbre: .wood).rate - 2) < 0.0001, "an octave doubles the rate")
        let firmer = FeelHit(pitch: 12, weight: 0.8, timbre: .glass)
        #expect(firmer.intensity > hit.intensity)
    }

    @Test func aStrokeIsAFixedSizeValue() {
        #expect(MemoryLayout<FeelStroke>.size <= 128, "no array: three inline hits")
        let stroke = FeelStroke(FeelHit(pitch: 0, weight: 1, timbre: .wood), nil, FeelHit(pitch: 2, weight: 1, timbre: .wood))
        #expect(stroke.count == 2)
        #expect(stroke.hits.map(\.pitch) == [0, 2])
    }
}

// MARK: - Haptics

@MainActor
struct HapticClickBankTests {
    @Test func everyCellRoundTrips() {
        for cell in 0 ..< HapticClickBank.cellCount {
            let (intensity, sharpness) = HapticClickBank.parameters(of: cell)
            #expect(HapticClickBank.cell(intensity: intensity, sharpness: sharpness) == cell)
        }
    }

    @Test func aHitPlaysTheNearestCellAndAWhisperNone() {
        let cell = HapticClickBank.cell(intensity: 0.33, sharpness: 0.66)
        let (intensity, sharpness) = HapticClickBank.parameters(of: cell!)
        #expect(intensity == 0.34)
        #expect(sharpness == 0.64)
        #expect(HapticClickBank.cell(intensity: 0.02, sharpness: 0.5) == nil)
    }

    @Test func intensityLevelsGrowByAboutAThird() {
        let levels = HapticClickBank.intensities
        for index in 1 ..< levels.count {
            let ratio = levels[index] / levels[index - 1]
            #expect(ratio > 1.2 && ratio < 1.7)
        }
    }

    @Test func aStrokePlaysEachHitFromTheBankAtTheUsersStrength() throws {
        let settings = HapticSettings(defaults: InMemoryUserDefaults(), shouldPersist: false)
        settings.tapIntensity = HapticIntensityLevel.light.storedIntensity
        let renderer = RecordingHapticRenderer()
        renderer.acceptsClicks = true
        let player = HapticFeedbackPlayer(settings: settings, detailed: renderer, pulses: RecordingPulseRenderer())
        let stroke = FeelVoiceModel.commit(
            .returnSwipe, voice: letterVoice(1, 1), direction: .swipeUp, isReturn: true, reach: 0.5, typing: .commitText("x")
        )
        player.play(stroke, as: .commit(.returnSwipe))
        #expect(renderer.clicks.count == 2)
        #expect(renderer.playedCues.isEmpty, "the designed pattern is the fallback, not played as well")
        let gain = HapticGain.gain(for: settings.tapIntensity)
        let first = try #require(renderer.clicks.first)
        #expect(abs(first.intensity - stroke.first.intensity * gain) < 0.0001)
        #expect(abs(first.sharpness - (stroke.first.sharpness + HapticGain.sharpnessShift(for: settings.tapIntensity))) < 0.0001)
        #expect(renderer.clicks[1].delay > 0)
    }

    @Test func withoutABankAStrokeFallsBackToItsCue() {
        let settings = HapticSettings(defaults: InMemoryUserDefaults(), shouldPersist: false)
        let renderer = RecordingHapticRenderer()
        let pulses = RecordingPulseRenderer()
        let player = HapticFeedbackPlayer(settings: settings, detailed: renderer, pulses: pulses)
        player.play(FeelVoiceModel.touchDown(letterVoice(0, 0)), as: .touchDown)
        #expect(renderer.playedCues == [.touchDown])
        renderer.isReady = false
        player.play(FeelVoiceModel.touchDown(letterVoice(0, 0)), as: .touchDown)
        #expect(pulses.played == [.pulse(for: settings.tapIntensity)])
    }

    @Test func anOffSliderSilencesStrokesToo() {
        let settings = HapticSettings(defaults: InMemoryUserDefaults(), shouldPersist: false)
        settings.tapIntensity = 0
        let renderer = RecordingHapticRenderer()
        renderer.acceptsClicks = true
        let player = HapticFeedbackPlayer(settings: settings, detailed: renderer, pulses: RecordingPulseRenderer())
        player.play(FeelVoiceModel.touchDown(letterVoice(0, 0)), as: .touchDown)
        #expect(renderer.clicks.isEmpty)
    }
}

// MARK: - Sound

@MainActor
struct KeySoundSynthTests {
    @Test func everyInstrumentSoundsAndDecays() {
        for timbre in FeelTimbre.allCases {
            let samples = KeySoundSynth.render(timbre, sampleRate: 48000)
            #expect(samples.count == Int(KeySoundSynth.duration * 48000))
            let peak = samples.map(abs).max() ?? 0
            #expect(abs(peak - 0.9) < 0.001, "\(timbre) is normalized")
            let tenth = samples.count / 10
            let head = samples.prefix(tenth).map { $0 * $0 }.reduce(0, +)
            let tail = samples.suffix(tenth).map { $0 * $0 }.reduce(0, +)
            #expect(tail < head * 0.01, "\(timbre) dies away")
        }
    }

    @Test func theSynthesisIsDeterministic() {
        #expect(KeySoundSynth.render(.wood, sampleRate: 44100) == KeySoundSynth.render(.wood, sampleRate: 44100))
    }

    @Test func instrumentsDiffer() {
        let all = KeySoundSynth.renderAll(sampleRate: 48000)
        #expect(all.count == FeelTimbre.allCases.count)
        for index in all.indices {
            for other in all.indices where other > index {
                #expect(all[index] != all[other])
            }
        }
    }
}

@MainActor
struct KeySoundMixerTests {
    private func mixer() -> KeySoundMixer {
        KeySoundMixer(instruments: KeySoundSynth.renderAll(sampleRate: 48000), sampleRate: 48000)
    }

    private func render(_ mixer: KeySoundMixer, frames: Int) -> [Float] {
        var buffer = [Float](repeating: 1, count: frames)
        buffer.withUnsafeMutableBufferPointer { _ = mixer.render(frames: frames, into: $0.baseAddress!) }
        return buffer
    }

    @Test func silenceUntilANotePlays() {
        let mixer = mixer()
        #expect(render(mixer, frames: 256).allSatisfy { $0 == 0 })
        mixer.start(KeySoundTrigger(timbre: 0, rate: 1, gain: 1, delay: 0))
        #expect(render(mixer, frames: 256).contains { $0 != 0 })
    }

    @Test func aDelayedNoteStartsLater() {
        let mixer = mixer()
        mixer.start(KeySoundTrigger(timbre: 0, rate: 1, gain: 1, delay: 0.01))
        let buffer = render(mixer, frames: 960)
        let firstSound = buffer.firstIndex { $0 != 0 } ?? -1
        #expect(firstSound >= 479 && firstSound <= 481, "10 ms at 48 kHz (got \(firstSound))")
    }

    @Test func aHigherNoteIsShorter() {
        func length(rate: Float) -> Int {
            let mixer = mixer()
            mixer.start(KeySoundTrigger(timbre: 0, rate: rate, gain: 1, delay: 0))
            var frames = 0
            while mixer.activeVoiceCount > 0, frames < 48000 {
                _ = render(mixer, frames: 128)
                frames += 128
            }
            return frames
        }
        #expect(length(rate: 2) < length(rate: 1))
    }

    @Test func voicesAreCappedAndTheOldestStolen() {
        let mixer = mixer()
        for _ in 0 ..< KeySoundMixer.maxVoices + 3 {
            mixer.start(KeySoundTrigger(timbre: 1, rate: 1, gain: 1, delay: 0))
        }
        #expect(mixer.activeVoiceCount == KeySoundMixer.maxVoices)
    }

    @Test func loudPileUpsStayInRange() {
        let mixer = mixer()
        for _ in 0 ..< KeySoundMixer.maxVoices {
            mixer.start(KeySoundTrigger(timbre: 4, rate: 1, gain: 3, delay: 0))
        }
        #expect(render(mixer, frames: 512).allSatisfy { abs($0) < 2 })
    }

    @Test func notesComeThroughTheLock() {
        let mixer = mixer()
        let queue = OSAllocatedUnfairLock(initialState: KeySoundQueue())
        queue.withLock { $0.push(KeySoundTrigger(timbre: 0, rate: 1, gain: 1, delay: 0)) }
        mixer.drain(queue)
        #expect(mixer.activeVoiceCount == 1)
        #expect(queue.withLock { $0.items.isEmpty })
    }

    @Test func theQueueIsBounded() {
        var queue = KeySoundQueue()
        for _ in 0 ..< KeySoundQueue.capacity + 5 {
            queue.push(KeySoundTrigger(timbre: 0, rate: 1, gain: 1, delay: 0))
        }
        #expect(queue.items.count == KeySoundQueue.capacity)
    }
}

@MainActor
struct KeySoundEngineTests {
    @Test func theTestRunnerNeverStartsAudio() {
        let engine = KeySoundEngine()
        #expect(engine.state == .unavailable)
        engine.prepare()
        #expect(engine.state == .unavailable)
        #expect(!engine.play(FeelVoiceModel.touchDown(letterVoice(0, 0))))
    }

    @Test func aRunningEngineQueuesOneNotePerHitAtItsLevel() {
        let engine = KeySoundEngine()
        engine.markRunningForMeasurement()
        let stroke = FeelVoiceModel.commit(
            .circle, voice: letterVoice(1, 1), direction: .circularClockwise, isReturn: false, reach: 0, typing: .commitText("O")
        )
        #expect(engine.play(stroke))
        #expect(engine.pendingCount == 3)
        engine.drainForMeasurement()
        #expect(engine.play(FeelVoiceModel.commit(.tap, voice: letterVoice(1, 1), direction: .tap, isReturn: false, reach: 0, typing: nil)))
        #expect(engine.pendingCount == 0, "a felt-only stroke queues nothing")
    }
}

// MARK: - Through the keyboard

@MainActor
private final class SoundRecorder {
    var sounds: [(click: KeyClick, stroke: FeelStroke)] = []

    func attach(to viewModel: KeyboardViewModel) {
        viewModel.keyClicks = KeyClickPlayer { [unowned self] click, stroke in sounds.append((click, stroke)) }
    }
}

@MainActor
struct DerivedKeySoundTests {
    @Test func eachKeySoundsItsOwnNote() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false, settings: [.keyClicksEnabled: true])
        let recorder = SoundRecorder()
        recorder.attach(to: scenario.viewModel)
        scenario.tap(GridSlot.topRight)
        scenario.tap(GridSlot.bottomLeft)
        scenario.tap(UtilitySlot.space)
        let pitches = recorder.sounds.map(\.stroke.first.pitch)
        #expect(pitches.count == 3, "a tap sounds once, on touch-down")
        #expect(pitches[0] > pitches[1], "top right above bottom left")
        #expect(pitches[2] < pitches[1], "space below the letters")
        #expect(recorder.sounds.map(\.click) == [.character, .character, .modifier])
    }

    @Test func aFlickSoundsItsDirectionOnRelease() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false, settings: [.keyClicksEnabled: true])
        let recorder = SoundRecorder()
        recorder.attach(to: scenario.viewModel)
        scenario.swipe(GridSlot.center, .swipeUp)
        #expect(recorder.sounds.count == 2, "the press, and the release's note")
        let press = recorder.sounds[0].stroke.first.pitch
        let release = recorder.sounds[1].stroke.first.pitch
        #expect(release == press + FeelVoiceModel.interval(of: .swipeUp))
    }

    @Test func modeKeysSoundTheirStep() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false, settings: [.keyClicksEnabled: true])
        let recorder = SoundRecorder()
        recorder.attach(to: scenario.viewModel)
        scenario.tap(UtilitySlot.symbols)
        #expect(scenario.mode == ModeNames.numeric)
        let step = recorder.sounds.last?.stroke.hits ?? []
        #expect(step.count == 2)
        #expect(step[1].pitch > step[0].pitch, "into numbers: rising")
    }

    @Test func noSoundsWithClicksOff() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        let recorder = SoundRecorder()
        recorder.attach(to: scenario.viewModel)
        scenario.swipe(GridSlot.center, .swipeUp)
        scenario.tap(UtilitySlot.symbols)
        #expect(recorder.sounds.isEmpty)
    }
}

// MARK: - ProMotion

@MainActor
struct FrameRateWindowTests {
    @Test func aTouchKeepsTheDisplayFastForTheLinger() {
        var window = FrameRateWindow()
        #expect(!window.isActive(at: 10))
        let started = window.engage(at: 10)
        #expect(started, "the first touch starts the boost")
        #expect(window.isActive(at: 10 + FrameRateWindow.linger - 0.01))
        let restarted = window.engage(at: 10.2)
        #expect(!restarted, "already running")
        #expect(window.isActive(at: 10.2 + FrameRateWindow.linger - 0.01), "each moment extends it")
        #expect(!window.isActive(at: 10.2 + FrameRateWindow.linger + 0.01))
        let again = window.engage(at: 20)
        #expect(again, "a touch after the window starts it again")
    }

    @Test func feelMomentsEngageTheBoost() {
        let settings = HapticSettings(defaults: InMemoryUserDefaults(), shouldPersist: false)
        var now: TimeInterval = 5
        let feel = KeyboardFeel(
            haptics: HapticFeedbackPlayer(settings: settings, detailed: RecordingHapticRenderer(), pulses: RecordingPulseRenderer()),
            now: { now }
        )
        #expect(!feel.boost.isEngaged)
        feel.touchDown(FeelVoiceModel.touchDown(letterVoice(0, 0)), mode: ModeNames.main)
        #expect(feel.boost.isEngaged)
        now += 1
        #expect(!feel.boost.isEngaged)
    }
}
