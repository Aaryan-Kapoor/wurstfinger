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

    /// Starts the engine again if it was wanted but is not running (it failed
    /// to start, or the system stopped it while the app was suspended). Cheap
    /// when there is nothing to do: called on touch-down.
    func resumeIfNeeded()

    /// Plays one click of about `intensity` and `sharpness` (already at the
    /// user's strength) `delay` seconds from now — a derived hit
    /// (`FeelHit`), from a bank of prebuilt one-click players. Returns false
    /// when it could not (the caller falls back).
    @discardableResult
    func playClick(intensity: Float, sharpness: Float, after delay: TimeInterval) -> Bool
}

extension HapticRenderer {
    func resumeIfNeeded() {}

    func playClick(intensity _: Float, sharpness _: Float, after _: TimeInterval) -> Bool { false }
}

/// The grid of one-click players that derived hits are played from.
///
/// A derived hit can have any intensity and sharpness, and a
/// `CHHapticPatternPlayer` cannot be built per keystroke (it parses a pattern
/// and talks to the haptic server). So the plane is cut into cells at the
/// resolution a finger can tell apart — eight intensities, roughly a third
/// louder each, and six sharpnesses — and one player per cell is built ahead
/// of time. A hit plays the nearest cell. Each cell has two players used in
/// turn, so a hit scheduled a few milliseconds ahead (the echo of a return
/// swipe) is not cut off by the next keystroke landing on the same cell.
///
/// Independent of the user's strength (the gain is applied to the hit before
/// it is quantized), so moving a slider never rebuilds the bank.
struct HapticClickBank: Equatable, Sendable {
    static let intensities: [Float] = [0.1, 0.16, 0.24, 0.34, 0.46, 0.6, 0.76, 0.94]
    static let sharpnesses: [Float] = [0.1, 0.28, 0.46, 0.64, 0.82, 1.0]
    /// Players per cell.
    static let alternates = 2

    static var cellCount: Int { intensities.count * sharpnesses.count }

    /// The cell nearest to a hit; nil for a hit too faint to feel.
    static func cell(intensity: Float, sharpness: Float) -> Int? {
        guard intensity >= intensities[0] * 0.5 else { return nil }
        let row = nearest(intensity, in: intensities)
        let column = nearest(sharpness, in: sharpnesses)
        return row * sharpnesses.count + column
    }

    /// The intensity and sharpness a cell plays.
    static func parameters(of cell: Int) -> (intensity: Float, sharpness: Float) {
        (intensities[cell / sharpnesses.count], sharpnesses[cell % sharpnesses.count])
    }

    private static func nearest(_ value: Float, in levels: [Float]) -> Int {
        var best = 0
        var distance = Float.greatestFiniteMagnitude
        for index in levels.indices {
            let d = abs(levels[index] - value)
            if d < distance {
                distance = d
                best = index
            }
        }
        return best
    }
}

/// The engine's lifecycle as plain data: when it may start, restart or give
/// up. Kept apart from `CoreHapticsRenderer` so every rule can be tested
/// without a Taptic Engine (this machine has none).
///
/// The rules it encodes:
/// - Nothing starts unless the keyboard asked for it (`prepare`) and has not
///   since let go of it (`suspend`): a stop or a server reset that arrives
///   while the keyboard is off screen must not bring the engine back.
/// - A failed start is retried, but only `maxStartFailures` times in a row;
///   one transient failure (the process was being suspended) must not silence
///   the detailed haptics for the rest of the process, and a persistent one
///   must not loop.
/// - The system stopping the engine because the app was suspended is not
///   restarted on the spot (it would fail); the next appearance starts it.
struct HapticEngineLifecycle: Equatable {
    enum State: Equatable {
        /// Not created yet, or suspended.
        case idle
        case starting
        case running
        /// The device cannot play haptics, or the engine could not be created
        /// in this process, or it failed to start `maxStartFailures` times in
        /// a row; the generators take over for good.
        case unavailable
    }

    /// Consecutive failed starts after which the engine is given up on.
    static let maxStartFailures = 3

    private(set) var state = State.idle
    /// Whether the keyboard wants the engine running (between `prepare` and
    /// `suspend`).
    private(set) var isWanted = false
    private(set) var failedStarts = 0

