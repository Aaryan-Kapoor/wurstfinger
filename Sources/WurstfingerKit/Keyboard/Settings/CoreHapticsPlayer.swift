//
//  CoreHapticsPlayer.swift
//  Wurstfinger
//
//  Renders the haptic vocabulary (`HapticPatterns.swift`) on the Taptic
//  Engine through Core Haptics, with the UIKit feedback generators as the
//  renderer of last resort.
//

import CoreHaptics
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Something that can play prepared haptic cues. The player (`HapticFeedbackPlayer`)
/// decides *what* to play and how strong; a renderer only plays it.
///
/// Main-actor and synchronous: `play` is called from inside the touch event
/// that caused it and returns as soon as the command is issued.
@MainActor
protocol HapticRenderer: AnyObject {
    /// Whether `play` can currently produce anything.
    var isReady: Bool { get }

    /// Builds what is needed to play `patterns` (already at the user's
    /// strength) — ahead of time, never per touch. Cues missing from the map
    /// are silent. Replaces anything prepared before.
    func prepare(_ patterns: [HapticCue: HapticPatternSpec])

    /// Plays a prepared cue `delay` seconds from now. Returns false when it
    /// could not (the caller falls back).
    @discardableResult
    func play(_ cue: HapticCue, after delay: TimeInterval) -> Bool

    /// Stops a cue that is playing or scheduled (the long-press ramp).
    func stop(_ cue: HapticCue)

    /// Releases the hardware while the keyboard is off screen.
    func suspend()
}

/// Core Haptics renderer.
///
/// **Kept running.** A `CHHapticEngine` takes tens of milliseconds to start,
/// which would land on the first keystroke after every pause if the engine
/// were allowed to idle down. So auto-shutdown is off and the engine is
/// started when the keyboard appears (`prepare`), kept running while it is on
/// screen, and stopped when it goes away (`suspend`). If the system stops it
/// anyway — an audio-session interruption, the haptic server resetting — the
/// handlers restart it and rebuild the players, off the touch path.
///
/// **Players ahead of time.** One `CHHapticPatternPlayer` per cue, built when
/// the patterns are prepared (the keyboard appears, or the user moves a
/// slider). Playing is a single `start(atTime:)`: no allocation, no pattern
/// parsing, no await.
///
/// **Haptics only.** `playsHapticsOnly` keeps the engine off the audio
/// session, so the keyboard never interrupts or ducks the host app's audio.
///
/// Compiled on macOS too (Core Haptics exists there), where the hardware
/// reports no support and `isReady` stays false.
@MainActor
final class CoreHapticsRenderer: HapticRenderer {
    enum State: Equatable {
        /// Not created yet, or suspended.
        case idle
        case starting
        case running
        /// The device cannot play haptics, or the engine could not be created
        /// in this process; the generators take over for good.
        case unavailable
    }

    private(set) var state = State.idle
    private var engine: CHHapticEngine?
    private var players: [HapticCue: CHHapticPatternPlayer] = [:]
    private var patterns: [HapticCue: HapticPatternSpec] = [:]

    /// Whether this device has a Taptic Engine Core Haptics can drive.
    static var isSupportedByHardware: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    init() {}

    var isReady: Bool { state == .running }

    func prepare(_ patterns: [HapticCue: HapticPatternSpec]) {
        self.patterns = patterns
        startIfNeeded()
        rebuildPlayers()
    }

    @discardableResult
    func play(_ cue: HapticCue, after delay: TimeInterval) -> Bool {
        guard state == .running, let engine, let player = players[cue] else { return false }
        let time = delay > 0 ? engine.currentTime + delay : CHHapticTimeImmediate
        do {
            try player.start(atTime: time)
            return true
        } catch {
            // The engine stopped between our bookkeeping and this call (the
            // stopped handler has not run yet). Treat it as not running; the
            // handler restarts it.
            state = .idle
            return false
        }
    }

    func stop(_ cue: HapticCue) {
        guard let player = players[cue] else { return }
        if let advanced = player as? CHHapticAdvancedPatternPlayer {
            // Also drops a start that is scheduled but has not begun.
            try? advanced.cancel()
        } else {
            try? player.stop(atTime: CHHapticTimeImmediate)
        }
    }

    func suspend() {
        guard let engine, state == .running || state == .starting else { return }
        state = .idle
        engine.stop(completionHandler: nil)
    }

    // MARK: - Engine lifecycle

