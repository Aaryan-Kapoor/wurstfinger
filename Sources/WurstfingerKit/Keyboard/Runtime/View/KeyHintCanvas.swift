//
//  KeyHintCanvas.swift
//  Wurstfinger
//
//  A key's eight swipe hints drawn into one `Canvas` instead of one SwiftUI
//  view stack apiece.
//

import SwiftUI

/// How `KeyView` draws its hints: one view stack per hint, or one `Canvas`
/// for the whole key (`KeyHintCanvas`). A switch only so the benchmark can
/// measure both in one process.
enum HintRendering: Sendable {
    case views
    case canvas
}

/// What the finger is heading for, as numbers a `Canvas` can animate: per hint
/// slot (the index into `KeyView.hintGestureOrder`) how far the hint has
/// swelled toward its target look, and how opaque it is.
///
/// The view stack path animates each hint's `scaleEffect`, colour and `opacity`
/// by itself, so a flick that turns from one direction to the next shrinks
/// one hint while the other grows. A `Canvas` has no such parts, only the
/// closure it is redrawn with, so the same two curves per hint are carried as
/// a vector for `Animatable` to run `FeelMotion.hintEmphasis` over.
struct HintEmphasis: VectorArithmetic, Sendable {
    /// 0 for a hint at rest, 1 for the hint the finger is heading for.
    var lift: SIMD8<Double>
    /// The hint's opacity: 1 at rest, `receded` while another is the target.
    var opacity: SIMD8<Double>

    /// Opacity of the hints that are not the target.
    static let receded = 0.3

    /// Nothing emphasized: every hint at full opacity.
    static let rest = HintEmphasis(lift: .zero, opacity: .one)

    /// Emphasis for a finger heading for `candidate` (nil: no finger), where
    /// `isGuided` says the engine is classifying a gesture at all (a circle
    /// has no hint to swell, but still lets them all recede).
    init(candidate: GestureType?, isGuided: Bool) {
        var lift = SIMD8<Double>.zero
        var opacity = SIMD8<Double>.one
        for (slot, gesture) in KeyView.hintGestureOrder.enumerated() {
            let isTarget = candidate == gesture
            lift[slot] = isTarget ? 1 : 0
            opacity[slot] = isGuided && !isTarget ? Self.receded : 1
        }
        self.lift = lift
        self.opacity = opacity
    }

    private init(lift: SIMD8<Double>, opacity: SIMD8<Double>) {
        self.lift = lift
        self.opacity = opacity
    }

    static var zero: HintEmphasis { HintEmphasis(lift: .zero, opacity: .zero) }

    static func + (lhs: HintEmphasis, rhs: HintEmphasis) -> HintEmphasis {
        HintEmphasis(lift: lhs.lift + rhs.lift, opacity: lhs.opacity + rhs.opacity)
    }

    static func - (lhs: HintEmphasis, rhs: HintEmphasis) -> HintEmphasis {
        HintEmphasis(lift: lhs.lift - rhs.lift, opacity: lhs.opacity - rhs.opacity)
    }

    mutating func scale(by rhs: Double) {
        lift *= rhs
        opacity *= rhs
    }

    var magnitudeSquared: Double {
        (lift * lift).sum() + (opacity * opacity).sum()
    }
}

