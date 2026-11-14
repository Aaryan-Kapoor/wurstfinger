//
//  KeySound.swift
//  Wurstfinger
//
//  The keyboard's own key sounds: a handful of instruments synthesized once,
//  played at the pitch each touch moment derives (`FeelVoiceModel`) through a
//  tiny mixer on the audio thread.
//

import AVFAudio
import Foundation
import os

// MARK: - Instruments

/// Synthesizes the instruments (`FeelTimbre`) as short mono samples, once,
/// at the output's sample rate. Pure arithmetic — modal partials with their
/// own decays, a filtered noise transient, a soft attack — deterministic (a
/// fixed noise seed), so tests can check every instrument.
///
/// Every instrument is tuned to `baseFrequency`; a hit plays it faster or
/// slower for its pitch (`FeelHit.rate`), like a sampler: a higher note is
/// also a shorter one, as with any struck object.
enum KeySoundSynth {
    /// The note a hit of pitch 0 plays (C5).
    static let baseFrequency: Double = 523.25
    /// Length of every instrument at its base pitch.
    static let duration: Double = 0.09

    /// One partial: a frequency ratio to the base, its amplitude and its
    /// decay time constant in seconds.
    private struct Mode {
        var ratio: Double
        var amplitude: Double
        var decay: Double
    }

    /// The recipe of an instrument.
    private struct Recipe {
        var modes: [Mode]
        /// Amplitude and decay of the noise transient (the strike).
        var noise: Double
        var noiseDecay: Double
        /// One-pole smoothing of the noise (0: white, near 1: dark).
        var noiseDarkness: Double
        /// Attack ramp in seconds.
        var attack: Double
        /// Fractional pitch drop over the first 20 ms (a thump's sag).
        var pitchDrop: Double = 0
    }

    private static func recipe(for timbre: FeelTimbre) -> Recipe {
        switch timbre {
        case .wood:
            Recipe(
                modes: [Mode(ratio: 1, amplitude: 1, decay: 0.018), Mode(ratio: 2.32, amplitude: 0.42, decay: 0.008),
                        Mode(ratio: 4.25, amplitude: 0.16, decay: 0.004)],
                noise: 0.22, noiseDecay: 0.0018, noiseDarkness: 0.55, attack: 0.0004
            )
        case .glass:
            Recipe(
                modes: [Mode(ratio: 1, amplitude: 0.7, decay: 0.03), Mode(ratio: 2.76, amplitude: 0.55, decay: 0.02),
                        Mode(ratio: 5.4, amplitude: 0.22, decay: 0.008)],
                noise: 0.08, noiseDecay: 0.001, noiseDarkness: 0.1, attack: 0.0003
            )
        case .bell:
            Recipe(
                modes: [Mode(ratio: 1, amplitude: 1, decay: 0.035), Mode(ratio: 2, amplitude: 0.32, decay: 0.024),
                        Mode(ratio: 3, amplitude: 0.18, decay: 0.02), Mode(ratio: 4.2, amplitude: 0.1, decay: 0.012)],
                noise: 0.05, noiseDecay: 0.001, noiseDarkness: 0.3, attack: 0.0006
            )
        case .felt:
            Recipe(
                modes: [Mode(ratio: 1, amplitude: 1, decay: 0.02), Mode(ratio: 2, amplitude: 0.12, decay: 0.008)],
                noise: 0.3, noiseDecay: 0.005, noiseDarkness: 0.85, attack: 0.0015
            )
        case .thump:
            Recipe(
                modes: [Mode(ratio: 0.5, amplitude: 1, decay: 0.03), Mode(ratio: 1, amplitude: 0.3, decay: 0.014)],
                noise: 0.3, noiseDecay: 0.004, noiseDarkness: 0.9, attack: 0.001, pitchDrop: 0.15
            )
        case .dull:
            Recipe(
                modes: [Mode(ratio: 1, amplitude: 1, decay: 0.012), Mode(ratio: 1.5, amplitude: 0.4, decay: 0.008)],
                noise: 0.4, noiseDecay: 0.003, noiseDarkness: 0.75, attack: 0.0004
            )
        case .tick:
            Recipe(
                modes: [Mode(ratio: 3, amplitude: 0.35, decay: 0.003)],
                noise: 0.85, noiseDecay: 0.0015, noiseDarkness: 0, attack: 0.0001
            )
        }
    }