    /// The keyboard asked for the engine. Returns whether to start it now.
    mutating func prepare() -> Bool {
        isWanted = true
        return state == .idle
    }

    /// The engine is being started: `idle` becomes `starting`.
    mutating func startBegan() {
        if state == .idle { state = .starting }
    }

    /// The device or the process cannot do haptics.
    mutating func becameUnavailable() {
        state = .unavailable
    }

    /// The asynchronous start finished.
    mutating func startFinished(error: (any Error)?) {
        guard state == .starting else { return }
        if error == nil {
            state = .running
            failedStarts = 0
            return
        }
        failedStarts += 1
        state = failedStarts >= Self.maxStartFailures ? .unavailable : .idle
    }

    /// The system stopped the engine. Returns whether to start it again.
    mutating func stopped(applicationWasSuspended: Bool) -> Bool {
        guard state == .running || state == .starting else { return false }
        state = .idle
        return isWanted && !applicationWasSuspended
    }

    /// The haptic server restarted: the players are invalid. Returns whether
    /// to start the engine and rebuild them.
    mutating func reset() -> Bool {
        guard state != .unavailable, isWanted else { return false }
        state = .idle
        return true
    }

    /// A `start` on a player threw: the engine is not running after all.
    /// Returns whether to start it again.
    mutating func playFailed() -> Bool {
        guard state == .running else { return false }
        state = .idle
        return isWanted
    }

    /// The keyboard let go of the engine. Returns whether it has to be stopped.
    mutating func suspend() -> Bool {
        isWanted = false
        guard state == .running || state == .starting else { return false }
        state = .idle
        return true
    }
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
    typealias State = HapticEngineLifecycle.State

    private var lifecycle = HapticEngineLifecycle()
    var state: State { lifecycle.state }
    private var engine: CHHapticEngine?
    private var players: [HapticCue: CHHapticPatternPlayer] = [:]
    private var patterns: [HapticCue: HapticPatternSpec] = [:]
    /// `HapticClickBank.cellCount × alternates` one-click players, cell-major;
    /// empty until the engine exists, and filling in while `clickBankBuild`
    /// runs (a nil slot is not built yet).
    private var clicks: [CHHapticPatternPlayer?] = []
    /// Which alternate each cell plays next.
    private var nextAlternate: [UInt8] = []
    /// The build filling `clicks` a batch per main-actor turn, while it runs.
    private var clickBankBuild: Task<Void, Never>?

    /// Whether this device has a Taptic Engine Core Haptics can drive.
    static var isSupportedByHardware: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    init() {}

    var isReady: Bool { state == .running }

