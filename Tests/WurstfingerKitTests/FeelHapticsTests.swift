//
//  FeelHapticsTests.swift
//  WurstfingerKitTests
//
//  The haptic vocabulary (cue → pattern), the strength scaling, the fallback
//  mapping, and the player's routing between Core Haptics and the generators —
//  against recording fakes, since nothing here can be felt.
//

import CoreGraphics
import CoreHaptics
import Foundation
import Testing
@testable import WurstfingerKit

/// Records what the player asks Core Haptics to do.
@MainActor
final class RecordingHapticRenderer: HapticRenderer {
    var isReady = true
    var playsSucceed = true
    private(set) var prepared: [[HapticCue: HapticPatternSpec]] = []
    private(set) var played: [(cue: HapticCue, delay: TimeInterval)] = []
    private(set) var stopped: [HapticCue] = []
    private(set) var suspendCount = 0

    var playedCues: [HapticCue] { played.map(\.cue) }

    func prepare(_ patterns: [HapticCue: HapticPatternSpec]) {
        prepared.append(patterns)
    }

    func play(_ cue: HapticCue, after delay: TimeInterval) -> Bool {
        guard playsSucceed else { return false }
        played.append((cue, delay))
        return true
    }

    func stop(_ cue: HapticCue) {
        stopped.append(cue)
    }

    func suspend() {
        suspendCount += 1
    }
}

/// Records the generator pulses the player falls back to.
@MainActor
final class RecordingPulseRenderer: PulseRenderer {
    private(set) var played: [HapticPulse] = []
    private(set) var prepared: [HapticPulse] = []

    func prepare(_ pulse: HapticPulse) { prepared.append(pulse) }
    func play(_ pulse: HapticPulse) { played.append(pulse) }
}

@MainActor
private func makePlayer(
    tap: CGFloat = HapticSettings.defaultTapIntensity,
    drag: CGFloat = HapticSettings.defaultDragIntensity,
    detailed: Bool = true
) -> (HapticFeedbackPlayer, RecordingHapticRenderer, RecordingPulseRenderer, HapticSettings) {
    let settings = HapticSettings(defaults: InMemoryUserDefaults(), shouldPersist: false)
    settings.tapIntensity = tap
    settings.dragIntensity = drag
    settings.isDetailedEnabled = detailed
    let renderer = RecordingHapticRenderer()
    let pulses = RecordingPulseRenderer()
    let player = HapticFeedbackPlayer(settings: settings, detailed: renderer, pulses: pulses)
    return (player, renderer, pulses, settings)
}

// MARK: - Vocabulary

@MainActor
struct HapticVocabularyTests {
    @Test func everyCueHasAPlayablePattern() {
        for cue in HapticCue.allCases {
            let pattern = HapticPatternSpec.pattern(for: cue)
            #expect(!pattern.events.isEmpty, "\(cue) has no events")
            for event in pattern.events {
                #expect((0 ... 1).contains(event.intensity), "\(cue) intensity out of range")
                #expect((0 ... 1).contains(event.sharpness), "\(cue) sharpness out of range")
                #expect(event.time >= 0)
            }
        }
    }

    @Test func everyPatternTranslatesToCoreHaptics() throws {
        for cue in HapticCue.allCases {
            _ = try CHHapticPattern(HapticPatternSpec.pattern(for: cue))
        }
    }

    @Test func allCasesListsEveryCueOnce() {
        #expect(Set(HapticCue.allCases).count == HapticCue.allCases.count)
        #expect(HapticCue.allCases.contains(.commit(.circle)))
        #expect(HapticCue.allCases.contains(.cursorTick(.rapid)))
    }