    private func startIfNeeded() {
        guard state == .idle else { return }
        guard Self.isSupportedByHardware else {
            state = .unavailable
            return
        }
        if engine == nil {
            do {
                engine = try makeEngine()
            } catch {
                // A keyboard extension without Full Access (or a process the
                // haptic server refuses) ends up here: generators from now on.
                state = .unavailable
                return
            }
        }
        state = .starting
        // Asynchronous start: never block the main thread on the haptic
        // server. Until it completes, `play` returns false and the
        // generators cover.
        engine?.start(completionHandler: { @Sendable [weak self] error in
            Task { @MainActor in self?.didStart(error: error) }
        })
    }

    private func makeEngine() throws -> CHHapticEngine {
        let engine = try CHHapticEngine()
        engine.playsHapticsOnly = true
        engine.isAutoShutdownEnabled = false
        // Both handlers run on an internal Core Haptics queue: hop to the
        // main actor, where all engine state lives. `@Sendable` keeps the
        // closures nonisolated, so Swift's runtime isolation check does not
        // trap when Core Haptics calls them off the main thread.
        engine.stoppedHandler = { @Sendable [weak self] reason in
            Task { @MainActor in self?.engineStopped(reason: reason) }
        }
        engine.resetHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.engineReset() }
        }
        return engine
    }

    private func didStart(error: (any Error)?) {
        guard state == .starting else { return }
        state = error == nil ? .running : .unavailable
    }

    /// The system stopped the engine (interruption, idle timeout, a system
    /// error). Restart it right away unless we stopped it ourselves.
    private func engineStopped(reason: CHHapticEngine.StoppedReason) {
        guard state == .running || state == .starting else { return }
        state = .idle
        startIfNeeded()
    }

    /// The haptic server restarted: every player is invalid. Rebuild them and
    /// start again, as Apple requires.
    private func engineReset() {
        guard state != .unavailable else { return }
        state = .idle
        startIfNeeded()
        rebuildPlayers()
    }

    private func rebuildPlayers() {
        players.removeAll(keepingCapacity: true)
        guard let engine, state != .unavailable else { return }
        for (cue, spec) in patterns {
            guard let pattern = try? CHHapticPattern(spec) else { continue }
            // The ramp is scheduled ahead and cancelled when the finger moves,
            // which needs the advanced player's `cancel()`.
            let player: CHHapticPatternPlayer? = cue == .longPressRamp
                ? try? engine.makeAdvancedPlayer(with: pattern)
                : try? engine.makePlayer(with: pattern)
            if let player { players[cue] = player }
        }
    }
}

extension CHHapticPattern {
    /// Translates a vocabulary entry.
    convenience init(_ spec: HapticPatternSpec) throws {
        let events = spec.events.map { event -> CHHapticEvent in
            var parameters = [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: event.intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: event.sharpness),
            ]
            switch event.eventType {
            case .transient:
                return CHHapticEvent(eventType: .hapticTransient, parameters: parameters, relativeTime: event.time)
            case let .continuous(duration):
                if event.attack > 0 { parameters.append(.init(parameterID: .attackTime, value: event.attack)) }
                if event.release > 0 { parameters.append(.init(parameterID: .releaseTime, value: event.release)) }
                return CHHapticEvent(
                    eventType: .hapticContinuous, parameters: parameters,
                    relativeTime: event.time, duration: duration
                )
            }
        }
        let curves = spec.curves.map { curve in
            CHHapticParameterCurve(
                parameterID: curve.parameter == .intensity ? .hapticIntensityControl : .hapticSharpnessControl,
                controlPoints: curve.points.map {
                    CHHapticParameterCurve.ControlPoint(relativeTime: $0.time, value: $0.value)
                },
                relativeTime: 0
            )
        }
        try self.init(events: events, parameterCurves: curves)
    }
}

/// The UIKit feedback generators (on macOS, the trackpad shims in
/// `UIKitShims+macOS.swift`). They cannot shape a pattern; each cue maps to a
/// pulse (`HapticCue.fallbackPulse`), resolved by the player.
@MainActor
final class GeneratorRenderer {
    /// Cached per style, so a pulse allocates nothing.
    private lazy var impacts: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = {
        var generators: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]
        for style in [UIImpactFeedbackGenerator.FeedbackStyle.soft, .light, .medium, .heavy] {
            generators[style] = UIImpactFeedbackGenerator(style: style)
        }
        return generators
    }()

    private lazy var selection = UISelectionFeedbackGenerator()

    func prepare(_ pulse: HapticPulse) {
        switch pulse {
        case .selectionTick: selection.prepare()
        case let .impact(style): impacts[style]?.prepare()
        }
    }

    func play(_ pulse: HapticPulse) {
        switch pulse {
        case .selectionTick:
            selection.selectionChanged()
            selection.prepare()
        case let .impact(style):
            guard let generator = impacts[style] else { return }
            generator.impactOccurred()
            // Keep the Taptic Engine warm so the next keystroke fires
            // without ramp-up latency.
            generator.prepare()
        }
    }
}