/// All of a key's swipe hints in one `Canvas`.
///
/// A key's hints were eight `Text`/`Image` stacks (font, colour, `fixedSize`,
/// `scaleEffect`, `opacity`, edge padding, an infinity frame), each a node
/// SwiftUI keeps alive per key — about forty keys a mode. This draws the same
/// glyphs at the same places into one node: it resolves each label with the
/// font the stack would have used, measures it, and positions it by the same
/// alignment and padding arithmetic the layout did.
///
/// What carries over exactly, and why:
/// - **No scale-to-fit.** The stacks pinned each hint with `fixedSize()`,
///   which proposes no size, so their `minimumScaleFactor(0.6)` never had an
///   overflow to shrink and a hint always drew at its ideal size, even past
///   the key's edge. The canvas draws at the ideal size too.
/// - **Emphasis** is `Animatable`: `emphasis` interpolates under
///   `FeelMotion.hintEmphasis`, so the 80 ms swell and recede still run.
///   The only thing it cannot interpolate is the font weight (regular to
///   bold) — it switches at the half-way point, where the stacks switched
///   at once.
/// - **Mode change.** The feel layer cross-fades a changed label with
///   `contentTransition(.interpolate)`, which has nothing to interpolate in a
///   canvas. `KeyView` gives the canvas an identity tied to the hint set
///   (`.id(hints)`) and an opacity transition, so a new mode's hints fade in
///   over the old ones under `FeelMotion.labelSwap` instead of snapping.
/// - **Icons** are SF Symbols, which a canvas cannot size from a font by
///   itself. They are drawn as the canvas' `symbols`: the same `Image` views
///   the stacks used, laid out by SwiftUI, in a rest and an accent colour.
nonisolated struct KeyHintCanvas: View, Animatable {
    /// One hint to draw.
    struct Hint: Hashable, Sendable {
        /// Index of the hint's gesture in `KeyView.hintGestureOrder`.
        var slot: Int
        var content: Content

        enum Content: Hashable, Sendable {
            /// A text label, `isLetter` for the more prominent letter styling.
            case text(String, isLetter: Bool)
            /// An emoji (EMOJI MODE): drawn at `KeyTypography.hintEmoji`, in its
            /// own colours, never tinted by the rest or accent colour.
            case emoji(String)
            /// An SF Symbol; `isGlobeStyle` for the larger, bolder icon size.
            case icon(name: String, isGlobeStyle: Bool)
            /// The language code on the globe key. Never emphasized.
            case language(String)
        }

        var gesture: GestureType { KeyView.hintGestureOrder[slot] }

        /// How much smaller than normal this hint is drawn so as not to
        /// overflow its cell; 1 for an icon or the language code. Cached
        /// measurements (`HintFit.inkSize`), so a redraw during an animation
        /// shapes nothing.
        nonisolated func fit(typography: KeyTypography) -> CGFloat {
            let metrics: HintFit.InkMetrics
            let isEmoji: Bool
            switch content {
            case let .text(label, _):
                metrics = HintFit.inkMetrics(of: label, pointSize: typography.hintPointSize)
                isEmoji = false
            case let .emoji(label):
                metrics = HintFit.inkMetrics(of: label, pointSize: typography.emojiHintPointSize)
                isEmoji = true
            case .icon, .language: return 1
            }
            return HintFit.hintScale(
                metrics: metrics, gesture: gesture, key: typography.keySize,
                horizontalPadding: typography.hintHorizontalPadding, verticalPadding: typography.hintVerticalPadding,
                gap: HintFit.gap(forEmoji: isEmoji)
            )
        }
    }

    let hints: [Hint]
    let typography: KeyTypography
    /// What is emphasized right now; the animated part.
    var emphasis: HintEmphasis

    var animatableData: HintEmphasis {
        get { emphasis }
        set { emphasis = newValue }
    }

    /// Identity of an icon's symbol view: which glyph, at which size class,
    /// in which colour.
    private struct SymbolID: Hashable {
        var name: String
        var isGlobeStyle: Bool
        var isAccent: Bool
    }

    private var symbolIDs: [SymbolID] {
        hints.flatMap { hint -> [SymbolID] in
            guard case let .icon(name, isGlobeStyle) = hint.content else { return [] }
            return [false, true].map { SymbolID(name: name, isGlobeStyle: isGlobeStyle, isAccent: $0) }
        }
    }

    var body: some View {
        let hints = hints
        let typography = typography
        let emphasis = emphasis
        Canvas { context, size in
            Self.draw(hints, emphasis: emphasis, typography: typography, in: &context, size: size)
        } symbols: {
            ForEach(symbolIDs, id: \.self) { id in
                Self.symbolView(id, typography: typography).tag(id)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Content

    /// The hints `key` shows, in drawing order: the same gate the view stacks
    /// applied (a label or an icon, and the label-visibility setting), with the
    /// language label standing in on the language-switch binding.
    static func hints(
        for key: KeyDefinition,
        languageLabel: String,
        isLanguageLabelShown: Bool,
        isLabelVisible: (KeyBinding) -> Bool
    ) -> [Hint] {
        var hints = [Hint]()
        for (slot, gesture) in KeyView.hintGestureOrder.enumerated() {
            guard let binding = key.bindings[gesture] else { continue }
            if binding.action == .switchToNextLanguage {
                if isLanguageLabelShown { hints.append(Hint(slot: slot, content: .language(languageLabel))) }
            } else if !binding.label.isEmpty || KeyView.hintIcon(for: binding.action) != nil,
                      isLabelVisible(binding) {
                if let name = KeyView.hintIcon(for: binding.action) {
                    hints.append(Hint(slot: slot, content: .icon(
                        name: name, isGlobeStyle: KeyView.isGlobeStyleIcon(for: binding.action)
                    )))
                } else if EmojiText.isEmoji(binding.label) {
                    hints.append(Hint(slot: slot, content: .emoji(binding.label)))
                } else {
                    hints.append(Hint(slot: slot, content: .text(
                        binding.label, isLetter: binding.label.first?.isLetter ?? false
                    )))
                }
            }
        }
        return hints
    }

    // MARK: - Colours

    /// The colours a hint takes at rest; the accent colour when targeted.
    private nonisolated static func restColor(for content: Hint.Content) -> Color {
        switch content {
        case let .text(_, isLetter): isLetter ? Color.primary.opacity(0.65) : Color.secondary.opacity(0.55)
        case let .icon(_, isGlobeStyle): isGlobeStyle ? Color.primary.opacity(0.5) : Color.secondary.opacity(0.45)
        case .language: Color.primary.opacity(0.5)
        case .emoji: Color.primary
        }
    }

    @ViewBuilder
    private static func symbolView(_ id: SymbolID, typography: KeyTypography) -> some View {
        let font = id.isGlobeStyle ? typography.globeIcon : typography.symbolIcon
        let rest = restColor(for: .icon(name: id.name, isGlobeStyle: id.isGlobeStyle))
        Image(systemName: id.name)
            .font(font)
            .foregroundStyle(id.isAccent ? Color.accentColor : rest)
            .fixedSize()
    }

    /// `base` blended toward `target` by `fraction`, for the frames between rest
    /// and emphasized. Whole-number fractions return the colours untouched, so
    /// a still at rest or at the target is bit-for-bit the stack's colour.
    private nonisolated static func blend(
        _ base: Color, toward target: Color, by fraction: Double, in environment: EnvironmentValues
    ) -> Color {
        if fraction <= 0 { return base }
        if fraction >= 1 { return target }
        let from = base.resolve(in: environment)
        let to = target.resolve(in: environment)
        let mix = Float(fraction)
        return Color(
            .sRGB,
            red: Double(from.red + (to.red - from.red) * mix),
            green: Double(from.green + (to.green - from.green) * mix),
            blue: Double(from.blue + (to.blue - from.blue) * mix),
            opacity: Double(from.opacity + (to.opacity - from.opacity) * mix)
        )
    }

    // MARK: - Drawing

    /// How far an emphasized hint grows.
    private nonisolated static let emphasizedScale = 1.5

    private nonisolated static func draw(
        _ hints: [Hint],
        emphasis: HintEmphasis,
        typography: KeyTypography,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let unbounded = CGSize(width: CGFloat.infinity, height: CGFloat.infinity)
        for hint in hints {
            let gesture = hint.gesture
            let isEmphasizable: Bool
            if case .language = hint.content { isEmphasizable = false } else { isEmphasizable = true }
            let lift = isEmphasizable ? min(max(emphasis.lift[hint.slot], 0), 1) : 0
            let opacity = isEmphasizable ? min(max(emphasis.opacity[hint.slot], 0), 1) : 1
            let rest = restColor(for: hint.content)

            // The hint's own size (its ideal size: the stacks were `fixedSize`)
            // and how to draw it at a point and an anchor.
            var glyph = CGSize.zero
            var drawGlyph: (inout GraphicsContext, CGPoint) -> Void = { _, _ in }
            switch hint.content {
            case let .text(label, isLetter):
                let font = lift >= 0.5 ? typography.hintBold : isLetter ? typography.hintMedium : typography.hintRegular
                let color = blend(rest, toward: .accentColor, by: lift, in: context.environment)
                let resolved = context.resolve(Text(label).font(font).foregroundStyle(color))
                glyph = resolved.measure(in: unbounded)
                drawGlyph = { context, origin in context.draw(resolved, at: origin, anchor: .topLeading) }
            case let .emoji(label):
                // No foreground style: a colour glyph keeps its own colours, and
                // the emphasis is the swell and the receding of the others.
                let resolved = context.resolve(Text(label).font(typography.hintEmoji))
                glyph = resolved.measure(in: unbounded)
                drawGlyph = { context, origin in context.draw(resolved, at: origin, anchor: .topLeading) }
            case let .language(label):
                let resolved = context.resolve(Text(label).font(typography.languageLabel).foregroundStyle(rest))
                glyph = resolved.measure(in: unbounded)
                drawGlyph = { context, origin in context.draw(resolved, at: origin, anchor: .topLeading) }
            case let .icon(name, isGlobeStyle):
                let restID = SymbolID(name: name, isGlobeStyle: isGlobeStyle, isAccent: false)
                let accentID = SymbolID(name: name, isGlobeStyle: isGlobeStyle, isAccent: true)
                guard let restSymbol = context.resolveSymbol(id: restID),
                      let accentSymbol = context.resolveSymbol(id: accentID) else { continue }
                glyph = restSymbol.size
                drawGlyph = { context, origin in
                    // A cross-fade between the two colours of the same glyph:
                    // exact at either end, which is where a still lands.
                    if lift < 1 {
                        var rested = context
                        rested.opacity *= 1 - lift
                        rested.draw(restSymbol, at: origin, anchor: .topLeading)
                    }
                    if lift > 0 {
                        var lit = context
                        lit.opacity *= lift
                        lit.draw(accentSymbol, at: origin, anchor: .topLeading)
                    }
                }
            }

            // A hint with no area (a lone combining mark measures zero wide)
            // was never drawn by the stacks: SwiftUI drops a zero-sized view
            // along with its ink. The canvas drops it too, so a key looks
            // the same either way.
            guard glyph.width > 0, glyph.height > 0 else { continue }

            // Padding then alignment, as the stack's `.padding` and
            // `.frame(alignment:)` placed it: the padded box sits at the
            // alignment point of the key, the glyph inside it.
            let padding = KeyView.hintEdgePadding(
                for: gesture, horizontal: typography.hintHorizontalPadding, vertical: typography.hintVerticalPadding
            )
            let alignment = unitPoint(for: KeyView.hintAlignments[gesture] ?? .center)
            let padded = CGSize(
                width: glyph.width + padding.leading + padding.trailing,
                height: glyph.height + padding.top + padding.bottom
            )
            let scale = max(context.environment.displayScale, 1)
            let unsnapped = CGPoint(
                x: ((size.width - padded.width) * alignment.x + padding.leading) * scale,
                y: ((size.height - padded.height) * alignment.y + padding.top) * scale
            )
            let origin = CGPoint(x: snap(unsnapped.x) / scale, y: snap(unsnapped.y) / scale)

            var pass = context
            pass.opacity *= opacity
            // A glyph too wide for its third of the key is drawn smaller, held at
            // the edge it hangs from (`HintFit`).
            let fit = hint.fit(typography: typography)
            if lift > 0 || fit != 1 {
                let scale = (1 + (emphasizedScale - 1) * lift) * fit
                let anchor = KeyView.hintAnchor(for: gesture)
                let pivot = CGPoint(x: origin.x + glyph.width * anchor.x, y: origin.y + glyph.height * anchor.y)
                pass.translateBy(x: pivot.x, y: pivot.y)
                pass.scaleBy(x: scale, y: scale)
                pass.translateBy(x: -pivot.x, y: -pivot.y)
            }
            drawGlyph(&pass, origin)
        }
    }

    /// `value` (in device pixels) rounded to the nearest pixel, halves up. The
    /// nudge keeps a centred hint whose exact position is half a pixel — 63.5
    /// computed as 63.499999999999993 — on the side SwiftUI's layout rounds it
    /// to.
    private nonisolated static func snap(_ value: CGFloat) -> CGFloat {
        (value + 0.5 + 1e-6).rounded(.down)
    }

    /// The point of a rectangle an `Alignment` pins to, in unit coordinates.
    /// Pure and `internal` so a test can hold it to `KeyView.hintAnchor`.
    nonisolated static func unitPoint(for alignment: Alignment) -> UnitPoint {
        let x: CGFloat = alignment.horizontal == .leading ? 0 : alignment.horizontal == .trailing ? 1 : 0.5
        let y: CGFloat = alignment.vertical == .top ? 0 : alignment.vertical == .bottom ? 1 : 0.5
        return UnitPoint(x: x, y: y)
    }
}
