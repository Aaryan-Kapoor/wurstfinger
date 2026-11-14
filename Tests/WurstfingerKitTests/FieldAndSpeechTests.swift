//
//  FieldAndSpeechTests.swift
//  WurstfingerKitTests
//
//  What the keyboard shows in a sensitive field, what it says under
//  VoiceOver gesture typing, and the key clicks — through the real engine.
//

import CoreGraphics
import Foundation
import Testing
@testable import WurstfingerKit
@testable import WurstfingerScenarioKit

/// Records what the view model would have said or played.
@MainActor
private final class Recorder {
    var spoken: [SpokenTarget] = []
    var clicks: [KeyClick] = []
    var isVoiceOverRunning = true

    func attach(to viewModel: KeyboardViewModel) {
        viewModel.spokenFeedback = SpokenFeedback(
            isActive: { [unowned self] in isVoiceOverRunning },
            announce: { [unowned self] in spoken.append($0) }
        )
        viewModel.keyClicks = KeyClickPlayer { [unowned self] in clicks.append($0) }
    }
}

/// A slow flick from the centre of a key towards its lower right, at the
/// display rate: long enough for the engine to speculate on every sample.
private let slowDownRightFlick = TouchPath(samples: (0 ... 16).map { CGPoint(x: Double($0) * 2.5, y: Double($0) * 2.5) })

@MainActor
struct SensitiveFieldTests {
    @Test func aSensitiveFieldDrawsNoTrailAndAnOrdinaryOneDoes() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false, settings: [.gestureTrailEnabled: true])
        let viewModel = scenario.viewModel
        #expect(viewModel.gestureTuning.isTrailEnabled)
        viewModel.fieldTraits = FieldTraits(isSensitive: true)
        #expect(!viewModel.gestureTuning.isTrailEnabled)
        viewModel.reloadSettings()
        #expect(!viewModel.gestureTuning.isTrailEnabled, "a settings reload keeps the field's mask")
        viewModel.fieldTraits = .standard
        #expect(viewModel.gestureTuning.isTrailEnabled)
    }

    @Test func theMaskNeverTurnsATrailOn() {
        let tuning = GestureTuning.default
        #expect(!tuning.isTrailEnabled)
        #expect(tuning.applying(FieldTraits(isSensitive: true)) == tuning)
        #expect(tuning.applying(.standard) == tuning)
    }

    @Test func aSensitiveFieldLiftsNoGlyphOffTheKeyButStillTypes() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        scenario.viewModel.fieldTraits = FieldTraits(isSensitive: true)
        scenario.perform(slowDownRightFlick, on: GridSlot.topLeft)
        #expect(scenario.text == "v")
        #expect(scenario.viewModel.feel.board.pops.isEmpty)
    }

    @Test func anOrdinaryFieldLiftsTheGlyph() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        scenario.perform(slowDownRightFlick, on: GridSlot.topLeft)
        #expect(scenario.viewModel.feel.board.pops.map(\.text) == ["v"])
    }
}

@MainActor
struct GestureTypingSpeechTests {
    private func scenario(enabled: Bool = true) -> (KeyboardScenario, Recorder) {
        let scenario = KeyboardScenario(
            language: "en_US", autoCapitalize: false, settings: [.voiceOverGestureTyping: enabled]
        )
        let recorder = Recorder()
        recorder.attach(to: scenario.viewModel)
        return (scenario, recorder)
    }

    /// The key's own character on touch-down, then the target the flick
    /// heads for — each spelled out — and the flick types what was said last.
    @Test func aFlickSpeaksTheKeyThenItsTarget() {
        let (scenario, recorder) = scenario()
        scenario.perform(slowDownRightFlick, on: GridSlot.topLeft)
        #expect(recorder.spoken.first == .glyph("a"))
        #expect(recorder.spoken.last == .glyph("v"))
        #expect(scenario.text == "v")
    }

    @Test func aTargetIsSpokenOncePerChangeNotPerSample() {
        let (scenario, recorder) = scenario()
        scenario.perform(slowDownRightFlick, on: GridSlot.topLeft)
        #expect(recorder.spoken.count <= 4, "spoke \(recorder.spoken) for one flick")
        for (previous, next) in zip(recorder.spoken, recorder.spoken.dropFirst()) {
            #expect(previous != next, "repeated \(next)")
        }
    }

    /// A key whose binding has a name is read by it, not spelled out.
    @Test func aNamedKeyIsReadByName() throws {
        let (scenario, recorder) = scenario()
        let name = try #require(scenario.viewModel.activeModeFromDefinition?.key(for: UtilitySlot.delete)?
            .bindings[.tap]?.accessibilityLabel)
        scenario.tap(UtilitySlot.delete)
        #expect(recorder.spoken.first == .name(name))
    }

    @Test func silentWithoutVoiceOver() {
        let (scenario, recorder) = scenario()
        recorder.isVoiceOverRunning = false
        scenario.perform(slowDownRightFlick, on: GridSlot.topLeft)
        #expect(recorder.spoken.isEmpty)
        #expect(scenario.text == "v")
    }

    @Test func silentWithTheSettingOff() {
        let (scenario, recorder) = scenario(enabled: false)
        scenario.perform(slowDownRightFlick, on: GridSlot.topLeft)
        #expect(recorder.spoken.isEmpty)
    }
}

@MainActor
struct KeyClickTests {
    @Test func clicksFollowTheSystemKeyboardsThreeSounds() throws {
        let definition = try #require(KeyboardRegistry.load(id: "en_US"))
        let main = try #require(definition.mode(ModeNames.main))
        let letter = try #require(main.keys[GridSlot.topLeft])
        let delete = try #require(main.keys[UtilitySlot.delete])
        let space = try #require(main.keys[UtilitySlot.space])
        let symbols = try #require(main.keys[UtilitySlot.symbols])
        #expect(KeyClick(for: letter) == .character)
        #expect(KeyClick(for: delete) == .delete)
        #expect(KeyClick(for: space) == .modifier)
        #expect(KeyClick(for: symbols) == .modifier)
        #expect([KeyClick.character, .delete, .modifier].map(\.systemSoundID) == [1104, 1155, 1156])
    }

    @Test func aTouchClicksWhenTheSettingIsOn() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false, settings: [.keyClicksEnabled: true])
        let recorder = Recorder()
        recorder.attach(to: scenario.viewModel)
        scenario.tap(GridSlot.topLeft)
        scenario.tap(UtilitySlot.delete)
        #expect(recorder.clicks == [.character, .delete])
    }

    @Test func noClicksByDefault() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        let recorder = Recorder()
        recorder.attach(to: scenario.viewModel)
        scenario.tap(GridSlot.topLeft)
        #expect(recorder.clicks.isEmpty)
    }
}
