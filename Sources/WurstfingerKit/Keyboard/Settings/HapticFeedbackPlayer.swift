//
//  HapticFeedbackPlayer.swift
//  Wurstfinger
//
//  Extracted from KeyboardViewModel to improve separation of concerns.
//  Handles all haptic feedback generation for the keyboard.
//

import Observation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The physical pulse emitted for a haptic event.
///
/// This is the *fallback* ladder, used when Core Haptics cannot play (see
/// `HapticFeedbackPlayer`). `UIImpactFeedbackGenerator.impactOccurred(intensity:)`
/// is not used: it is backed by the same CHHapticEngine, which has been
/// observed failing to initialize in the sandboxed keyboard extension process —
/// exactly the case the fallback exists for. To still give the intensity
/// slider a wide perceived range, the scale starts with a barely-noticeable
/// `UISelectionFeedbackGenerator` tick and then steps through impact styles up
/// to `.heavy`.
enum HapticPulse: Equatable, Sendable {
    /// `UISelectionFeedbackGenerator` tick — the subtlest available feedback.
    case selectionTick
    case impact(UIImpactFeedbackGenerator.FeedbackStyle)

    /// Maps a 0...1 intensity to a pulse (0 is handled upstream as "off").
    static func pulse(for intensity: CGFloat) -> HapticPulse {
        switch intensity {
        case ..<0.2: .selectionTick
        case ..<0.4: .impact(.soft)
        case ..<0.6: .impact(.light)
        case ..<0.8: .impact(.medium)
        default: .impact(.heavy)
        }
    }
}

/// The discrete, user-facing intensity levels — one per producible pulse,
/// plus off. The settings UI offers exactly these instead of a continuous
/// range, because intermediate values cannot change the physical feedback.
///
/// Stored settings remain a 0...1 intensity for backward compatibility;
/// levels map to their bucket's midpoint in `HapticPulse.pulse(for:)`.
enum HapticIntensityLevel: Int, CaseIterable, Equatable, Sendable {
    case off = 0, tick, soft, light, medium, heavy

    /// Canonical stored intensity (midpoint of the corresponding pulse bucket).
    var storedIntensity: CGFloat {
        switch self {
        case .off: 0
        case .tick: 0.1
        case .soft: 0.3
        case .light: 0.5
        case .medium: 0.7
        case .heavy: 0.9
        }
    }

    /// Derives the level from a stored intensity via the pulse mapping, so
    /// the two can never drift apart.
    init(storedIntensity: CGFloat) {
        guard storedIntensity > 0 else {
            self = .off
            return
        }
        self = switch HapticPulse.pulse(for: storedIntensity) {
        case .selectionTick: .tick
        case .impact(.soft): .soft
        case .impact(.light): .light
        case .impact(.medium): .medium
        case .impact: .heavy
        }
    }
}

/// Plays the keyboard's haptic vocabulary (`HapticCue`, `HapticPatterns.swift`).
///
/// **Two renderers.** Core Haptics (`CoreHapticsRenderer`) plays the designed
/// patterns — a distinct transient per commit kind, direction detents, the
/// long-press swell. When it is unavailable (no Taptic Engine, the engine
/// could not start in this process, "Detailed Haptics" is off, or it is still
/// starting) each cue falls back to a UIKit generator pulse
/// (`HapticCue.fallbackPulse`), which is the keyboard's original feel.
///
/// **Strength.** The two user sliders stay meaningful: each cue follows one
/// of them (`HapticCue.channel`), Off silences it, and the other levels scale
/// the designed intensities (`HapticGain`). The scaled patterns are baked into
/// the players when they are built — ahead of time, when the keyboard appears
/// or a slider moves — so playing a cue is a single `start` call.
///
/// Requires Full Access in the keyboard extension; without it neither Core
/// Haptics nor the generators reach the Taptic Engine, so nothing is started
/// at all (`isAccessGranted`). The host app's settings UI explains this.
///
/// **Main-actor only.** Every caller is already on the main actor (the input
/// engine's touch handlers, the action pipeline), so there is no thread hop to
/// make: the cue is issued in the same synchronous call that received the
/// touch.
@MainActor
final class HapticFeedbackPlayer {
    private let settings: HapticSettings
    /// Core Haptics, or nil where it is not wanted at all (it is still tried
    /// on macOS, where the hardware reports no support).
    private let detailed: HapticRenderer?
    private let pulses: any PulseRenderer

