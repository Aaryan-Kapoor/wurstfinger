//
//  NumpadKeyFace.swift
//  Wurstfinger
//
//  What a numpad-column key draws: three digits side by side, symbols as hints.
//

import SwiftUI

/// The face of a `.numpad` key (`NumpadColumn`): its left, tap and right digits
/// large and evenly spaced across the middle, so the column reads as a numpad,
/// and the six symbol gestures as the small hints every key draws around its
/// edge. Replaces `KeyView`'s centre label and hint layer for that style.
///
/// It draws the same live guidance as any key: the digit or symbol the finger is
/// heading for takes the accent colour and grows, the rest recede.
struct NumpadKeyFace: View {
    let key: KeyDefinition
    let metrics: KeyboardLayoutMetrics
    let typography: KeyTypography
    let settings: KeyRenderSettings
    /// The gesture the engine's speculative classification says a release would
    /// type (`KeyPressCell.candidate`).
    let candidate: GestureType?

    /// The digit gestures, left to right.
    private static let digitGestures: [GestureType] = [.swipeLeft, .tap, .swipeRight]
    /// The symbol gestures, drawn as hints.
    private static let hintGestures: [GestureType] = [
        .swipeUp, .swipeDown, .swipeUpLeft, .swipeUpRight, .swipeDownLeft, .swipeDownRight,
    ]

    /// Digit size: a third of the cell is each digit's slot, so the size follows
    /// the cell's width, within the range a main label uses.
    private var digitFont: Font {
        let size = min(
            max(metrics.cellHeight * 0.42, KeyboardConstants.FontSizes.mainLabelMinSize - 4),
            metrics.cellWidth * 0.36,
            KeyboardConstants.FontSizes.mainLabelMaxSize
        )
        return .system(size: size, weight: .semibold, design: .rounded)
    }

    private var isGuided: Bool { candidate != nil }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                ForEach(Self.digitGestures, id: \.self) { gesture in
                    if let binding = key.bindings[gesture] {
                        let isTarget = candidate == gesture
                        Text(binding.label)
                            .font(digitFont)
                            .foregroundStyle(isTarget ? Color.accentColor : Color.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .scaleEffect(isTarget ? 1.22 : 1)
                            .opacity(isGuided && !isTarget ? 0.35 : 1)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, 1)
            .animation(KeyView.guidanceAnimation, value: candidate)

            hints
        }
    }

    private var hints: some View {
        let hPad = typography.hintHorizontalPadding
        let vPad = typography.hintVerticalPadding
        return ZStack {
            ForEach(Self.hintGestures, id: \.self) { gesture in
                if let binding = key.bindings[gesture],
                   let alignment = KeyView.hintAlignments[gesture],
                   isVisible(binding) {
                    let isTarget = candidate == gesture
                    Text(binding.label)
                        .font(isTarget ? typography.hintBold : typography.hintRegular)
                        .foregroundStyle(isTarget ? Color.accentColor : Color.secondary.opacity(0.6))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .fixedSize()
                        .scaleEffect(isTarget ? 1.5 : 1, anchor: KeyView.hintAnchor(for: gesture))
                        .opacity(isGuided && !isTarget ? 0.3 : 1)
                        .padding(KeyView.hintEdgePadding(for: gesture, horizontal: hPad, vertical: vPad))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                }
            }
        }
        .animation(KeyView.guidanceAnimation, value: candidate)
        .allowsHitTesting(false)
    }

    /// The symbols follow the label-visibility settings like every other key's
    /// hints; digits are `LabelCategory.number` and always show.
    private func isVisible(_ binding: KeyBinding) -> Bool {
        LabelCategory.of(binding).isVisible(
            areLetterLabelsHidden: settings.areLetterLabelsHidden,
            areStandardSymbolLabelsHidden: settings.areStandardSymbolLabelsHidden,
            areExtraSymbolLabelsHidden: settings.areExtraSymbolLabelsHidden
        )
    }
}
