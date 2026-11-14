//
//  HapticFeedbackPlayer.swift
//  Wurstfinger
//
//  Extracted from KeyboardViewModel to improve separation of concerns.
//  Handles all haptic feedback generation for the keyboard.
//

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The physical pulse emitted for a haptic event.
///
/// `UIImpactFeedbackGenerator.impactOccurred(intensity:)` requires
/// CHHapticEngine, which cannot initialize in the sandboxed keyboard
/// extension process, so continuous intensity is unavailable. To still give
/// the intensity slider a wide perceived range, the scale starts with a
/// barely-noticeable `UISelectionFeedbackGenerator` tick and then steps
/// through impact styles up to `.heavy`.
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

/// Plays haptic feedback for keyboard events.
///
/// Requires Full Access to be enabled — without it, `UIFeedbackGenerator` silently
/// fails because the underlying `CHHapticEngine` is blocked by the keyboard sandbox.
/// The host app settings UI prevents enabling haptics when Full Access is not granted.
///
/// **Main-actor only.** UIKit's feedback generators are `@MainActor`, and every
/// caller is already on the main actor (touch-down handlers, the action
/// pipeline), so there is no thread hop to make: the pulse is issued in the
/// same synchronous call that received the touch. (This type used to bounce
/// off-main callers through `DispatchQueue.main.async`; with the isolation
/// stated in the type system no such caller can exist.)
@MainActor
final class HapticFeedbackPlayer {
    private let settings: HapticSettings

    /// Cached generators per feedback style to avoid per-event allocation
    private lazy var impactGenerators: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = {
        var gens = [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator]()
        for style in [UIImpactFeedbackGenerator.FeedbackStyle.soft, .light, .medium, .heavy] {
            gens[style] = UIImpactFeedbackGenerator(style: style)
        }
        return gens
    }()

    /// Detent-style ticks for drag steps, state changes, and the lowest
    /// intensity level.
    private lazy var selectionGenerator = UISelectionFeedbackGenerator()

    /// When the generators were last told to `prepare()`. The Taptic Engine
    /// stays warm for only a couple of seconds after a prepare, so a keyboard
    /// that has been idle fires its next impact through a cold engine — the
    /// perceptible lag on the first keystroke after a pause.
    private var lastPrepared: ContinuousClock.Instant?

    /// How long a prepare is trusted to still be warm. Apple documents "a
    /// short time" without a figure; the engine idles down after roughly two
    /// seconds, so re-preparing slightly before that keeps it hot at the cost
    /// of one cheap call per touch-down after a pause.
    private static let warmWindow: Duration = .seconds(1.5)

    init(settings: HapticSettings) {
        self.settings = settings
    }

    // MARK: - Public API

    /// Warms the generators the next touch will use, if they have gone cold.
    ///
    /// Called on touch-down *before* the tap pulse and again when the keyboard
    /// appears: preparing at the moment of the first touch of a burst means
    /// the engine is already spun up for the drag ticks and for every
    /// following key, instead of each pulse paying the ramp. A no-op while the
    /// last prepare is still inside `warmWindow`, and when haptics are off.
    func prepareIfNeeded() {
        guard settings.tapIntensity > 0 || settings.dragIntensity > 0 else { return }
        let now = ContinuousClock.now
        if let lastPrepared, now - lastPrepared < Self.warmWindow { return }
        lastPrepared = now
        // Only the generators this user's settings can actually fire: the tap
        // and drag pulses, plus the selection tick that state changes (which
        // follow the tap intensity) use. Preparing the unused styles would
        // keep the engine busier for nothing.
        if settings.tapIntensity > 0 {
            prepare(.pulse(for: settings.tapIntensity))
            selectionGenerator.prepare()
        }
        if settings.dragIntensity > 0 {
            prepare(.pulse(for: settings.dragIntensity))
        }
    }

    private func prepare(_ pulse: HapticPulse) {
        switch pulse {
        case .selectionTick:
            selectionGenerator.prepare()
        case let .impact(style):
            impactGenerators[style]?.prepare()
        }
    }

    /// Triggers haptic feedback for a key tap (touch-down)
    func tap() {
        prepareIfNeeded()
        trigger(.tap)
    }

    /// Triggers haptic feedback for drag operations (cursor movement, delete drag)
    func drag() {
        trigger(.drag)
    }

    /// Triggers a confirmation tick for mode/language changes and system
    /// actions (globe, dismiss, clipboard).
    func stateChange() {
        trigger(.stateChange)
    }

    /// Triggers haptic feedback for the specified event type
    func trigger(_ event: KeyboardHapticEvent) {
        let intensity = settings.intensity(for: event)
        guard intensity > 0 else { return }

        let pulse: HapticPulse = switch event {
        case .tap, .drag: .pulse(for: intensity)
        // State changes always use the light detent tick —
        // `UISelectionFeedbackGenerator` is made for exactly this.
        case .stateChange: .selectionTick
        }

        switch pulse {
        case .selectionTick:
            selectionGenerator.selectionChanged()
            selectionGenerator.prepare()
        case let .impact(style):
            guard let generator = impactGenerators[style] else { return }
            generator.impactOccurred()
            // Keep the Taptic Engine warm so the next keystroke fires
            // without ramp-up latency.
            generator.prepare()
        }
        lastPrepared = ContinuousClock.now
    }
}