    /// Whether the keyboard has Full Access. Set by the controller; true in
    /// the host app and in tests.
    var isAccessGranted = true {
        didSet {
            guard isAccessGranted != oldValue else { return }
            refreshIfSettingsChanged()
        }
    }

    /// What the detailed renderer was last prepared with.
    private var prepared: PreparedState?

    /// When the generators were last told to `prepare()`. The Taptic Engine
    /// stays warm for only a couple of seconds after a prepare, so a keyboard
    /// that has been idle fires its next generator impact through a cold
    /// engine — the perceptible lag on the first keystroke after a pause.
    private var lastPrepared: ContinuousClock.Instant?

    /// How long a generator prepare is trusted to still be warm. Apple
    /// documents "a short time" without a figure; the engine idles down after
    /// roughly two seconds, so re-preparing slightly before that keeps it hot
    /// at the cost of one cheap call per touch-down after a pause.
    private static let warmWindow: Duration = .seconds(1.5)

    init(
        settings: HapticSettings,
        detailed: HapticRenderer? = CoreHapticsRenderer(),
        pulses: (any PulseRenderer)? = nil
    ) {
        self.settings = settings
        self.detailed = detailed
        self.pulses = pulses ?? GeneratorRenderer()
        observeSettings()
    }

    // MARK: - Playing

    /// Plays `cue` now (or `delay` seconds from now, Core Haptics only), at
    /// the strength of its channel's slider. Silent when that slider is Off.
    func play(_ cue: HapticCue, after delay: TimeInterval = 0) {
        guard isAccessGranted else { return }
        let intensity = settings.intensity(for: cue.channel)
        guard intensity > 0 else { return }
        if isDetailedActive, let detailed, detailed.isReady, detailed.play(cue, after: delay) {
            return
        }
        // The generators cannot schedule; a delayed cue (the long-press
        // swell) simply has no fallback.
        guard delay == 0, let pulse = cue.fallbackPulse(intensity: intensity) else { return }
        pulses.play(pulse)
        lastPrepared = ContinuousClock.now
    }

    /// Plays a derived stroke (`FeelVoiceModel`) for the moment `cue` names:
    /// each hit as a click from Core Haptics' bank, at the strength of the
    /// cue's channel. Where the bank cannot play, the cue's designed pattern
    /// plays instead, and without Core Haptics its generator pulse — so a
    /// derived moment is never silent where the plain one would not be.
    ///
    /// Allocation-free: the stroke has fixed storage and is walked with a
    /// non-escaping closure; each hit is one `start` on a prebuilt player.
    func play(_ stroke: FeelStroke, as cue: HapticCue) {
        guard isAccessGranted else { return }
        let intensity = settings.intensity(for: cue.channel)
        guard intensity > 0 else { return }
        if isDetailedActive, let detailed, detailed.isReady {
            let gain = HapticGain.gain(for: intensity)
            let shift = HapticGain.sharpnessShift(for: intensity)
            var played = false
            stroke.forEach { hit in
                let isPlayed = detailed.playClick(
                    intensity: hit.intensity * gain,
                    sharpness: hit.sharpness + shift,
                    after: TimeInterval(hit.delay)
                )
                played = played || isPlayed
            }
            if played { return }
        }
        play(cue)
    }

    /// Stops a playing or scheduled cue (the long-press swell when the finger
    /// moves or lifts first).
    func stop(_ cue: HapticCue) {
        detailed?.stop(cue)
    }

    /// Whether the patterns play through Core Haptics right now.
    var isDetailedActive: Bool {
        settings.isDetailedEnabled && detailed != nil
    }

    // MARK: - Warming

