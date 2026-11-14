//
//  KeyboardShot.swift
//  WurstfingerSnapshots
//
//  Turns a description of a keyboard on a screen — language, mode, device,
//  settings, a finger mid-gesture — into a view of the real keyboard.
//

import SwiftUI
@testable import WurstfingerKit
@testable import WurstfingerScenarioKit

/// What sits behind the keyboard.
enum Backdrop {
    /// The system background of the appearance.
    case plain
    /// Saturated colour, for the translucent liquid-glass keys to show against.
    case colorful
}

/// A finger on the keyboard, drawn through the real trail code.
struct FingerTrail {
    enum Motion {
        /// Dragged from the key's centre toward a direction by this many key
        /// widths, finger still down.
        case drag(GestureType, keyWidths: CGFloat)
        /// A loop drawn on the key, `fraction` of the way round.
        case circle(clockwise: Bool, fraction: CGFloat)
        /// Out toward a direction and part of the way back.
        case returnSwipe(GestureType, keyWidths: CGFloat)
        /// A press that has not moved.
        case press
    }

    var keyId: String
    var motion: Motion
    /// The finger has rested long enough for the guide card to reveal the
    /// key's whole map.
    var paused = false
    /// Long swipes are on, so the trail turns the accent colour while a
    /// release would fire one (`LongSwipeConfiguration.isArmed`).
    var longSwipes = false
}

/// Everything that distinguishes one keyboard picture from another.
struct KeyboardSpec {
    var language = "en_US"
    var mode = ModeNames.main
    var device = Device.iPhone15
    var scheme: ColorScheme = .light
    var style: KeyboardStyle = .classic
    var utilityColumnLeading = false
    var keyAspectRatio: Double?
    /// Keyboard width wish in points; nil keeps the device-class default.
    var widthWish: Double?
    var hideLetters = false
    var hideStandardSymbols = false
    var hideExtraSymbols = false
    var longPressDigits = false
    /// Keys drawn pressed.
    var pressedKeys: Set<String> = []
    var finger: FingerTrail?
    var backdrop = Backdrop.plain
    /// Typed by gesture before the picture is taken, and shown in a text-field
    /// box above the keyboard.
    var typedText: String?
    /// Languages enabled in settings. More than one makes the globe key show
    /// the active language's label.
    var enabledLanguages: [String]?
    /// Custom layouts registered for the picture, so `language` can name one.
    var customLayouts: [CustomLayout] = []
}