    /// Feedback must never outlast a keystroke at typing speed (8–10 a
    /// second): only the long-press swell is longer, by design.
    @Test func patternsAreShortExceptTheSwell() {
        for cue in HapticCue.allCases where cue != .longPressRamp {
            #expect(HapticPatternSpec.pattern(for: cue).duration <= 0.1, "\(cue) is too long")
        }
        #expect(HapticPatternSpec.pattern(for: .longPressRamp).duration == LongPressFeel.rampDuration)
    }

    @Test func eachCommitTypeFeelsDifferent() {
        let patterns = CommitType.allCases.map { HapticPatternSpec.pattern(for: .commit($0)) }
        for (index, pattern) in patterns.enumerated() {
            for other in patterns[(index + 1)...] {
                #expect(pattern != other)
            }
        }
    }

    /// The detent is felt while the finger moves; it must stay lighter than
    /// the touch-down and every commit, or a flick buzzes.
    @Test func theDirectionDetentIsTheLightestFlickFeedback() {
        let detent = HapticPatternSpec.pattern(for: .directionDetent).peakIntensity
        #expect(detent < HapticPatternSpec.pattern(for: .touchDown).peakIntensity)
        for kind in CommitType.allCases where kind != .tap {
            #expect(detent < HapticPatternSpec.pattern(for: .commit(kind)).peakIntensity)
        }
        #expect(HapticPatternSpec.pattern(for: .directionDetent).events[0].sharpness > 0.9)
    }

    /// Press and release read as one keystroke: the release is softer and
    /// duller than the press.
    @Test func aTapReleasesSofterThanItPresses() {
        let down = HapticPatternSpec.pattern(for: .touchDown).events[0]
        let up = HapticPatternSpec.pattern(for: .commit(.tap)).events[0]
        #expect(up.intensity < down.intensity)
        #expect(up.sharpness < down.sharpness)
    }

    @Test func crossingTheLongSwipeThresholdIsHeavierThanADetent() {
        #expect(
            HapticPatternSpec.pattern(for: .longSwipeArmed).peakIntensity
                > HapticPatternSpec.pattern(for: .directionDetent).peakIntensity * 2
        )
    }

    @Test func cursorTicksLightenAsTheSlideSpeedsUp() {
        let intensities = SlidePace.allCases.map { HapticPatternSpec.pattern(for: .cursorTick($0)).peakIntensity }
        #expect(intensities == intensities.sorted(by: >))
        #expect(Set(intensities).count == intensities.count)
    }

    @Test func theSwellRisesThroughItsCurve() throws {
        let ramp = HapticPatternSpec.pattern(for: .longPressRamp)
        let intensity = try #require(ramp.curves.first { $0.parameter == .intensity })
        let values = intensity.points.map(\.value)
        #expect(values == values.sorted())
        #expect(values.last == 1)
    }

    @Test func slideCuesFollowTheDragSlider() {
        #expect(HapticCue.deleteTick.channel == .slide)
        for pace in SlidePace.allCases { #expect(HapticCue.cursorTick(pace).channel == .slide) }
        for cue in HapticCue.allCases where cue != .deleteTick {
            if case .cursorTick = cue { continue }
            #expect(cue.channel == .touch, "\(cue) should follow the tap slider")
        }
    }

    @Test func pipelineActionsMapToStateCues() {
        #expect(HapticCue.forPipelineAction(.switchMode("numeric")) == .modeSwitch)
        #expect(HapticCue.forPipelineAction(.switchToNextLanguage) == .languageSwitch)
        #expect(HapticCue.forPipelineAction(.advanceToNextInputMode) == .languageSwitch)
        #expect(HapticCue.forPipelineAction(.dismissKeyboard) == .dismiss)
        #expect(HapticCue.forPipelineAction(.commitText("a")) == nil)
        #expect(HapticCue.forPipelineAction(.copy) == nil, "clipboard confirms its own successes")
        #expect(HapticCue.forPipelineAction(.deleteBackward) == nil)
    }

    @Test func slidePaceClassifiesTheGapBetweenSteps() {
        #expect(SlidePace.forStepGap(nil) == .deliberate)
        #expect(SlidePace.forStepGap(0.2) == .deliberate)
        #expect(SlidePace.forStepGap(0.06) == .steady)
        #expect(SlidePace.forStepGap(0.03) == .brisk)
        #expect(SlidePace.forStepGap(0.01) == .rapid)
    }
}