    /// Gets the hardware ready for the next touch: starts Core Haptics and
    /// builds its players when the keyboard appears (a no-op once they match
    /// the current settings), and warms the generators that would cover for
    /// it if they have gone cold.
    ///
    /// Called when the keyboard appears and again on touch-down. Never builds
    /// players on a touch once they exist: a settings change rebuilds them
    /// when it arrives (`observeSettings`).
    func prepareIfNeeded() {
        guard isAccessGranted, settings.tapIntensity > 0 || settings.dragIntensity > 0 else { return }
        if prepared == nil { refreshIfSettingsChanged() }
        if isDetailedActive {
            if detailed?.isReady == true { return }
            // Wanted but not running (a start failed, or the system stopped
            // the engine while the app was suspended): a state check, and an
            // asynchronous start only when there is something to start.
            detailed?.resumeIfNeeded()
        }
        let now = ContinuousClock.now
        if let lastPrepared, now - lastPrepared < Self.warmWindow { return }
        lastPrepared = now
        // Only the pulses this user's settings can actually fire: the tap and
        // drag pulses, plus the selection tick that state changes use.
        if settings.tapIntensity > 0 {
            pulses.prepare(.pulse(for: settings.tapIntensity))
            pulses.prepare(.selectionTick)
        }
        if settings.dragIntensity > 0 {
            pulses.prepare(.pulse(for: settings.dragIntensity))
        }
    }

    /// Releases the Taptic Engine while the keyboard is off screen; the next
    /// `prepareIfNeeded` (on appearance) starts it again.
    func suspend() {
        detailed?.suspend()
        prepared = nil
    }

    /// Rebuilds the Core Haptics players when the sliders, the Detailed
    /// Haptics switch or Full Access changed since they were built.
    func refreshIfSettingsChanged() {
        let state = PreparedState(
            tap: settings.tapIntensity,
            drag: settings.dragIntensity,
            isDetailed: isDetailedActive && isAccessGranted
        )
        guard state != prepared else { return }
        prepared = state
        guard let detailed else { return }
        if state.isDetailed {
            detailed.prepare(Self.patterns(tapIntensity: state.tap, dragIntensity: state.drag))
        } else {
            detailed.suspend()
        }
    }

    /// Every cue at the user's strength; cues whose slider is Off are left
    /// out (no player is built for them).
    static func patterns(tapIntensity: CGFloat, dragIntensity: CGFloat) -> [HapticCue: HapticPatternSpec] {
        var patterns: [HapticCue: HapticPatternSpec] = [:]
        for cue in HapticCue.allCases {
            let intensity = cue.channel == .touch ? tapIntensity : dragIntensity
            let gain = HapticGain.gain(for: intensity)
            guard gain > 0 else { continue }
            patterns[cue] = HapticPatternSpec.pattern(for: cue)
                .scaled(by: gain, sharpnessShift: HapticGain.sharpnessShift(for: intensity))
        }
        return patterns
    }

    /// Re-arms itself on every change of the settings the players depend on;
    /// the rebuild runs in its own main-actor turn, never inside a touch.
    private func observeSettings() {
        withObservationTracking {
            _ = settings.tapIntensity
            _ = settings.dragIntensity
            _ = settings.isDetailedEnabled
        } onChange: { [weak self] in
            // `onChange` fires before the new value is stored; read it on the
            // next main-actor turn.
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Only once players exist: before the first appearance
                // there is nothing to rebuild yet.
                if self.prepared != nil { self.refreshIfSettingsChanged() }
                self.observeSettings()
            }
        }
    }

    // MARK: - Legacy entry points

    /// Haptic feedback for a key touch-down.
    func tap() {
        prepareIfNeeded()
        play(.touchDown)
    }

    /// One step of a slide.
    func drag() {
        play(.deleteTick)
    }

    /// A confirmation for a mode change or system action.
    func stateChange() {
        play(.modeSwitch)
    }

    /// Plays the cue for a coarse event (kept for callers that predate the
    /// vocabulary).
    func trigger(_ event: KeyboardHapticEvent) {
        switch event {
        case .tap: play(.touchDown)
        case .drag: play(.deleteTick)
        case .stateChange: play(.modeSwitch)
        }
    }

    private struct PreparedState: Equatable {
        var tap: CGFloat
        var drag: CGFloat
        var isDetailed: Bool
    }
}

/// Plays generator pulses: the UIKit feedback generators in the app, a
/// recording fake in tests.
@MainActor
protocol PulseRenderer: AnyObject {
    func prepare(_ pulse: HapticPulse)
    func play(_ pulse: HapticPulse)
}

extension GeneratorRenderer: PulseRenderer {}
