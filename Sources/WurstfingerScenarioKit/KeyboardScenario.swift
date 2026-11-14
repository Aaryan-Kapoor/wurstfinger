//
//  KeyboardScenario.swift
//  WurstfingerScenarioKit
//
//  Types on a real keyboard by moving a synthetic finger over it.
//
//  Every gesture is a touch path (`TouchPath`) fed, sample by sample, to the
//  view model's own `TouchEngine` — the object a touch surface feeds on a
//  device: it hit-tests the key, tracks the finger, classifies speculatively,
//  applies the long-press guard and commits in press order, then calls the view
//  model's `handleGesture` / `handleSlide`. Nothing is handed to the pipeline
//  pre-classified, so input, recognition, resolution and the action pipeline
//  are exercised together.
//

import CoreGraphics
import Foundation
import SwiftUI
@testable import WurstfingerKit

/// What a scenario gesture turned into, for tests that assert on recognition
/// rather than on the typed text.
struct GestureOutcome: Equatable {
    /// The gesture the recognizer classified the path as. `nil` for a slide
    /// key, which reports phases instead.
    var gesture: GestureType?
    var isReturn = false
    /// The slide phases a space or delete key reported.
    var slidePhases: [SlidePhase] = []
    /// Whether the long-press timer would have fired for this touch.
    var firedLongPress = false
    /// Whether the view model resolved the gesture to a binding.
    var dispatched = false
    /// Where the finger ended, in key sizes (see `GestureClassification`).
    var displacementInKeys: CGVector = .zero
    /// Whether the flick was a long swipe, which fires a global action instead
    /// of the key's own binding.
    var firedLongSwipe = false
}

@MainActor
final class KeyboardScenario {
    /// Settings store the view model reads. In memory, so nothing a scenario
    /// sets reaches disk or the user's real settings.
    let defaults: ScenarioDefaults
    let viewModel: KeyboardViewModel
    let target: ScenarioTextTarget

    /// Width the keyboard is laid out against, in points.
    let containerWidth: CGFloat

    private var touchCount: UInt64 = 0
    private let seed: UInt64

    /// - Parameters:
    ///   - language: Registered language id.
    ///   - containerWidth: Width of the view hosting the keyboard.
    ///   - autoCapitalize: Whether the "Auto-capitalize" setting is on. It is
    ///     off in a fresh installation; scenarios that type a sentence usually
    ///     want it on.
    ///   - settings: Further settings to store before the view model reads
    ///     them (label toggles, long-press digits, double-space period, ...).
    init(
        language: String = "en_US",
        containerWidth: CGFloat = 393,
        autoCapitalize: Bool = true,
        settings: [SettingsKey: Any] = [:],
        seed: UInt64 = 7
    ) {
        let defaults = ScenarioDefaults()
        defaults.set(autoCapitalize, forKey: SettingsKey.autoCapitalizeEnabled.rawValue)
        for (key, value) in settings {
            defaults.set(value, forKey: key.rawValue)
        }
        self.defaults = defaults
        self.containerWidth = containerWidth
        self.seed = seed

        let viewModel = KeyboardViewModel(userDefaults: defaults, shouldPersistSettings: false)
        let target = ScenarioTextTarget()
        viewModel.bindTextInputTarget(target)
        viewModel.loadDefinition(for: language)
        // What the controller does on appearance: pick the mode for the
        // (empty) document, so a sentence start comes up shifted.
        viewModel.refreshAutoCapitalization()
        self.viewModel = viewModel
        self.target = target
    }

    // MARK: - State

    /// The typed text, cursor ignored.
    var text: String { target.text }

    /// The caret position, in characters from the start of the text.
    var cursor: Int { target.cursor }

    /// Name of the keyboard mode on screen.
    var mode: String { viewModel.activeModeName }

    /// Layout metrics at the scenario's container width.
    var metrics: KeyboardLayoutMetrics {
        viewModel.layoutMetrics(forContainerWidth: containerWidth)
    }

    /// Clears the document and returns to the language's default mode, as when
    /// the keyboard is brought up on an empty field.
    func clear() {
        target.reset()
        viewModel.resetToDefaultMode()
        viewModel.refreshAutoCapitalization()
    }

    // MARK: - Gestures

    /// A tap on the key.
    @discardableResult
    func tap(_ keyId: String) -> GestureOutcome {
        var synth = synthesizer(for: keyId)
        return perform(synth.tap(), on: keyId)
    }