// MARK: - Strength

@MainActor
struct HapticStrengthTests {
    @Test func offIsSilentAndTheLevelsRiseToFull() {
        #expect(HapticGain.gain(for: 0) == 0)
        let gains = HapticIntensityLevel.allCases.map { HapticGain.gain(for: $0.storedIntensity) }
        #expect(gains == gains.sorted())
        #expect(Set(gains).count == gains.count, "every level must feel different")
        #expect(gains.last == 1)
        #expect(gains[1] >= 0.35, "the lowest audible level must still be felt")
    }

    @Test func lighterLevelsAreCrisperStrongerOnesRounder() {
        #expect(HapticGain.sharpnessShift(for: HapticIntensityLevel.tick.storedIntensity) > 0)
        #expect(HapticGain.sharpnessShift(for: HapticIntensityLevel.heavy.storedIntensity) < 0)
        #expect(HapticGain.sharpnessShift(for: 0) == 0)
    }

    @Test func scalingMultipliesIntensityAndShiftsSharpnessWithinRange() {
        let spec = HapticPatternSpec(
            events: [.click(0.8, sharpness: 0.95), .buzz(at: 0.01, for: 0.05, 0.5, sharpness: 0.02)],
            curves: [.init(parameter: .intensity, points: [.init(time: 0, value: 0.3)])]
        )
        let scaled = spec.scaled(by: 0.5, sharpnessShift: 0.1)
        #expect(scaled.events[0].intensity == 0.4)
        #expect(scaled.events[0].sharpness == 1, "clamped")
        #expect(scaled.events[1].intensity == 0.25)
        #expect(abs(scaled.events[1].sharpness - 0.12) < 0.0001)
        #expect(scaled.curves == spec.curves, "curves are relative and stay")
        #expect(spec.scaled(by: 3).events.allSatisfy { $0.intensity <= 1 })
    }

    @Test func preparedPatternsCarryTheUsersStrength() throws {
        let tap = HapticIntensityLevel.medium.storedIntensity
        let drag = HapticIntensityLevel.tick.storedIntensity
        let patterns = HapticFeedbackPlayer.patterns(tapIntensity: tap, dragIntensity: drag)
        let touch = try #require(patterns[.touchDown])
        #expect(touch == HapticPatternSpec.pattern(for: .touchDown)
            .scaled(by: HapticGain.gain(for: tap), sharpnessShift: HapticGain.sharpnessShift(for: tap)))
        let delete = try #require(patterns[.deleteTick])
        #expect(delete == HapticPatternSpec.pattern(for: .deleteTick)
            .scaled(by: HapticGain.gain(for: drag), sharpnessShift: HapticGain.sharpnessShift(for: drag)))
        #expect(patterns.count == HapticCue.allCases.count)
    }

    @Test func anOffSliderBuildsNoPlayersForItsCues() {
        let patterns = HapticFeedbackPlayer.patterns(tapIntensity: 0.5, dragIntensity: 0)
        #expect(patterns[.deleteTick] == nil)
        #expect(patterns[.cursorTick(.steady)] == nil)
        #expect(patterns[.touchDown] != nil)
    }
}

// MARK: - Fallback

@MainActor
struct HapticFallbackTests {
    @Test func theFallbackKeepsTheOriginalFeel() {
        let intensity = HapticIntensityLevel.light.storedIntensity
        #expect(HapticCue.touchDown.fallbackPulse(intensity: intensity) == .pulse(for: intensity))
        #expect(HapticCue.deleteTick.fallbackPulse(intensity: intensity) == .pulse(for: intensity))
        #expect(HapticCue.modeSwitch.fallbackPulse(intensity: intensity) == .selectionTick)
        #expect(HapticCue.clipboardSuccess.fallbackPulse(intensity: intensity) == .selectionTick)
    }

