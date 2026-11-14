//
//  KeyView.swift
//  Wurstfinger
//
//  Generic key view that renders any KeyDefinition with style-based appearance
//  and full gesture recognition.
//

import SwiftUI

/// Snapshot of the user settings a key needs to render, read once in
/// `DataDrivenKeyboardRootView` and passed down by value.
///
/// The whole keyboard holds one defaults observation per setting, and the
/// ~100 key views a mode builds hold none: the root re-renders when a
/// setting changes and hands every key the fresh values.
struct KeyRenderSettings: Equatable, Sendable {
    var keyboardStyle: KeyboardStyle = .classic
    var areLetterLabelsHidden = false
    var areStandardSymbolLabelsHidden = false
    var areExtraSymbolLabelsHidden = false
    var isLongPressDigitEnabled = false
    /// Press, release and commit animations and the light effects on keys
    /// (`SettingsKey.keyAnimationsEnabled`).
    var areKeyAnimationsEnabled = true

    /// The values a key renders with when nothing is stored yet. Single source
    /// for those defaults: `DataDrivenKeyboardRootView` initializes its
    /// `@AppStorage` wrappers from it, so the snapshot a test or preview builds
    /// with `KeyRenderSettings()` cannot drift from what an untouched
    /// installation actually renders.
    static let stock = KeyRenderSettings()
}

#if DEBUG
/// Counts `KeyView.body` evaluations so the benchmark can report how many keys
/// a keystroke re-renders. Debug-only: release builds carry no counter at all.
@MainActor
enum KeyViewBodyCounter {
    static var count = 0
}
#endif

/// Generic key view that renders any `KeyDefinition`.
///
/// Visual appearance is driven by `key.style`. Hints derive directly from
/// `key.bindings`, so only the gestures actually defined on a key are shown.
///
/// A key handles no touches itself: the grid's `TouchSurface` feeds every
/// finger to the `TouchEngine`, and the key draws the engine's live state from
/// its own `KeyPressCell` — pressed, and the gesture the finger is heading for,
/// whose hint it emphasizes. Reading only its own cell is what keeps a touch
/// from re-rendering any other key.
struct KeyView: View {
    let key: KeyDefinition
    /// Performs a gesture on this key; used by the VoiceOver custom actions.
    let onGesture: (KeyDefinition, GestureType, Bool) -> Void

    /// This key's live touch state, from the grid's engine. Nil in hosts with
    /// no engine (tests), where the key is never pressed.
    var pressCell: KeyPressCell?

    /// Inset between the full touch cell and the key's visible bounds. The cell
    /// supplied by `KeyboardGridLayout` extends halfway into the gap toward each
    /// neighbour so there are no dead zones; insetting the drawn content by the
    /// same amount keeps the visible key exactly where it was. Defaults to zero.
    var visualInset: EdgeInsets = .init()

    /// Keys a headless host holds in the pressed state (see
    /// `SnapshotHooks.swift`); empty in the app, where only a touch presses.
    @Environment(\.forcedActiveKeyIds) private var forcedActiveKeyIds

    /// User settings affecting key rendering, injected by `KeyboardGridView`
    /// (ultimately read once in `DataDrivenKeyboardRootView`) — see
    /// `KeyRenderSettings`. No default, for the same reason as `metrics`: a
    /// defaulted snapshot would let a missing injection compile and silently
    /// render stock settings (labels shown, long-press numbers off) instead of
    /// failing the build.
    let settings: KeyRenderSettings

    /// Resolved layout metrics injected by `KeyboardGridView` (same reasoning
    /// as there: an `@AppStorage` read desynchronizes from the width path
    /// when the view model is configured programmatically). Feeds the gesture
    /// classification geometry and the font scaling. No default: every caller
    /// must pass the resolved metrics explicitly so a `.reference` fallback can
    /// never silently mask a wiring gap (production sites already do).
    var metrics: KeyboardLayoutMetrics

    /// The user's resolved gesture settings, passed down from the view model
    /// by `KeyboardGridView`. No default, same reasoning as `metrics`: a
    /// defaulted snapshot would let a missing injection compile and silently
    /// classify with stock thresholds instead of the user's.
    let tuning: GestureTuning

