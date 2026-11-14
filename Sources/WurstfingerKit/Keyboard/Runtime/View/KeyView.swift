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
    // Long-press behaviour (issue #308): arms the engine's hold timer
    // (`isLongPressEnabled`); what the hold types is resolved from the typing
    // snapshot, not rendered.
    var longPress = LongPressType.default
    var isLongPressEnabled: Bool { longPress.isEnabled }
    /// Press, release and commit animations and the light effects on keys
    /// (`SettingsKey.keyAnimationsEnabled`).
    var areKeyAnimationsEnabled = true
    /// Under VoiceOver, the grid is one direct-touch area that speaks gesture
    /// targets (`SettingsKey.voiceOverGestureTyping`).
    var isVoiceOverGestureTypingEnabled = false

    /// The values a key renders with when nothing is stored yet. Single source
    /// for those defaults: `DataDrivenKeyboardRootView` initializes its
    /// `@AppStorage` wrappers from it, so the snapshot a test or preview builds
    /// with `KeyRenderSettings()` cannot drift from what an untouched
    /// installation actually renders.
    static let stock = KeyRenderSettings()
}

/// The fonts and hint paddings every key of one grid draws with, resolved
/// once per grid from the layout metrics.
///
/// A `Font` is a boxed descriptor, so building one is a heap allocation. A
/// key used to build nine per body (its label and up to eight hints), ~40
/// keys per mode: a few hundred allocations per mode switch for values that
/// depend only on the metrics. The grid builds this once and hands it down;
/// a key picks from it.
struct KeyTypography: Equatable {
    /// The centre label, per key style (the base size differs by style).
    private let labels: [Font]
    /// Text hints at regular, medium (letters) and bold (the one targeted).
    let hintRegular: Font
    let hintMedium: Font
    let hintBold: Font
    /// The language code on the globe key.
    let languageLabel: Font
    /// Globe / dismiss icons, larger for discoverability.
    let globeIcon: Font
    /// Copy / paste / cut icons, lighter to avoid clutter.
    let symbolIcon: Font
    /// Hint padding from the key edge, scaled with the hint font.
    let hintHorizontalPadding: CGFloat
    let hintVerticalPadding: CGFloat

    init(metrics: KeyboardLayoutMetrics) {
        labels = KeyStyle.allCases.map { style in
            Font.system(
                size: KeyView.clampedFontSize(
                    base: KeyView.baseFontSize(for: style),
                    metrics: metrics,
                    minimum: KeyboardConstants.FontSizes.mainLabelMinSize,
                    maximum: KeyboardConstants.FontSizes.mainLabelMaxSize,
                    cellFraction: KeyboardConstants.FontSizes.mainLabelMaxCellFraction
                ),
                weight: .semibold, design: .rounded
            )
        }
        let hintSize = KeyView.clampedFontSize(
            base: KeyboardConstants.FontSizes.hintBaseSize,
            metrics: metrics,
            minimum: KeyboardConstants.FontSizes.hintMinSize,
            maximum: KeyboardConstants.FontSizes.hintMaxSize,
            cellFraction: KeyboardConstants.FontSizes.hintMaxCellFraction
        )
        hintRegular = .system(size: hintSize, weight: .regular, design: .rounded)
        hintMedium = .system(size: hintSize, weight: .medium, design: .rounded)
        hintBold = .system(size: hintSize, weight: .bold, design: .rounded)
        languageLabel = .system(size: hintSize * 0.75, weight: .semibold, design: .rounded)
        globeIcon = .system(size: hintSize * 0.75, weight: .medium)
        symbolIcon = .system(size: hintSize * 0.6, weight: .regular)
        // Scale padding proportionally with font size.
        let fontRatio = hintSize / KeyboardConstants.FontSizes.hintReferenceFontSize
        hintHorizontalPadding = KeyboardConstants.FontSizes.hintBaseHorizontalPadding * fontRatio
        hintVerticalPadding = KeyboardConstants.FontSizes.hintBaseVerticalPadding * fontRatio
    }