    /// The instrument's samples at `sampleRate`, peak-normalized to 0.9.
    static func render(_ timbre: FeelTimbre, sampleRate: Double) -> [Float] {
        let recipe = recipe(for: timbre)
        let count = max(Int(duration * sampleRate), 1)
        var samples = [Float](repeating: 0, count: count)
        var phases = [Double](repeating: 0, count: recipe.modes.count)
        var seed: UInt32 = 0x9E37_79B9 &+ UInt32(timbre.rawValue)
        var noiseState = 0.0
        var peak: Float = 0
        for index in 0 ..< count {
            let time = Double(index) / sampleRate
            let sag = 1 - recipe.pitchDrop * min(time / 0.02, 1)
            var value = 0.0
            for (modeIndex, mode) in recipe.modes.enumerated() {
                phases[modeIndex] += 2 * Double.pi * baseFrequency * mode.ratio * sag / sampleRate
                value += mode.amplitude * exp(-time / mode.decay) * sin(phases[modeIndex])
            }
            // xorshift noise, darkened by a one-pole low-pass.
            seed ^= seed << 13
            seed ^= seed >> 17
            seed ^= seed << 5
            let white = Double(seed) / Double(UInt32.max) * 2 - 1
            noiseState = recipe.noiseDarkness * noiseState + (1 - recipe.noiseDarkness) * white
            value += recipe.noise * exp(-time / recipe.noiseDecay) * noiseState
            value *= min(time / max(recipe.attack, 1 / sampleRate), 1)
            samples[index] = Float(value)
            peak = max(peak, abs(Float(value)))
        }
        // Fade the last 15 % out: a note cut off while still ringing would end
        // in a click of its own.
        let fadeLength = max(count * 15 / 100, 1)
        for offset in 0 ..< fadeLength {
            let index = count - fadeLength + offset
            let gain = 0.5 * (1 + cos(Double.pi * Double(offset) / Double(fadeLength)))
            samples[index] *= Float(gain)
        }
        if peak > 0 {
            let scale = 0.9 / peak
            for index in samples.indices { samples[index] *= scale }
        }
        return samples
    }

    /// Every instrument, indexed by `FeelTimbre.rawValue`.
    static func renderAll(sampleRate: Double) -> [[Float]] {
        FeelTimbre.allCases.map { render($0, sampleRate: sampleRate) }
    }
}

// MARK: - Handing hits to the audio thread

/// One note for the mixer: which instrument, how fast to play it (its pitch),
/// how loud, and how many seconds after the moment.
struct KeySoundTrigger: Equatable, Sendable {
    var timbre: UInt8
    var rate: Float
    var gain: Float
    var delay: Float
}

/// The notes waiting for the audio thread.
///
/// Behind an unfair lock: the main thread holds it for the few nanoseconds of
/// an append; the audio thread only ever *tries* it (`withLockIfAvailable`),
/// so the real-time thread never waits — at worst it picks the notes up one
/// buffer (a few milliseconds) later. The storage is reserved up front and
/// emptied in place, so neither side allocates.
struct KeySoundQueue: Sendable {
    static let capacity = 16
    private(set) var items: [KeySoundTrigger]

    init() {
        items = []
        items.reserveCapacity(Self.capacity)
    }

    /// Appends, dropping the note when the audio thread has fallen behind
    /// (it never should: it drains every buffer).
    mutating func push(_ trigger: KeySoundTrigger) {
        guard items.count < Self.capacity else { return }
        items.append(trigger)
    }

    mutating func removeAll() {
        items.removeAll(keepingCapacity: true)
    }
}

// MARK: - The mixer

/// Plays notes from the instruments, on the audio thread.
///
/// Up to `maxVoices` notes at once (fast typing overlaps a few), the oldest
/// cut off when a new one needs its place. Each voice reads its instrument at
/// its own rate with linear interpolation. Nothing allocates while rendering:
/// the voice slots are a fixed array made at init.
///
/// `@unchecked Sendable` because the render block captures it: after `init`
/// it is touched only by `render`, which Core Audio calls serially on its
/// render thread (and by tests, from one thread). The instruments are
/// immutable.
final class KeySoundMixer: @unchecked Sendable {
    static let maxVoices = 8
    /// Overall level: key sounds sit well under anything the user listens to.
    static let masterGain: Float = 0.32