    /// Short language label (e.g. "DE") shown on the switch key, and whether to
    /// show it. Driven by the active keyboard locale via `KeyboardViewModel`
    /// (threaded through `KeyboardGridView`) rather than re-derived from shared
    /// defaults, so the hint stays correct even when startup loads a pinned
    /// language whose id differs from the stored selection.
    var languageLabel: String = ""
    var isLanguageLabelShown: Bool = false

    /// Whether the label of `binding` should be drawn, honouring the user's
    /// label-visibility toggles (numbers and functional keys always show).
    private func isLabelVisible(_ binding: KeyBinding) -> Bool {
        LabelCategory.of(binding).isVisible(
            areLetterLabelsHidden: settings.areLetterLabelsHidden,
            areStandardSymbolLabelsHidden: settings.areStandardSymbolLabelsHidden,
            areExtraSymbolLabelsHidden: settings.areExtraSymbolLabelsHidden
        )
    }

    /// Maps emoji labels to SF Symbol names for utility keys.
    private static let sfSymbolMap: [String: String] = [
        "🌐": "globe",
        "⌫": "delete.backward",
        "↵": "return",
    ]

    var body: some View {
        #if DEBUG
            KeyViewBodyCounter.count += 1
        #endif
        return keyContent
    }

    @ViewBuilder
    private var keyContent: some View {
        ZStack {
            background
            label
            hintOverlay
        }
        // Feel hook: the press sink, release spring, glass ripple and the
        // label cross-fade on a mode change (`KeyPressSurface.swift`).
        .modifier(KeyPressFeel(
            key: key,
            isPressed: isPressed,
            touchPoint: pressCell?.touchPoint ?? CGPoint(x: 0.5, y: 0.5),
            keyboardStyle: settings.keyboardStyle,
            isAnimated: settings.areKeyAnimationsEnabled
        ))
        // Inset the drawn key from the touch cell by `visualInset`, so the
        // visible key keeps its position/size while the cell itself extends into
        // the inter-key gaps (see KeyboardGridLayout.gapInsets).
        .padding(visualInset)
        // Fill the cell frame imposed by KeyboardGridLayout. The layout sizes
        // rows from the same effective key height, so single-row keys are
        // unchanged while a spanning key (e.g. landscape return) grows to cover
        // multiple rows.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(key.id)
        .accessibilityAddTraits(.isButton)
        .modifier(KeyAccessibilityActions(key: key, onGesture: onGesture))
        // The whole cell is the key's frame for VoiceOver's activation point;
        // touches themselves are hit-tested by the engine's `KeyHitMap`.
        .contentShape(Rectangle())
        // Pin the key's alignment/padding surface to physical LTR so the
        // directional hints (`hintAlignments` / `hintEdgePadding`, which use
        // semantic leading/trailing) always match the physical swipe
        // directions — even when a host renders this key under an RTL locale
        // (e.g. KeyboardShowcaseView / AppStoreScreenshotView for localized
        // screenshots, or SwiftUI previews). Defense-in-depth alongside the
        // root pin in DataDrivenKeyboardRootView; nested identical pins are
        // harmless.
        .environment(\.layoutDirection, .leftToRight)
    }

    // MARK: - Style

    /// Primary text shown on the key. Falls back to the binding label or the
    /// key id (so unconfigured keys are still visible during development).
    var primaryLabel: String {
        if let tap = key.bindings[.tap] {
            return tap.label
        }
        return key.id
    }

    var accessibilityLabel: String {
        if let tap = key.bindings[.tap], let custom = tap.accessibilityLabel {
            return custom
        }
        return primaryLabel
    }

    /// Base font size derived from the visual style.
    static func baseFontSize(for style: KeyStyle) -> CGFloat {
        switch style {
        case .primary:
            KeyboardConstants.FontSizes.mainLabelBaseSize
        case .secondary:
            KeyboardConstants.FontSizes.hintBaseSize
        case .utility:
            KeyboardConstants.FontSizes.utilityLabel
        case .spacebar:
            KeyboardConstants.FontSizes.defaultLabel
        case .accent:
            KeyboardConstants.FontSizes.mainLabelBaseSize
        }
    }