    /// A flick across the key toward `gesture` (one of the eight swipes).
    @discardableResult
    func swipe(_ keyId: String, _ gesture: GestureType, fraction: CGFloat = 0.85) -> GestureOutcome {
        var synth = synthesizer(for: keyId)
        return perform(synth.swipe(gesture, fraction: fraction), on: keyId)
    }

    /// A flick out toward `gesture` and back to where the finger started.
    @discardableResult
    func returnSwipe(_ keyId: String, _ gesture: GestureType) -> GestureOutcome {
        var synth = synthesizer(for: keyId)
        return perform(synth.returnSwipe(gesture), on: keyId)
    }

    /// A loop drawn on the key.
    @discardableResult
    func circle(_ keyId: String, clockwise: Bool = true) -> GestureOutcome {
        var synth = synthesizer(for: keyId)
        return perform(synth.circle(clockwise: clockwise), on: keyId)
    }

    /// A press held long enough for the long-press timer. Whether it does
    /// anything depends on the "long-press digits" setting, like on a device.
    @discardableResult
    func longPress(_ keyId: String) -> GestureOutcome {
        var synth = synthesizer(for: keyId)
        let hold = KeyboardConstants.LongPress.duration + 0.1
        return perform(synth.hold(duration: hold), on: keyId)
    }

    /// A straight drag over the key, for the space bar's cursor slide and the
    /// delete key's slide-to-delete.
    @discardableResult
    func drag(_ keyId: String, by translation: CGSize) -> GestureOutcome {
        var synth = synthesizer(for: keyId)
        return perform(synth.drag(by: translation), on: keyId)
    }

    /// Runs an arbitrary touch path over the key, through the view model's
    /// real `TouchEngine`: hit test, per-finger track, speculative
    /// classification, long-press guard, ordered commit, then the view model's
    /// dispatch — the same calls a touch surface makes.
    @discardableResult
    func perform(_ path: TouchPath, on keyId: String) -> GestureOutcome {
        var outcome = GestureOutcome()
        guard viewModel.activeModeFromDefinition?.key(for: keyId) != nil,
              configureEngine(recordingInto: { outcome = $0(outcome) }),
              let frame = engine.hitMap.key(withId: keyId)?.frame
        else { return outcome }

        let origin = CGPoint(x: frame.midX, y: frame.midY)
        func point(_ sample: CGPoint) -> CGPoint {
            CGPoint(x: origin.x + sample.x, y: origin.y + sample.y)
        }
        touchCount += 1
        let pointer = PointerID(truncatingIfNeeded: touchCount)
        let start = clock
        let interval = 1 / TouchPath.sampleRate
        engine.began(pointer, at: point(path.samples.first ?? .zero), time: start)
        for (index, sample) in path.samples.dropFirst().dropLast().enumerated() {
            engine.moved(pointer, samples: [TouchSample(location: point(sample), time: start + Double(index + 1) * interval)])
        }
        // A long press fires while the finger still rests on the key; the
        // engine's own guard decides whether it was still resting.
        if path.duration >= viewModel.gestureTuning.longPressDuration {
            engine.fireLongPressTimer(for: pointer)
        }
        engine.ended(pointer, at: point(path.end), time: start + path.duration)
        clock = start + path.duration + 0.2
        return outcome
    }

    /// The engine the scenario types through.
    var engine: TouchEngine { viewModel.touchEngine }

    /// Synthetic touch clock, advanced past each gesture so consecutive
    /// gestures never overlap (rollover is tested against the engine itself).
    private var clock: TimeInterval = 1000

    /// Hands the engine the active mode and callbacks that forward to the view
    /// model while recording what happened into the outcome.
    private func configureEngine(recordingInto record: @escaping ((GestureOutcome) -> GestureOutcome) -> Void) -> Bool {
        guard let mode = viewModel.activeModeFromDefinition,
              let (geometry, size) = viewModel.gridGeometry(forContainerWidth: containerWidth)
        else { return false }
        let viewModel = viewModel
        var actions = viewModel.touchEngineActions
        actions.gesture = { key, classification in
            let firedLongSwipe = viewModel.gestureTuning.longSwipe.action(for: classification) != nil
            let dispatched = viewModel.handleClassification(classification, keyId: key.id)
            record { outcome in
                var outcome = outcome
                outcome.gesture = classification.gesture
                outcome.isReturn = classification.isReturn
                outcome.displacementInKeys = classification.displacementInKeys
                outcome.firedLongSwipe = firedLongSwipe
                outcome.dispatched = dispatched
                return outcome
            }
        }
        actions.slide = { key, phase in
            viewModel.handleSlide(key, phase: phase)
            record { outcome in
                var outcome = outcome
                outcome.slidePhases.append(phase)
                outcome.dispatched = true
                return outcome
            }
        }
        actions.longPress = { key in
            let handled = viewModel.handleGesture(.longPress, keyId: key.id, isReturn: false)
            if handled {
                record { outcome in
                    var outcome = outcome
                    outcome.firedLongPress = true
                    outcome.gesture = .longPress
                    outcome.dispatched = true
                    return outcome
                }
            }
            return handled
        }
        engine.configure(
            geometry: geometry,
            keys: mode.keys,
            tuning: viewModel.gestureTuning,
            isLongPressEnabled: defaults.bool(forKey: SettingsKey.isLongPressDigitEnabled.rawValue),
            actions: actions
        )
        engine.updateSize(size)
        return true
    }

