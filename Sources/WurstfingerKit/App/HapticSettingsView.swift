import SwiftUI

struct HapticSettingsView: View {
    @AppStorage(SettingsKey.hapticIntensityTap.rawValue, store: SharedDefaults.store)
    private var tapIntensity = Double(HapticSettings.defaultTapIntensity)

    @AppStorage(SettingsKey.hapticIntensityDrag.rawValue, store: SharedDefaults.store)
    private var dragIntensity = Double(HapticSettings.defaultDragIntensity)

    @AppStorage(SettingsKey.keyboardFullAccess.rawValue, store: SharedDefaults.store)
    private var hasFullAccess = false

    @AppStorage(SettingsKey.detailedHapticsEnabled.rawValue, store: SharedDefaults.store)
    private var isDetailedEnabled = true

    /// Whether the keyboard extension has synced its Full Access status at least once.
    /// Prevents treating "unset" as "denied" on fresh installs.
    private var hasSyncedFullAccess: Bool {
        SharedDefaults.store.object(forKey: SettingsKey.keyboardFullAccess.rawValue) != nil
    }

    @AppStorage(SettingsKey.keyAspectRatio.rawValue, store: SharedDefaults.store)
    private var previewAspectRatio = DeviceLayout.defaultKeyAspectRatio

    @AppStorage(SettingsKey.keyboardWidthPoints.rawValue, store: SharedDefaults.store)
    private var previewWidth = DeviceLayout.defaultKeyboardWidth

    @AppStorage(SettingsKey.keyboardHorizontalPosition.rawValue, store: SharedDefaults.store)
    private var previewPosition = DeviceLayout.defaultKeyboardPosition