    /// Font size for a label whose reference size is `base`, scaled to the
    /// rendered cell and clamped both for readability and against the cell.
    /// Pure and `internal` so the "never wider than its key" relationship can
    /// be locked by a test.
    static func clampedFontSize(
        base: CGFloat,
        metrics: KeyboardLayoutMetrics,
        minimum: CGFloat,
        maximum: CGFloat,
        cellFraction: CGFloat
    ) -> CGFloat {
        let scaled = min(max(base * metrics.fontScale, minimum), maximum)
        return min(scaled, metrics.cellWidth * cellFraction)
    }

    /// Scaled font size proportional to the rendered cell height
    /// (`metrics.fontScale` is cell height over the reference key height).
    private var scaledFontSize: CGFloat {
        Self.clampedFontSize(
            base: Self.baseFontSize(for: key.style),
            metrics: metrics,
            minimum: KeyboardConstants.FontSizes.mainLabelMinSize,
            maximum: KeyboardConstants.FontSizes.mainLabelMaxSize,
            cellFraction: KeyboardConstants.FontSizes.mainLabelMaxCellFraction
        )
    }

    /// Scaled hint font size proportional to the rendered cell height.
    private var scaledHintFontSize: CGFloat {
        Self.clampedFontSize(
            base: KeyboardConstants.FontSizes.hintBaseSize,
            metrics: metrics,
            minimum: KeyboardConstants.FontSizes.hintMinSize,
            maximum: KeyboardConstants.FontSizes.hintMaxSize,
            cellFraction: KeyboardConstants.FontSizes.hintMaxCellFraction
        )
    }

    /// Whether the key should be rendered as an icon-only key (no text label).
    static func isIconOnly(style: KeyStyle) -> Bool {
        style == .utility
    }

    /// Background fill for the key.
    /// An opaque step up from the idle fill in both appearances. (The pressed
    /// fill used to be `tertiarySystemFill`, a translucent gray that over the
    /// black keyboard background landed within a few percent of the idle key
    /// in dark mode — the press was all but invisible.)
    static func backgroundColor(for style: KeyStyle, active: Bool = false) -> Color {
        if active {
            return Color(.systemGray4)
        }
        return Color(.secondarySystemBackground)
    }

    /// Whether the key is drawn pressed: a finger is on it, or a headless host
    /// holds it down (`SnapshotHooks.swift`).
    private var isPressed: Bool {
        (pressCell?.isPressed ?? false) || forcedActiveKeyIds.contains(key.id)
    }

    // MARK: - View Construction

    /// The cap, its pressed state and the light a press throws: drawn by the
    /// feel layer (`KeyPressSurface`), which keeps the styles' fills.
    private var background: some View {
        KeyPressSurface(
            keyStyle: key.style,
            keyboardStyle: settings.keyboardStyle,
            isPressed: isPressed,
            touchPoint: pressCell?.touchPoint ?? CGPoint(x: 0.5, y: 0.5),
            isAnimated: settings.areKeyAnimationsEnabled
        )
    }