    @Test func detentsFallBackToSelectionTicks() {
        for cue in [HapticCue.directionDetent, .centerDetent, .returnDetent, .circleClosed, .longSwipeArmed] {
            #expect(cue.fallbackPulse(intensity: 0.5) == .selectionTick)
        }
    }

    /// A second generator impact per keystroke reads as a double buzz, and
    /// the generators cannot swell.
    @Test func releaseClicksAndTheSwellHaveNoFallback() {
        for kind in [CommitType.tap, .swipe, .returnSwipe, .circle] {
            #expect(HapticCue.commit(kind).fallbackPulse(intensity: 0.9) == nil)
        }
        #expect(HapticCue.longPressRamp.fallbackPulse(intensity: 0.9) == nil)
    }

    @Test func offIsSilentInTheFallbackToo() {
        for cue in HapticCue.allCases {
            #expect(cue.fallbackPulse(intensity: 0) == nil)
        }
    }
}

// MARK: - Player routing

@MainActor
struct HapticPlayerTests {
    @Test func preparingBuildsEveryCueAtTheUsersStrength() throws {
        let (player, renderer, _, settings) = makePlayer()
        player.prepareIfNeeded()
        let prepared = try #require(renderer.prepared.last)
        #expect(prepared == HapticFeedbackPlayer.patterns(
            tapIntensity: settings.tapIntensity, dragIntensity: settings.dragIntensity
        ))
        // A second prepare with nothing changed builds nothing.
        player.prepareIfNeeded()
        #expect(renderer.prepared.count == 1)
    }

    @Test func cuesPlayThroughCoreHapticsWhenItIsReady() {
        let (player, renderer, pulses, _) = makePlayer()
        player.prepareIfNeeded()
        player.play(.touchDown)
        player.play(.commit(.swipe))
        player.play(.directionDetent)
        #expect(renderer.playedCues == [.touchDown, .commit(.swipe), .directionDetent])
        #expect(pulses.played.isEmpty)
    }

    @Test func anOffSliderSilencesItsCuesOnly() {
        let (player, renderer, pulses, _) = makePlayer(tap: 0, drag: 0.3)
        player.prepareIfNeeded()
        player.play(.touchDown)
        player.play(.commit(.tap))
        player.play(.deleteTick)
        #expect(renderer.playedCues == [.deleteTick])
        #expect(pulses.played.isEmpty)
    }

    @Test func aNotReadyEngineFallsBackToTheGenerators() {
        let (player, renderer, pulses, settings) = makePlayer()
        renderer.isReady = false
        player.play(.touchDown)
        player.play(.directionDetent)
        player.play(.commit(.tap))
        #expect(renderer.playedCues.isEmpty)
        #expect(pulses.played == [.pulse(for: settings.tapIntensity), .selectionTick])
    }

    @Test func aFailedPlayFallsBackToo() {
        let (player, renderer, pulses, _) = makePlayer()
        renderer.playsSucceed = false
        player.play(.modeSwitch)
        #expect(pulses.played == [.selectionTick])
    }

    @Test func detailedHapticsOffUsesOnlyTheGenerators() {
        let (player, renderer, pulses, settings) = makePlayer(detailed: false)
        player.prepareIfNeeded()
        player.play(.touchDown)
        #expect(renderer.playedCues.isEmpty)
        #expect(renderer.prepared.isEmpty)
        #expect(pulses.played == [.pulse(for: settings.tapIntensity)])
    }

    @Test func aDelayedCueHasNoGeneratorFallback() {
        let (player, renderer, pulses, _) = makePlayer()
        renderer.isReady = false
        player.play(.longPressRamp, after: 0.4)
        #expect(pulses.played.isEmpty)
    }

    @Test func theSwellIsScheduledAhead() throws {
        let (player, renderer, _, _) = makePlayer()
        player.prepareIfNeeded()
        player.play(.longPressRamp, after: 0.44)
        let played = try #require(renderer.played.last)
        #expect(played.cue == .longPressRamp)
        #expect(played.delay == 0.44)
        player.stop(.longPressRamp)
        #expect(renderer.stopped == [.longPressRamp])
    }

    @Test func withoutFullAccessNothingStartsOrPlays() {
        let (player, renderer, pulses, _) = makePlayer()
        player.isAccessGranted = false
        player.prepareIfNeeded()
        player.play(.touchDown)
        #expect(renderer.prepared.isEmpty)
        #expect(renderer.playedCues.isEmpty)
        #expect(pulses.played.isEmpty)
    }

    @Test func aSliderChangeRebuildsThePlayers() throws {
        let (player, renderer, _, settings) = makePlayer()
        player.prepareIfNeeded()
        settings.tapIntensity = HapticIntensityLevel.heavy.storedIntensity
        player.refreshIfSettingsChanged()
        #expect(renderer.prepared.count == 2)
        let touch = try #require(renderer.prepared.last?[.touchDown])
        #expect(touch.peakIntensity == HapticPatternSpec.pattern(for: .touchDown).peakIntensity)
    }

    @Test func turningDetailedHapticsOffSuspendsTheEngine() {
        let (player, renderer, _, settings) = makePlayer()
        player.prepareIfNeeded()
        settings.isDetailedEnabled = false
        player.refreshIfSettingsChanged()
        #expect(renderer.suspendCount == 1)
    }

    @Test func suspendingAndReappearingStartsAgain() {
        let (player, renderer, _, _) = makePlayer()
        player.prepareIfNeeded()
        player.suspend()
        #expect(renderer.suspendCount == 1)
        player.prepareIfNeeded()
        #expect(renderer.prepared.count == 2)
    }

    @Test func theLegacyEntryPointsPlayTheirCues() {
        let (player, renderer, _, _) = makePlayer(drag: 0.5)
        player.prepareIfNeeded()
        player.tap()
        player.drag()
        player.stateChange()
        player.trigger(.tap)
        #expect(renderer.playedCues == [.touchDown, .deleteTick, .modeSwitch, .touchDown])
    }
}