    var body: some View {
        VStack(spacing: 20) {
            // Keyboard Preview
            InteractiveKeyboardPreview(aspectRatio: $previewAspectRatio, width: $previewWidth, position: $previewPosition)
                .padding(.horizontal, 16)

            ScrollView {
                VStack(spacing: 24) {
                    if !hasSyncedFullAccess || hasFullAccess {
                        // Full Access granted or not yet synced — show full UI.
                        // No master toggle: each slider's "Off" level disables
                        // its feedback.
                        if !hasSyncedFullAccess {
                            Text("Open the keyboard once to sync Full Access status.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                        }

                        VStack(spacing: 24) {
                            hapticControl(
                                title: "Tap Feedback",
                                value: $tapIntensity,
                                description: "Applies when you touch any key.",
                                preview: .touchDown
                            )

                            hapticControl(
                                title: "Drag Feedback",
                                value: $dragIntensity,
                                description: "Applies when you drag the Space or Delete key to move the cursor or delete text.",
                                preview: .cursorTick(.deliberate)
                            )

                            VStack(alignment: .leading, spacing: 8) {
                                Toggle("Detailed Haptics", isOn: $isDetailedEnabled)
                                    .font(.headline)
                                Text(
                                    // swiftlint:disable:next line_length
                                    "A distinct feel for each gesture: ticks as a swipe passes each direction, a click on release, a swell before a long press. Turn off for simple clicks."
                                )
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 16)
                        }
                    } else {
                        // Full Access explicitly denied
                        VStack(spacing: 12) {
                            Label {
                                Text(
                                    // swiftlint:disable:next line_length
                                    "Haptic feedback requires Full Access. Enable it in **Settings › Wurstfinger › Keyboards › Wurstfinger › Allow Full Access**."
                                )
                                .font(.caption)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .padding(.vertical, 20)
        .navigationTitle("Haptics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !hasSyncedFullAccess || hasFullAccess {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Reset") {
                        tapIntensity = Double(HapticSettings.defaultTapIntensity)
                        dragIntensity = Double(HapticSettings.defaultDragIntensity)
                        isDetailedEnabled = true
                    }
                }
            }
        }
    }

    /// The keyboard can only produce the pulses in `HapticIntensityLevel`,
    /// so the slider snaps to those levels instead of offering a continuous
    /// range that mostly changes nothing.
    private func hapticControl(
        title: LocalizedStringKey,
        value: Binding<Double>,
        description: LocalizedStringKey,
        preview: HapticCue
    ) -> some View {
        VStack(spacing: 16) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text(HapticIntensityLevel(storedIntensity: value.wrappedValue).displayName)
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 8) {
                HapticLevelSlider(
                    levelIndex: levelIndexBinding(for: value, preview: preview),
                    levelCount: HapticIntensityLevel.allCases.count
                )
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(HapticIntensityLevel(storedIntensity: value.wrappedValue).displayName))

                HStack {
                    Text("Off")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("Max")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
    }

    /// Bridges the stored 0...1 intensity to a discrete level index. Writing
    /// stores the level's canonical intensity, so legacy in-between values
    /// snap to a level the moment the slider is touched.
    ///
    /// Each snap onto a new level plays that level's pulse, so every level
    /// can be felt while sliding across the detents (off stays silent).
    private func levelIndexBinding(for value: Binding<Double>, preview: HapticCue) -> Binding<Int> {
        Binding(
            get: { HapticIntensityLevel(storedIntensity: value.wrappedValue).rawValue },
            set: { index in
                let level = HapticIntensityLevel(rawValue: index) ?? .off
                let previous = HapticIntensityLevel(storedIntensity: value.wrappedValue)
                value.wrappedValue = Double(level.storedIntensity)
                if level != previous {
                    HapticPreview.play(preview)
                }
            }
        )
    }
}

/// Plays, from the settings screen, exactly what the keyboard plays for a
/// cue at the stored settings: the Core Haptics pattern when Detailed Haptics
/// is on, the generator pulse otherwise. One player for the screen's
/// lifetime, re-read from the store before each preview (the sliders write
/// it through `@AppStorage`).
@MainActor
enum HapticPreview {
    private static let settings = HapticSettings(defaults: SharedDefaults.store, shouldPersist: false)
    private static let player = HapticFeedbackPlayer(settings: settings)

    static func play(_ cue: HapticCue) {
        settings.reload()
        player.refreshIfSettingsChanged()
        player.prepareIfNeeded()
        player.play(cue)
    }
}

extension HapticIntensityLevel {
    /// User-facing level name. Lives in the host app target: the extension's
    /// own catalog carries only the strings the keyboard itself displays, so a
    /// settings-only name must not be looked up from extension code.
    var displayName: String {
        switch self {
        case .off: String(localized: "Off")
        case .tick: String(localized: "Minimal")
        case .soft: String(localized: "Soft")
        case .light: String(localized: "Light")
        case .medium: String(localized: "Medium")
        case .heavy: String(localized: "Strong")
        }
    }
}

/// Discrete slider with one detent per haptic level.
///
/// Custom instead of SwiftUI's `Slider` because the system control plays its
/// own (non-suppressible) haptic when the thumb hits the range bounds — which
/// made even the "Off" end vibrate. Here the only feedback is the level-snap
/// pulse played by the binding.
private struct HapticLevelSlider: View {
    @Binding var levelIndex: Int
    let levelCount: Int

    private let thumbDiameter: CGFloat = 27
    private let tickDiameter: CGFloat = 6
    private let trackHeight: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            let stepWidth = (geometry.size.width - thumbDiameter) / CGFloat(levelCount - 1)
            let thumbOffset = stepWidth * CGFloat(levelIndex)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.systemFill))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: thumbOffset + thumbDiameter / 2, height: trackHeight)

                ForEach(0 ..< levelCount, id: \.self) { index in
                    Circle()
                        .fill(Color(.systemGray3))
                        .frame(width: tickDiameter, height: tickDiameter)
                        .offset(x: thumbDiameter / 2 + stepWidth * CGFloat(index) - tickDiameter / 2)
                }

                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .offset(x: thumbOffset)
            }
            .frame(maxHeight: .infinity)
            .animation(.snappy(duration: 0.15), value: levelIndex)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let position = (gesture.location.x - thumbDiameter / 2) / stepWidth
                        let index = min(max(Int(position.rounded()), 0), levelCount - 1)
                        if index != levelIndex {
                            levelIndex = index
                        }
                    }
            )
        }
        .frame(height: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                levelIndex = min(levelIndex + 1, levelCount - 1)
            case .decrement:
                levelIndex = max(levelIndex - 1, 0)
            @unknown default:
                break
            }
        }
    }
}