    @ViewBuilder
    private var label: some View {
        if key.style == .spacebar {
            // Spacebar renders blank — label is purely for accessibility.
            EmptyView()
        } else if let tap = key.bindings[.tap], !isLabelVisible(tap) {
            // The centre label is hidden by the label-visibility setting.
            EmptyView()
        } else {
            let font = Font.system(size: scaledFontSize, weight: .semibold, design: .rounded)
            Group {
                if let sfName = Self.sfSymbolMap[primaryLabel] {
                    Image(systemName: sfName)
                        .font(font)
                } else {
                    Text(primaryLabel)
                        .font(font)
                        // Multi-character labels ("123") outgrow the cell before
                        // the size cap does; shrink instead of wrapping.
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            }
            .foregroundStyle(centerStyle)
            .opacity(guidance == .swipe ? 0.35 : 1)
            .animation(Self.guidanceAnimation, value: guidance)
        }
    }

    // MARK: - Hint Overlay

    /// Mapping from swipe `GestureType` to the SwiftUI `Alignment` where
    /// the hint label should be placed. These are PHYSICAL edges: the render
    /// tree is pinned to `.leftToRight` (see `keyContent`) so `.leading`
    /// resolves to the physical left and `.trailing` to the physical right
    /// regardless of the system language. Must never be mirrored for RTL —
    /// the swipe gesture classification is physical, so mirroring the hints
    /// would show a glyph on the opposite edge from the swipe that produces
    /// it. `internal` (not `private`) so the guard tests can lock the mapping.
    static let hintAlignments: [GestureType: Alignment] = [
        .swipeUp: .top,
        .swipeDown: .bottom,
        .swipeLeft: .leading,
        .swipeRight: .trailing,
        .swipeUpLeft: .topLeading,
        .swipeUpRight: .topTrailing,
        .swipeDownLeft: .bottomLeading,
        .swipeDownRight: .bottomTrailing,
    ]

    /// The gestures `hintOverlay` draws, in a fixed order. A static list keeps
    /// the hint layer order stable across launches (dictionary iteration order
    /// is seeded per process) and allocates nothing per render; gestures a key
    /// does not bind drop out via the `key.bindings[gesture]` lookup. Must
    /// cover exactly `hintAlignments` — a missing entry silently hides that
    /// hint. `internal` (not `private`) so the guard test can lock it.
    static let hintGestureOrder: [GestureType] = GestureType.allCases.filter(\.isSwipe)

    /// Maps certain key actions to SF Symbol names for hint rendering.
    private static func hintIcon(for action: KeyAction) -> String? {
        switch action {
        case .advanceToNextInputMode: "globe"
        case .dismissKeyboard: "keyboard.chevron.compact.down"
        case .copy: "doc.on.doc"
        case .paste: "doc.on.clipboard"
        case .cut: "scissors"
        // Note: on the globe key `hintOverlay` renders the current-language
        // label (e.g. "DE") for this action instead — both occupy the same
        // directional slot, so the more informative label wins there. The
        // icon keeps the action→icon mapping complete for any other render
        // of a language-switch binding.
        case .switchToNextLanguage: "globe.badge.chevron.backward"
        default: nil
        }
    }

    /// Directional edge padding for hint labels. Padding is only applied on
    /// the edges where the hint is aligned, keeping hints close to the key
    /// border and away from the center label. The `leading`/`trailing` insets
    /// resolve to physical left/right because the render tree is pinned to
    /// `.leftToRight`; like `hintAlignments`, this table must not be mirrored
    /// for RTL. `internal` (not `private`) so the guard tests can lock it.
    static func hintEdgePadding(
        for gesture: GestureType, horizontal: CGFloat, vertical: CGFloat
    ) -> EdgeInsets {
        switch gesture {
        case .swipeUp:
            EdgeInsets(top: vertical, leading: 0, bottom: 0, trailing: 0)
        case .swipeDown:
            EdgeInsets(top: 0, leading: 0, bottom: vertical, trailing: 0)
        case .swipeLeft:
            EdgeInsets(top: 0, leading: horizontal, bottom: 0, trailing: 0)
        case .swipeRight:
            EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: horizontal)
        case .swipeUpLeft:
            EdgeInsets(top: vertical, leading: horizontal, bottom: 0, trailing: 0)
        case .swipeUpRight:
            EdgeInsets(top: vertical, leading: 0, bottom: 0, trailing: horizontal)
        case .swipeDownLeft:
            EdgeInsets(top: 0, leading: horizontal, bottom: vertical, trailing: 0)
        case .swipeDownRight:
            EdgeInsets(top: 0, leading: 0, bottom: vertical, trailing: horizontal)
        default:
            EdgeInsets()
        }
    }

    // MARK: - Guidance

    /// What the finger on this key is heading for, from the engine's
    /// speculative classification. Reading `pressCell` here is what subscribes
    /// this key — and only this key — to its own guidance changes.
    private enum Guidance: Equatable {
        case none
        /// A swipe: its hint is emphasized and the others recede.
        case swipe
        /// A circle: the centre letter (whose capital a circle types) lights up.
        case circle
    }

    private var guidance: Guidance {
        switch pressCell?.candidate {
        case nil: .none
        case .circularClockwise?, .circularCounterclockwise?: .circle
        default: .swipe
        }
    }

    /// Fast enough to read as instant, smooth enough not to flicker when a
    /// flick's direction settles (`FeelMotion.hintEmphasis`).
    static let guidanceAnimation = FeelMotion.hintEmphasis