    func prepare(_ patterns: [HapticCue: HapticPatternSpec]) {
        self.patterns = patterns
        if lifecycle.prepare() { startIfNeeded() }
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
            // stopped handler has not run yet, and when it does it finds the
            // engine already idle and leaves the restart to us). Treat it as
            // not running and start it again.
            if lifecycle.playFailed() { startIfNeeded() }
            return false
        }
    }

    @discardableResult
    func playClick(intensity: Float, sharpness: Float, after delay: TimeInterval) -> Bool {
        guard state == .running, let engine, !clicks.isEmpty,
              let cell = HapticClickBank.cell(intensity: intensity, sharpness: sharpness)
        else { return false }
        let alternate = Int(nextAlternate[cell])
        nextAlternate[cell] = UInt8((alternate + 1) % HapticClickBank.alternates)
        let base = cell * HapticClickBank.alternates
        // While the bank is still being built, the other alternate may exist
        // already; with neither, the caller plays the designed pattern.
        guard let player = clicks[base + alternate] ?? clicks[base + (alternate + 1) % HapticClickBank.alternates]
        else { return false }
        let time = delay > 0 ? engine.currentTime + delay : CHHapticTimeImmediate
        do {
            try player.start(atTime: time)
            return true
        } catch {
            if lifecycle.playFailed() { startIfNeeded() }
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

    func resumeIfNeeded() {
        guard lifecycle.isWanted, state == .idle else { return }
        startIfNeeded()
    }

    func suspend() {
        guard lifecycle.suspend(), let engine else { return }
        engine.stop(completionHandler: nil)
    }

    // MARK: - Engine lifecycle

    private func startIfNeeded() {
        guard state == .idle else { return }
        guard Self.isSupportedByHardware else {
            lifecycle.becameUnavailable()
            return
        }
        if engine == nil {
            do {
                engine = try makeEngine()
            } catch {
                // A keyboard extension without Full Access (or a process the
                // haptic server refuses) ends up here: generators from now on.
                lifecycle.becameUnavailable()
                return
            }
        }
        lifecycle.startBegan()
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

    /// A failed start leaves the engine idle (the lifecycle gives up only after
    /// a few in a row) and is not retried at once, since whatever failed it
    /// is likely still true; `resumeIfNeeded` tries again at the next touch.
    private func didStart(error: (any Error)?) {
        lifecycle.startFinished(error: error)
    }

    /// The system stopped the engine (interruption, idle timeout, a system
    /// error). Restart it right away unless we stopped it ourselves or the
    /// app is being suspended (the next appearance starts it then).
    private func engineStopped(reason: CHHapticEngine.StoppedReason) {
        if lifecycle.stopped(applicationWasSuspended: reason == .applicationSuspended) { startIfNeeded() }
    }

    /// The haptic server restarted: every player is invalid. Rebuild them and
    /// start again, as Apple requires.
    private func engineReset() {
        guard lifecycle.reset() else { return }
        // Every player died with the server, the click bank's included.
        clickBankBuild?.cancel()
        clickBankBuild = nil
        clicks.removeAll()
        startIfNeeded()
        rebuildPlayers()
    }

    /// Puts a built player in its slot, unless the build it belongs to was
    /// superseded (an engine reset started another).
    fileprivate func setClick(_ player: CHHapticPatternPlayer, at slot: Int, for build: Task<Void, Never>?) {
        guard build != nil, clickBankBuild == build, clicks.indices.contains(slot) else { return }
        clicks[slot] = player
    }

    /// A build ended, done or failed (`complete` false empties the bank: a
    /// partial bank would play some hits and drop others).
    fileprivate func finishClickBank(_ build: Task<Void, Never>?, complete: Bool) {
        guard build != nil, clickBankBuild == build else { return }
        clickBankBuild = nil
        if !complete { clicks.removeAll() }
    }

    private func rebuildPlayers() {
        players.removeAll(keepingCapacity: true)
        guard let engine, state != .unavailable else { return }
        if clicks.isEmpty, clickBankBuild == nil { rebuildClickBank(on: engine) }
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

extension CoreHapticsRenderer {
    /// Players built per main-actor turn: each is a call into the haptic
    /// server, and touches must get through between batches.
    static let clickBankBatch = 8

    /// Builds the click bank: one single-transient player per cell and
    /// alternate. Gain-independent, so only the engine's own resets rebuild it.
    ///
    /// A batch per main-actor turn rather than all at once: building every
    /// player synchronously would put ~100 haptic-server calls on the frame the
    /// keyboard first appears, ahead of its first touch. The first alternate of
    /// every cell comes first, so the whole plane plays early; until a slot is
    /// built `playClick` returns false and the cue's designed pattern plays.
    fileprivate func rebuildClickBank(on engine: CHHapticEngine) {
        clicks = Array(repeating: nil, count: HapticClickBank.cellCount * HapticClickBank.alternates)
        nextAlternate = [UInt8](repeating: 0, count: HapticClickBank.cellCount)
        let build = Task { @MainActor [weak self] in
            // Its own handle: assigned below before this body can run, since
            // both are on the main actor and the assignment comes first.
            let build = self?.clickBankBuild
            var built = 0
            for alternate in 0 ..< HapticClickBank.alternates {
                for cell in 0 ..< HapticClickBank.cellCount {
                    guard !Task.isCancelled, let self else { return }
                    let (intensity, sharpness) = HapticClickBank.parameters(of: cell)
                    let spec = HapticPatternSpec(events: [.click(intensity, sharpness: sharpness)])
                    guard let pattern = try? CHHapticPattern(spec), let player = try? engine.makePlayer(with: pattern)
                    else {
                        finishClickBank(build, complete: false)
                        return
                    }
                    setClick(player, at: cell * HapticClickBank.alternates + alternate, for: build)
                    built += 1
                    if built % Self.clickBankBatch == 0 { await Task.yield() }
                }
            }
            self?.finishClickBank(build, complete: true)
        }
        clickBankBuild = build
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