    let sampleRate: Double
    private let instruments: [[Float]]

    private struct Voice {
        var instrument = 0
        var position: Float = 0
        var rate: Float = 1
        var gain: Float = 0
        /// Frames left before the note starts.
        var wait = 0
        var isActive = false
        var age = 0
    }

    private var voices = [Voice](repeating: Voice(), count: maxVoices)
    private var clock = 0

    init(instruments: [[Float]], sampleRate: Double) {
        self.instruments = instruments
        self.sampleRate = sampleRate
    }

    /// Starts a note in a free slot, or in the oldest one.
    func start(_ trigger: KeySoundTrigger) {
        let instrument = Int(trigger.timbre)
        guard instrument < instruments.count, trigger.gain > 0, trigger.rate > 0 else { return }
        var slot = 0
        var oldest = Int.max
        for index in voices.indices {
            if !voices[index].isActive {
                slot = index
                break
            }
            if voices[index].age < oldest {
                oldest = voices[index].age
                slot = index
            }
        }
        clock &+= 1
        voices[slot] = Voice(
            instrument: instrument, position: 0, rate: trigger.rate, gain: trigger.gain,
            wait: max(Int(Double(trigger.delay) * sampleRate), 0), isActive: true, age: clock
        )
    }

    /// Takes whatever notes are waiting, if the lock is free right now.
    func drain(_ queue: OSAllocatedUnfairLock<KeySoundQueue>) {
        queue.withLockIfAvailable { pending in
            for trigger in pending.items { start(trigger) }
            pending.removeAll()
        }
    }

    /// Mixes `frames` frames into `output`. Returns whether anything sounded
    /// (the render block reports silence otherwise).
    @discardableResult
    func render(frames: Int, into output: UnsafeMutablePointer<Float>) -> Bool {
        output.update(repeating: 0, count: frames)
        var sounded = false
        for index in voices.indices where voices[index].isActive {
            sounded = true
            var voice = voices[index]
            let samples = instruments[voice.instrument]
            let last = Float(samples.count - 1)
            let gain = voice.gain * Self.masterGain
            samples.withUnsafeBufferPointer { source in
                var frame = 0
                if voice.wait > 0 {
                    let skip = min(voice.wait, frames)
                    voice.wait -= skip
                    frame = skip
                }
                while frame < frames, voice.position < last {
                    let base = Int(voice.position)
                    let fraction = voice.position - Float(base)
                    let value = source[base] + (source[base + 1] - source[base]) * fraction
                    output[frame] += value * gain
                    voice.position += voice.rate
                    frame += 1
                }
            }
            if voice.wait == 0, voice.position >= last { voice.isActive = false }
            voices[index] = voice
        }
        if sounded {
            // A gentle limiter for the rare pile-up of loud notes.
            for frame in 0 ..< frames {
                let value = output[frame]
                output[frame] = value / (1 + abs(value) * 0.5)
            }
        }
        return sounded
    }

    /// Notes currently sounding or waiting to (for tests).
    var activeVoiceCount: Int { voices.reduce(0) { $0 + ($1.isActive ? 1 : 0) } }
}

// MARK: - The engine

/// Owns the audio graph: an `AVAudioEngine` with one source node whose render
/// block runs the mixer. An actor, so the graph is built, started and stopped
/// off the main thread — starting an engine takes tens of milliseconds and
/// must never land on a touch.
actor KeySoundHost {
    private var engine: AVAudioEngine?

    /// Builds the instruments for the output's rate and starts the graph.
    /// Returns whether it is running.
    func start(queue: OSAllocatedUnfairLock<KeySoundQueue>) -> Bool {
        if let engine, engine.isRunning { return true }
        #if os(iOS)
        // Ambient: mixes with whatever plays, never interrupts it, and
        // follows the ring/silent switch like the system's own key clicks.
        // A short IO buffer keeps a click within a few milliseconds of its
        // touch.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
        } catch {
            return false
        }
        #endif
        let engine = AVAudioEngine()
        let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = outputRate > 0 ? outputRate : 48000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return false }
        let mixer = KeySoundMixer(instruments: KeySoundSynth.renderAll(sampleRate: sampleRate), sampleRate: sampleRate)
        let source = AVAudioSourceNode(format: format) { @Sendable isSilence, _, frameCount, bufferList in
            mixer.drain(queue)
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard let channel = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let sounded = mixer.render(frames: Int(frameCount), into: channel)
            isSilence.pointee = ObjCBool(!sounded)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            return false
        }
        self.engine = engine
        return true
    }

    func stop() {
        engine?.stop()
        engine = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }
}