    func label(for style: KeyStyle) -> Font {
        labels[KeyStyle.allCases.firstIndex(of: style) ?? 0]
    }
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
///
/// `Equatable`, and installed with `.equatable()` by the grid: when the root
/// re-evaluates for a reason that changes nothing a key draws (a gesture
/// tuning slider, a language-list change), SwiftUI compares the inputs and
/// skips the body. The `onGesture` callback is left out of the comparison on
/// purpose — it is a new closure per root body with the same meaning every
/// time (it forwards to the view model).
struct KeyView: View, Equatable {
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
    /// when the view model is configured programmatically). No default: every
    /// caller must pass the resolved metrics explicitly so a `.reference`
    /// fallback can never silently mask a wiring gap (production sites already
    /// do).
    var metrics: KeyboardLayoutMetrics

    /// The fonts for this grid, built once by `KeyboardGridView` from the
    /// same metrics (see `KeyTypography`).
    let typography: KeyTypography

    /// Short language label (e.g. "DE") shown on the switch key, and whether to
    /// show it. Driven by the active keyboard locale via `KeyboardViewModel`
    /// (threaded through `KeyboardGridView`) rather than re-derived from shared
    /// defaults, so the hint stays correct even when startup loads a pinned
    /// language whose id differs from the stored selection.
    var languageLabel: String = ""
    var isLanguageLabelShown: Bool = false

    init(
        key: KeyDefinition,
        onGesture: @escaping (KeyDefinition, GestureType, Bool) -> Void,
        pressCell: KeyPressCell? = nil,
        visualInset: EdgeInsets = .init(),
        settings: KeyRenderSettings,
        metrics: KeyboardLayoutMetrics,
        typography: KeyTypography? = nil,
        languageLabel: String = "",
        isLanguageLabelShown: Bool = false
    ) {
        self.key = key
        self.onGesture = onGesture
        self.pressCell = pressCell
        self.visualInset = visualInset
        self.settings = settings
        self.metrics = metrics
        self.typography = typography ?? KeyTypography(metrics: metrics)
        self.languageLabel = languageLabel
        self.isLanguageLabelShown = isLanguageLabelShown
    }

    nonisolated static func == (lhs: KeyView, rhs: KeyView) -> Bool {
        lhs.pressCell === rhs.pressCell
            && lhs.visualInset == rhs.visualInset
            && lhs.settings == rhs.settings
            && lhs.metrics == rhs.metrics
            && lhs.languageLabel == rhs.languageLabel
            && lhs.isLanguageLabelShown == rhs.isLanguageLabelShown
            && lhs.typography == rhs.typography
            && lhs.key == rhs.key
    }

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
            // Numpad column (WP-B): three digits across the key and symbol
            // hints, drawn by `NumpadKeyFace` instead of the label and hints.
            if key.style == .numpad {
                NumpadKeyFace(
                    key: key, metrics: metrics, typography: typography,
                    settings: settings, candidate: pressCell?.candidate
                )
            } else {
                label
                hintOverlay
            }
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
    nonisolated static func baseFontSize(for style: KeyStyle) -> CGFloat {
        switch style {
        case .primary:
            KeyboardConstants.FontSizes.mainLabelBaseSize
        case .secondary:
            KeyboardConstants.FontSizes.hintBaseSize
        case .utility:
            KeyboardConstants.FontSizes.utilityLabel
        case .spacebar:
            KeyboardConstants.FontSizes.defaultLabel
        case .accent, .numpad:
            KeyboardConstants.FontSizes.mainLabelBaseSize
        }
    }

    /// Font size for a label whose reference size is `base`, scaled to the
    /// rendered cell and clamped both for readability and against the cell.
    /// Pure and `internal` so the "never wider than its key" relationship can
    /// be locked by a test.
    nonisolated static func clampedFontSize(
        base: CGFloat,
        metrics: KeyboardLayoutMetrics,
        minimum: CGFloat,
        maximum: CGFloat,
        cellFraction: CGFloat
    ) -> CGFloat {
        let scaled = min(max(base * metrics.fontScale, minimum), maximum)
        return min(scaled, metrics.cellWidth * cellFraction)
    }