    private var centerStyle: AnyShapeStyle {
        guidance == .circle ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary)
    }

    private var hintOverlay: some View {
        // Scale padding proportionally with font size
        let fontRatio = scaledHintFontSize / KeyboardConstants.FontSizes.hintReferenceFontSize
        let hPad = KeyboardConstants.FontSizes.hintBaseHorizontalPadding * fontRatio
        let vPad = KeyboardConstants.FontSizes.hintBaseVerticalPadding * fontRatio

        // Each hint fills the cell via an infinity frame and pins to its
        // directional alignment, so the overlay needs no size measurement —
        // and the key no extra layout container.
        return ZStack {
            ForEach(Self.hintGestureOrder, id: \.self) { gesture in
                // Render a hint when it has a text label, or when the action
                // maps to an icon (globe, dismiss, copy/cut/paste). Utility
                // icon hints carry an empty label on purpose — their glyph is
                // derived from the action, so gating on the label alone would
                // hide them entirely.
                if let binding = key.bindings[gesture],
                   let alignment = Self.hintAlignments[gesture] {
                    if binding.action == .switchToNextLanguage {
                        if isLanguageLabelShown {
                            Text(languageLabel)
                                .font(.system(size: scaledHintFontSize * 0.75, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.primary.opacity(0.5))
                                .fixedSize()
                                .padding(Self.hintEdgePadding(for: gesture, horizontal: hPad, vertical: vPad))
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                        }
                    } else if !binding.label.isEmpty || Self.hintIcon(for: binding.action) != nil,
                              isLabelVisible(binding) {
                        let isTarget = pressCell?.candidate == gesture
                        // The hint the finger is heading for grows and takes
                        // the accent colour; the rest recede, so the eye finds
                        // the target without searching.
                        hintContent(for: binding, isTarget: isTarget)
                            .fixedSize()
                            .scaleEffect(isTarget ? 1.5 : 1, anchor: Self.hintAnchor(for: gesture))
                            .opacity(guidance != .none && !isTarget ? 0.3 : 1)
                            .padding(Self.hintEdgePadding(for: gesture, horizontal: hPad, vertical: vPad))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                    }
                }
            }
        }
        .animation(Self.guidanceAnimation, value: pressCell?.candidate)
        .allowsHitTesting(false)
    }

    /// The point an emphasized hint grows from: its own corner or edge, so it
    /// swells toward the key's centre instead of out of the key.
    static func hintAnchor(for gesture: GestureType) -> UnitPoint {
        switch gesture {
        case .swipeUp: .top
        case .swipeDown: .bottom
        case .swipeLeft: .leading
        case .swipeRight: .trailing
        case .swipeUpLeft: .topLeading
        case .swipeUpRight: .topTrailing
        case .swipeDownLeft: .bottomLeading
        case .swipeDownRight: .bottomTrailing
        default: .center
        }
    }

    /// Whether the icon is a "globe-style" hint (globe, dismiss) that gets
    /// larger, bolder styling vs. a "symbols-style" hint (copy, paste, cut).
    private static func isGlobeStyleIcon(for action: KeyAction) -> Bool {
        switch action {
        case .advanceToNextInputMode, .dismissKeyboard: true
        default: false
        }
    }

    @ViewBuilder
    private func hintContent(for binding: KeyBinding, isTarget: Bool = false) -> some View {
        if let iconName = Self.hintIcon(for: binding.action) {
            if Self.isGlobeStyleIcon(for: binding.action) {
                // Globe / dismiss: larger, bolder for discoverability
                Image(systemName: iconName)
                    .font(.system(size: scaledHintFontSize * 0.75, weight: .medium))
                    .foregroundStyle(isTarget ? Color.accentColor : Color.primary.opacity(0.5))
            } else {
                // Copy / paste / cut: smaller, lighter to avoid visual clutter
                Image(systemName: iconName)
                    .font(.system(size: scaledHintFontSize * 0.6, weight: .regular))
                    .foregroundStyle(isTarget ? Color.accentColor : Color.secondary.opacity(0.45))
            }
        } else {
            // Text hint — letters get higher prominence than symbols
            let isLetter = binding.label.first?.isLetter ?? false
            Text(binding.label)
                .font(.system(
                    size: scaledHintFontSize,
                    weight: isTarget ? .bold : isLetter ? .medium : .regular,
                    design: .rounded
                ))
                .foregroundStyle(
                    isTarget ? Color.accentColor
                        : isLetter ? Color.primary.opacity(0.65)
                        : Color.secondary.opacity(0.55)
                )
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
    }
}