// MARK: - Settings

@MainActor
struct DetailedHapticsSettingTests {
    @Test func detailedHapticsDefaultOnAndPersist() {
        let defaults = InMemoryUserDefaults()
        let settings = HapticSettings(defaults: defaults, shouldPersist: true)
        #expect(settings.isDetailedEnabled)
        settings.isDetailedEnabled = false
        #expect(defaults.object(forKey: SettingsKey.detailedHapticsEnabled.rawValue) as? Bool == false)
        #expect(!HapticSettings(defaults: defaults, shouldPersist: false).isDetailedEnabled)
    }

    @Test func aReloadPicksUpTheSwitch() {
        let defaults = InMemoryUserDefaults()
        let settings = HapticSettings(defaults: defaults, shouldPersist: false)
        defaults.set(false, forKey: SettingsKey.detailedHapticsEnabled.rawValue)
        settings.reload()
        #expect(!settings.isDetailedEnabled)
    }

    @Test func channelsReadTheirSliders() {
        let settings = HapticSettings(defaults: InMemoryUserDefaults(), shouldPersist: false)
        settings.tapIntensity = 0.7
        settings.dragIntensity = 0.1
        #expect(settings.intensity(for: .touch) == 0.7)
        #expect(settings.intensity(for: .slide) == 0.1)
    }

    @Test func keyAnimationsAreOnInAStockInstallation() {
        #expect(KeyRenderSettings.stock.areKeyAnimationsEnabled)
    }
}