    /// Whether the key should be rendered as an icon-only key (no text label).
    static func isIconOnly(style: KeyStyle) -> Bool {
        style == .utility
    }

    /// The idle and pressed fills, resolved once: bridging a `UIColor` into a
    /// `Color` per body was a small allocation on every key of every render.
    private static let idleFill = Color(.secondarySystemBackground)
    private static let pressedFill = Color(.systemGray4)

    /// Background fill for the key.
    /// An opaque step up from the idle fill in both appearances. (The pressed
    /// fill used to be `tertiarySystemFill`, a translucent gray that over the
    /// black keyboard background landed within a few percent of the idle key
    /// in dark mode — the press was all but invisible.)
    static func backgroundColor(for style: KeyStyle, active: Bool = false) -> Color {
        active ? pressedFill : idleFill
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
            let font = typography.label(for: key.style)
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
    nonisolated static let hintAlignments: [GestureType: Alignment] = [
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
    nonisolated static let hintGestureOrder: [GestureType] = GestureType.allCases.filter(\.isSwipe)

    /// Maps certain key actions to SF Symbol names for hint rendering.
    nonisolated static func hintIcon(for action: KeyAction) -> String? {
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
    nonisolated static func hintEdgePadding(
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
        /// A circle: the centre letter lights up (a circle acts on the key itself;
        /// what it will type is on the guide card, resolved per the circle settings).
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

    /// Both branches are a `Color`, so no type-erased style box is needed.
    private var centerStyle: Color {
        guidance == .circle ? Color.accentColor : Color.primary
    }

    /// How the hints are drawn: one `Canvas` per key (`KeyHintCanvas`), which
    /// costs 40% less heap per keyboard graph than a view per glyph and renders
    /// faster, at pixel parity (`docs/rework-review.md`, S10). The view stacks
    /// stay selectable so the benchmark and the snapshot tool can compare the
    /// two in one process.
    @MainActor static var hintRendering = HintRendering.canvas

    @ViewBuilder
    private var hintOverlay: some View {
        switch Self.hintRendering {
        case .views: viewHintOverlay
        case .canvas: canvasHintOverlay
        }
    }

    /// The hints as one `Canvas` per key. The identity is the hint set, so a
    /// mode or language change fades the new hints in over the old ones
    /// (`FeelMotion.labelSwap`, from `KeyPressFeel`'s `.animation(value: key)`)
    /// where the view stacks cross-faded each glyph with `contentTransition`.
    private var canvasHintOverlay: some View {
        let hints = KeyHintCanvas.hints(
            for: key, languageLabel: languageLabel, isLanguageLabelShown: isLanguageLabelShown,
            isLabelVisible: isLabelVisible
        )
        return KeyHintCanvas(
            hints: hints,
            typography: typography,
            emphasis: HintEmphasis(candidate: pressCell?.candidate, isGuided: guidance != .none)
        )
        .animation(Self.guidanceAnimation, value: pressCell?.candidate)
        .id(hints)
        .transition(.opacity)
    }

    private var viewHintOverlay: some View {
        let hPad = typography.hintHorizontalPadding
        let vPad = typography.hintVerticalPadding

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
                                .font(typography.languageLabel)
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
    nonisolated static func hintAnchor(for gesture: GestureType) -> UnitPoint {
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
    nonisolated static func isGlobeStyleIcon(for action: KeyAction) -> Bool {
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
                    .font(typography.globeIcon)
                    .foregroundStyle(isTarget ? Color.accentColor : Color.primary.opacity(0.5))
            } else {
                // Copy / paste / cut: smaller, lighter to avoid visual clutter
                Image(systemName: iconName)
                    .font(typography.symbolIcon)
                    .foregroundStyle(isTarget ? Color.accentColor : Color.secondary.opacity(0.45))
            }
        } else {
            // Text hint — letters get higher prominence than symbols
            let isLetter = binding.label.first?.isLetter ?? false
            Text(binding.label)
                .font(isTarget ? typography.hintBold : isLetter ? typography.hintMedium : typography.hintRegular)
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
