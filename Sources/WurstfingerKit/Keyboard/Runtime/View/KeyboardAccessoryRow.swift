//
//  KeyboardAccessoryRow.swift
//  Wurstfinger
//
//  The row above the keys: word completions.
//

import SwiftUI

/// The row above the keys: shown, at `KeyboardLayoutMetrics.accessoryHeight`,
/// whenever `KeyboardViewModel.accessoryRowHeight` is non-zero. The layout
/// plan reserves its height (the keys shrink rather than the keyboard
/// outgrowing the screen) and it moves with the keys through every resize.
///
/// Holds up to three completions of the word before the cursor
/// (`WordCompletions`); a tap on one types the rest of the word and a space.
/// It reads only `viewModel.completions.candidates`, so a keystroke that
/// changes nothing about them re-renders nothing here, and the keys never
/// re-render for the row.
struct KeyboardAccessoryRow: View {
    let viewModel: KeyboardViewModel

    @AppStorage(SettingsKey.keyboardStyle.rawValue, store: SharedDefaults.store)
    private var keyboardStyle: KeyboardStyle = KeyRenderSettings.stock.keyboardStyle

    var body: some View {
        CompletionRow(
            candidates: viewModel.completions.candidates,
            keyboardStyle: keyboardStyle,
            direction: Self.direction(of: viewModel.pipelineLocale),
            accept: { completion in
                viewModel.feedbackTap()
                viewModel.acceptCompletion(completion)
            }
        )
    }

    /// The reading direction of the layout's language. The keyboard itself is
    /// pinned left-to-right (its keys are physical positions), but the words
    /// in this row are text: an RTL language lists its best completion at the
    /// right, where its reader starts.
    static func direction(of locale: Locale?) -> LayoutDirection {
        guard let language = locale?.language else { return .leftToRight }
        return language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }
}

/// The completions as text segments with dividers between them.
///
/// The typed beginning of each word is de-emphasized and what accepting adds
/// is set in the foreground weight, so the eye lands on the part that saves
/// keystrokes. The segments share the width equally, so a single completion
/// is centred, and a long word loses the start of its typed part to the
/// ellipsis, never the end.
struct CompletionRow: View {
    let candidates: [Completion]
    let keyboardStyle: KeyboardStyle
    var direction: LayoutDirection = .leftToRight
    let accept: (Completion) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.forcedPressedCompletion) private var forcedPressed

    /// Row text size: the system keyboard's suggestion bar reads at 17.
    private static let fontSize: CGFloat = 17

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, completion in
                if index > 0 { divider }
                Button { accept(completion) } label: {
                    Text(Self.styled(completion))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(CompletionButtonStyle(
                    keyboardStyle: keyboardStyle, colorScheme: colorScheme, isForcedPressed: forcedPressed == index
                ))
                .accessibilityLabel(completion.word)
                .accessibilityHint(String(localized: "Types the rest of the word and a space"))
            }
        }
        .background { glassTile }
        .padding(.horizontal, KeyboardConstants.Layout.horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Words arrive with the keystroke that changed them; a fade would only
        // make the row lag the typing.
        .transaction { $0.animation = nil }
        .environment(\.layoutDirection, direction)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Suggestions"))
        .accessibilityHidden(candidates.isEmpty)
    }

    /// On glass the row is one tile of the keys' own material, so its words
    /// stay readable over whatever the host shows behind the keyboard; the
    /// classic style leaves it flat, like the system keyboard's bar.
    @ViewBuilder
    private var glassTile: some View {
        if keyboardStyle == .liquidGlass, !candidates.isEmpty {
            let shape = RoundedRectangle(cornerRadius: KeyboardConstants.KeyDimensions.cornerRadius)
            shape.fill(.bar)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .padding(.vertical, 2)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(keyboardStyle == .liquidGlass ? 0.22 : 0.16))
            .frame(width: 1, height: 22)
            .accessibilityHidden(true)
    }

    /// One completion's text: typed part secondary, the rest primary and
    /// heavier. Built on attributed ranges, not concatenated runs, so a
    /// right-to-left word shapes as one piece of text.
    static func styled(_ completion: Completion) -> AttributedString {
        let parts = completion.split
        var typed = AttributedString(String(parts.typed))
        typed.foregroundColor = .secondary
        typed.font = .system(size: fontSize)
        var rest = AttributedString(String(parts.rest))
        rest.foregroundColor = .primary
        rest.font = .system(size: fontSize, weight: .semibold)
        return typed + rest
    }
}

/// The press state of a completion: a soft rounded highlight under the
/// finger, instant on touch-down like a key's, easing out on release. On glass
/// it is a touch stronger, as the glass keys' press is.
private struct CompletionButtonStyle: ButtonStyle {
    let keyboardStyle: KeyboardStyle
    let colorScheme: ColorScheme
    /// A headless host holds it down (`SnapshotHooks.swift`).
    var isForcedPressed = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed || isForcedPressed ? pressedOpacity : 0))
                    .padding(.vertical, 3)
                    .padding(.horizontal, 2)
            )
            .animation(configuration.isPressed || reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }

    private var pressedOpacity: Double {
        switch (keyboardStyle, colorScheme) {
        case (.liquidGlass, _): 0.18
        case (.classic, .dark): 0.16
        case (.classic, _): 0.1
        }
    }
}