    // MARK: - Typing text

    /// Types `string` one character at a time by finding the gesture that
    /// produces each and performing it, switching modes through the keyboard's
    /// own mode keys where a character lives in another mode (an uppercase
    /// letter in `shifted`, a digit in `numeric`). Returns the characters no
    /// gesture of the loaded layout produces.
    @discardableResult
    func type(_ string: String) -> [Character] {
        var missing: [Character] = []
        for character in string where !typeCharacter(character) {
            missing.append(character)
        }
        return missing
    }

    private func typeCharacter(_ character: Character) -> Bool {
        guard let definition = viewModel.currentDefinition else { return false }
        let startMode = viewModel.activeModeName
        let wanted = Self.action(producing: character)

        // The mode on screen first, then the others in a stable order.
        let modeNames = [startMode] + definition.modes.keys.sorted().filter { $0 != startMode }
        for modeName in modeNames {
            guard let mode = definition.mode(modeName),
                  let (keyId, gesture) = Self.gesture(producing: wanted, in: mode)
            else { continue }
            if modeName != startMode {
                guard let (switchKey, switchGesture) = Self.gesture(
                    producing: .switchMode(modeName), in: viewModel.activeModeFromDefinition
                ) else { continue }
                perform(gesture: switchGesture, on: switchKey)
                guard viewModel.activeModeName == modeName else { continue }
            }
            perform(gesture: gesture, on: keyId)
            // A mode entered only to type one character is left again when the
            // layout does not do it itself (numeric stays until told).
            if modeName != startMode, viewModel.activeModeName == modeName,
               let back = Self.gesture(producing: .switchMode(startMode), in: viewModel.activeModeFromDefinition) {
                perform(gesture: back.1, on: back.0)
            }
            return true
        }
        return false
    }

    private func perform(gesture: GestureType, on keyId: String) {
        if gesture == .tap { tap(keyId) } else { swipe(keyId, gesture) }
    }

    /// The action that types `character`.
    private static func action(producing character: Character) -> KeyAction {
        switch character {
        case " ": .space
        case "\n": .newline
        default: .commitText(String(character))
        }
    }

    /// The first key and gesture (tap, then the eight swipes) whose binding
    /// performs `action`, searched in a stable order.
    private static func gesture(producing action: KeyAction, in mode: KeyboardMode?) -> (String, GestureType)? {
        guard let mode else { return nil }
        let gestures: [GestureType] = [.tap] + GestureType.allCases.filter(\.isSwipe)
        for keyId in mode.keys.keys.sorted() {
            guard let key = mode.keys[keyId] else { continue }
            for gesture in gestures where key.bindings[gesture]?.action == action {
                return (keyId, gesture)
            }
        }
        return nil
    }

    // MARK: - Geometry

    /// The key's rendered size in the current mode, in points.
    func keySize(_ keyId: String) -> CGSize {
        guard let frame = KeyboardGeometry.frames(
            of: viewModel, containerWidth: containerWidth
        )[keyId] else {
            return CGSize(width: metrics.cellWidth, height: metrics.cellHeight)
        }
        return frame.size
    }

    private func spanRatio(of keyId: String) -> CGFloat {
        guard let arrangement = viewModel.currentArrangement,
              let cell = GridLayoutSolver.solve(arrangement).first(where: { $0.keyId == keyId })
        else { return 1 }
        return CGFloat(cell.columnSpan) / CGFloat(cell.rowSpan)
    }

    private func synthesizer(for keyId: String) -> TouchSynthesizer {
        touchCount += 1
        return TouchSynthesizer(keySize: keySize(keyId), seed: seed &* 1000 &+ touchCount)
    }
}