/// The key sounds of the keyboard: main-actor, synchronous, allocation-free
/// to play.
///
/// `play` turns a stroke's hits into notes and appends them to the queue the
/// audio thread drains — a lock held for an append, nothing else. Starting
/// and stopping the audio graph happen in `KeySoundHost`, off the main thread,
/// when the keyboard appears (`prepare`) and goes away (`suspend`); until the
/// graph runs, `play` returns false and the caller may fall back.
///
/// **Full Access.** A keyboard extension's sandbox gives it audio output only
/// with Full Access ("Allow Full Access" in Settings); without it nothing is
/// started (`isAccessGranted`). The host app always may.
@MainActor
final class KeySoundEngine {
    static let shared = KeySoundEngine()

    enum State: Equatable { case idle, starting, running, unavailable }

    private(set) var state = State.idle
    /// Whether the keyboard has Full Access (set by the controller).
    var isAccessGranted = true
    let queue = OSAllocatedUnfairLock(initialState: KeySoundQueue())
    private let host: KeySoundHost?
    /// Bumped by `suspend`, so a start that finishes after it is undone.
    private var generation = 0

    /// - Parameter host: nil in processes that must never make a sound (the
    ///   unit-test runner), where the engine stays unavailable.
    init(host: KeySoundHost? = UnitTestHost.isActive ? nil : KeySoundHost()) {
        self.host = host
        if host == nil { state = .unavailable }
    }

    /// Starts the audio graph in the background, if it is not running.
    func prepare() {
        guard state == .idle, isAccessGranted, let host else { return }
        state = .starting
        let queue = queue
        let started = generation
        Task { @MainActor [weak self] in
            let isRunning = await host.start(queue: queue)
            guard let self else { return }
            guard started == generation else {
                // Suspended while starting: undo.
                await host.stop()
                return
            }
            state = isRunning ? .running : .unavailable
        }
    }

    /// Starts the audio graph and waits for it (the settings screen's
    /// preview, never the keyboard's touch path). Returns whether it runs.
    func start() async -> Bool {
        if state == .running { return true }
        guard isAccessGranted, let host else { return false }
        state = .starting
        let started = generation
        let isRunning = await host.start(queue: queue)
        guard started == generation else { return false }
        state = isRunning ? .running : .unavailable
        return isRunning
    }

    /// Stops the audio graph while the keyboard is off screen.
    func suspend() {
        generation &+= 1
        guard state == .running || state == .starting, let host else { return }
        state = .idle
        queue.withLock { $0.removeAll() }
        Task { await host.stop() }
    }

    /// Plays `stroke` at `gain` (1: a touch-down's level). Returns false when
    /// the graph is not running (then it asks for it to start).
    @discardableResult
    func play(_ stroke: FeelStroke, gain: Float = 1) -> Bool {
        guard state == .running else {
            prepare()
            return false
        }
        let level = gain * stroke.soundGain
        guard level > 0 else { return true }
        queue.withLock { pending in
            stroke.forEach { hit in
                pending.push(KeySoundTrigger(
                    timbre: UInt8(hit.timbre.rawValue),
                    rate: hit.rate,
                    gain: hit.weight * hit.timbre.loudness * level,
                    delay: hit.delay
                ))
            }
        }
        return true
    }

    /// Treats the graph as running without one, so `play` queues notes —
    /// for the bench, which measures the main-thread side alone.
    func markRunningForMeasurement() {
        state = .running
    }

    /// Notes waiting for the audio thread (for tests and the bench).
    var pendingCount: Int { queue.withLock { $0.items.count } }

    func drainForMeasurement() {
        queue.withLock { $0.removeAll() }
    }
}