@MainActor
enum KeyboardShot {
    /// Builds the view for `spec`.
    static func make(_ spec: KeyboardSpec) -> Shot {
        ScenarioEnvironment.reset()
        let store = SharedDefaults.store
        store.set(spec.style.rawValue, forKey: SettingsKey.keyboardStyle.rawValue)
        store.set(spec.hideLetters, forKey: SettingsKey.areLetterLabelsHidden.rawValue)
        store.set(spec.hideStandardSymbols, forKey: SettingsKey.areStandardSymbolLabelsHidden.rawValue)
        store.set(spec.hideExtraSymbols, forKey: SettingsKey.areExtraSymbolLabelsHidden.rawValue)
        store.set(spec.longPressDigits, forKey: SettingsKey.isLongPressDigitEnabled.rawValue)

        if !spec.customLayouts.isEmpty {
            KeyboardRegistry.replaceCustomLayouts(spec.customLayouts, revision: "snapshot")
        }
        spec.device.activate()
        var settings: [SettingsKey: Any] = [:]
        if let enabled = spec.enabledLanguages { settings[.enabledLanguageIds] = enabled }
        // A finger on the keyboard draws its trail, as with the setting on.
        if spec.finger != nil { settings[.gestureTrailEnabled] = true }
        if spec.finger?.longSwipes == true {
            settings[.expertModeEnabled] = true
            settings[.isLongSwipeEnabled] = true
        }
        let scenario = KeyboardScenario(
            language: spec.language,
            containerWidth: spec.device.width,
            autoCapitalize: spec.typedText != nil,
            settings: settings
        )
        let viewModel = scenario.viewModel
        viewModel.utilityColumnLeading = spec.utilityColumnLeading
        if let ratio = spec.keyAspectRatio { viewModel.keyAspectRatio = ratio }
        if let width = spec.widthWish { viewModel.keyboardWidth = width }

        if let typed = spec.typedText { scenario.type(typed) }
        viewModel.switchToMode(spec.mode)

        guard let layout = KeyboardGeometry.layout(of: viewModel, containerWidth: spec.device.width) else {
            return Shot(size: .zero, content: AnyView(EmptyView()))
        }

        let keepAlive: [AnyObject] = [scenario]
        // A finger goes through the view model's real input engine — pressed
        // key, emphasized hint, guide card and trail all come from it.
        if let finger = spec.finger {
            TrailDrawing.touch(finger, on: scenario)
        }
        let keyboard = DataDrivenKeyboardRootView(viewModel: viewModel, overrideWidth: spec.device.width)
            .frame(width: spec.device.width, height: layout.keyboardHeight)
            .environment(\.forcedActiveKeyIds, spec.pressedKeys)
            // No native views in a headless render; the engine is fed above.
            .environment(\.isTouchSurfaceEnabled, false)
            .environment(\.touchGuideReveal, spec.finger?.paused == true ? .immediately : .never)

        let fieldHeight: CGFloat = spec.typedText == nil ? 0 : 96
        let width = spec.device.width
        let height = layout.keyboardHeight + fieldHeight

        let content = ZStack(alignment: .bottom) {
            switch spec.backdrop {
            case .plain:
                Color.clear
            case .colorful:
                LinearGradient(
                    colors: [.pink, .orange, .yellow, .green, .blue, .purple],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
            VStack(spacing: 0) {
                if spec.typedText != nil {
                    TypedTextBox(before: scenario.target.before, after: scenario.target.after)
                        .frame(width: width, height: fieldHeight)
                }
                keyboard
            }
        }
        return Shot(
            size: CGSize(width: width, height: height),
            scheme: spec.scheme,
            content: AnyView(content),
            keepAlive: keepAlive
        )
    }
}

/// The document a typing scenario wrote into, drawn as the text field of a
/// notes app with the caret where the cursor is.
private struct TypedTextBox: View {
    let before: String
    let after: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            (Text(before) + Text("|").foregroundColor(.accentColor) + Text(after))
                .font(.system(size: 24, weight: .regular))
                .lineLimit(2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(16)
            Divider()
        }
        .background(Color(.systemBackground))
    }
}

/// Puts a finger on the keyboard through the view model's real `TouchEngine`:
/// down on the key, then along the path, and not lifted.
@MainActor
enum TrailDrawing {
    static func touch(_ finger: FingerTrail, on scenario: KeyboardScenario) {
        let viewModel = scenario.viewModel
        viewModel.configureTouchEngine(
            containerWidth: scenario.containerWidth,
            isLongPressEnabled: scenario.defaults.bool(forKey: SettingsKey.isLongPressDigitEnabled.rawValue)
        )
        let engine = viewModel.touchEngine
        guard let frame = engine.hitMap.key(withId: finger.keyId)?.frame else { return }
        let origin = CGPoint(x: frame.midX, y: frame.midY)
        var synthesizer = TouchSynthesizer(keySize: frame.size, jitter: 0.4, seed: 11)

        let path: TouchPath
        switch finger.motion {
        case let .drag(gesture, keyWidths):
            let length = keyWidths * frame.width
            let unit = unitVector(gesture, in: frame.size)
            path = synthesizer.drag(by: CGSize(width: unit.x * length, height: unit.y * length), speed: 350)
        case let .circle(clockwise, fraction):
            let full = synthesizer.circle(clockwise: clockwise)
            let count = max(Int(Double(full.samples.count) * Double(fraction)), 2)
            path = TouchPath(samples: Array(full.samples.prefix(count)))
        case let .returnSwipe(gesture, keyWidths):
            let length = keyWidths * frame.width
            let full = synthesizer.returnSwipe(gesture)
            // Rescale the unit swipe to the requested length and stop on the
            // way back.
            let scale = length / max(full.maxDisplacement, 1)
            let count = Int(Double(full.samples.count) * 0.78)
            path = TouchPath(samples: full.samples.prefix(count).map {
                CGPoint(x: $0.x * scale, y: $0.y * scale)
            })
        case .press:
            path = synthesizer.hold(duration: 0.1)
        }

        let points = path.offset(by: origin)
        let start = ProcessInfo.processInfo.systemUptime
        engine.began(1, at: points[0], time: start)
        for (index, point) in points.dropFirst().enumerated() {
            engine.moved(1, samples: [TouchSample(location: point, time: start + Double(index + 1) / TouchPath.sampleRate)])
        }
    }

    private static func unitVector(_ gesture: GestureType, in size: CGSize) -> CGPoint {
        let (sx, sy): (CGFloat, CGFloat)
        switch gesture {
        case .swipeUp: (sx, sy) = (0, -1)
        case .swipeDown: (sx, sy) = (0, 1)
        case .swipeLeft: (sx, sy) = (-1, 0)
        case .swipeRight: (sx, sy) = (1, 0)
        case .swipeUpLeft: (sx, sy) = (-1, -1)
        case .swipeUpRight: (sx, sy) = (1, -1)
        case .swipeDownLeft: (sx, sy) = (-1, 1)
        case .swipeDownRight: (sx, sy) = (1, 1)
        default: (sx, sy) = (0, 0)
        }
        let raw = CGPoint(x: sx * size.width, y: sy * size.height)
        let magnitude = hypot(raw.x, raw.y)
        return magnitude > 0 ? CGPoint(x: raw.x / magnitude, y: raw.y / magnitude) : .zero
    }
}

/// Resets what a scenario can leave behind between pictures.
@MainActor
enum ScenarioEnvironment {
    /// Empties the throwaway defaults suite and puts the simulated device back.
    static func reset() {
        let name = SharedDefaults.resolvedSuiteName(arguments: ProcessInfo.processInfo.arguments)
        precondition(
            SharedDefaults.isWipeableSuite(name),
            "refusing to wipe '\(name)': the tool must run against the isolated defaults suite"
        )
        SharedDefaults.store.removePersistentDomain(forName: name)
        // The custom layouts a previous picture installed: files, library and registry.
        try? FileManager.default.removeItem(at: CustomLayoutStore.shared.directory)
        KeyboardRegistry.replaceCustomLayouts([], revision: nil)
        CustomLayoutLibrary.shared.reload()
        LanguageSettings.shared.reloadFromStore()
        Device.iPhone15.activate()
    }
}
