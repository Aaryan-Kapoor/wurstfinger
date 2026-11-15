//
//  DataDrivenKeyboardRootView.swift
//  Wurstfinger
//
//  Root SwiftUI view that renders the data-driven keyboard using
//  KeyboardGridView. Replaces KeyboardRootView as the hosting target
//  in KeyboardViewController.
//

import SwiftUI

/// Root view for the data-driven keyboard path. Reads mode and arrangement
/// from the ViewModel and delegates all gesture callbacks back to it.
///
/// The view model is `@Observable`: reading `viewModel.viewWidth`,
/// `activeModeName` and the rest below is what subscribes this body to them,
/// property by property — so a haptic-intensity or typing-toggle change, which
/// nothing here reads, re-renders no keys at all.
struct DataDrivenKeyboardRootView: View {
    let viewModel: KeyboardViewModel

    /// Optional width override used by InteractiveKeyboardPreview.
    /// When nil, falls back to `viewModel.viewWidth`.
    var overrideWidth: CGFloat?

    // Single read site for the per-key render settings: one observation per
    // setting for the whole keyboard rather than one per key view. The root
    // re-renders on changes and passes fresh values down. The unstored-value
    // defaults come from `KeyRenderSettings.stock`, so this site and the
    // snapshot type agree on what an untouched installation renders.
    @AppStorage(SettingsKey.keyboardStyle.rawValue, store: SharedDefaults.store)
    private var keyboardStyle: KeyboardStyle = KeyRenderSettings.stock.keyboardStyle

    @AppStorage(SettingsKey.areLetterLabelsHidden.rawValue, store: SharedDefaults.store)
    private var areLetterLabelsHidden = KeyRenderSettings.stock.areLetterLabelsHidden

    @AppStorage(SettingsKey.areStandardSymbolLabelsHidden.rawValue, store: SharedDefaults.store)
    private var areStandardSymbolLabelsHidden = KeyRenderSettings.stock.areStandardSymbolLabelsHidden

    @AppStorage(SettingsKey.areExtraSymbolLabelsHidden.rawValue, store: SharedDefaults.store)
    private var areExtraSymbolLabelsHidden = KeyRenderSettings.stock.areExtraSymbolLabelsHidden

    @AppStorage(SettingsKey.longPressBehaviour.rawValue, store: SharedDefaults.store)
    private var longPress = KeyRenderSettings.stock.longPress

    @AppStorage(SettingsKey.keyAnimationsEnabled.rawValue, store: SharedDefaults.store)
    private var areKeyAnimationsEnabled = KeyRenderSettings.stock.areKeyAnimationsEnabled

    @AppStorage(SettingsKey.voiceOverGestureTyping.rawValue, store: SharedDefaults.store)
    private var isVoiceOverGestureTypingEnabled = KeyRenderSettings.stock.isVoiceOverGestureTypingEnabled

    private var renderSettings: KeyRenderSettings {
        KeyRenderSettings(
            keyboardStyle: keyboardStyle,
            areLetterLabelsHidden: areLetterLabelsHidden,
            areStandardSymbolLabelsHidden: areStandardSymbolLabelsHidden,
            areExtraSymbolLabelsHidden: areExtraSymbolLabelsHidden,
            longPress: longPress,
            areKeyAnimationsEnabled: areKeyAnimationsEnabled,
            isVoiceOverGestureTypingEnabled: isVoiceOverGestureTypingEnabled
        )
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let currentWidth = overrideWidth ?? viewModel.viewWidth
        // Single geometry source: the resolved metrics drive the keyboard
        // width here and the row/cell sizes in the grid, so they can never
        // desynchronize — which a second, `@AppStorage`-read source of row
        // heights would allow.
        let plan = viewModel.layoutPlan(forContainerWidth: currentWidth)
        let metrics = plan?.metrics ?? viewModel.layoutMetrics(forContainerWidth: currentWidth)
        let availableSpace = currentWidth - metrics.keyboardWidth
        let horizontalOffset = availableSpace * (viewModel.keyboardHorizontalPosition - 0.5)
        // How this frame's geometry change, if any, moves (`LayoutMotion`):
        // keys glide to their new cells, the width and offset with them.
        let signature = plan.map(KeyboardGeometrySignature.init)
        let motion = signature.flatMap { viewModel.layoutMotionClock.motion(for: $0, reduceMotion: reduceMotion) }

        ZStack {
            keyboardBackground
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let mode = viewModel.activeModeFromDefinition, let plan {
                VStack(spacing: 0) {
                    if metrics.accessoryHeight > 0 {
                        KeyboardAccessoryRow(viewModel: viewModel)
                            .frame(height: metrics.accessoryHeight)
                    }
                    KeyboardGridView(
                        arrangement: plan.arrangement,
                        keys: mode.keys,
                        onGesture: { key, gesture, isReturn in
                            viewModel.handleGesture(gesture, keyId: key.id, isReturn: isReturn)
                        },
                        engine: viewModel.touchEngine,
                        touchActions: viewModel.touchEngineActions,
                        languageLabel: viewModel.currentLanguageLabel,
                        isLanguageLabelShown: viewModel.hasMultipleLanguages,
                        renderSettings: renderSettings,
                        metrics: metrics,
                        tuning: viewModel.gestureTuning
                    )
                    // Feel hook: the grid's overlay draws the view model's board.
                    .environment(\.feelBoard, viewModel.feel.board)
                    .environment(\.showsTypedCharacters, !viewModel.fieldTraits.isSensitive)
                    .environment(\.offersCompletionAction, metrics.accessoryHeight > 0) // WORD COMPLETIONS hook
                    .padding(.horizontal, KeyboardConstants.Layout.horizontalPadding)
                    .padding(.top, KeyboardConstants.Layout.verticalPaddingTop)
                    .padding(.bottom, KeyboardConstants.Layout.verticalPaddingBottom)
                }
                .frame(width: metrics.keyboardWidth)
                .offset(x: horizontalOffset)
            }
        }
        // Scoped to the geometry: only a change of `signature` animates, so a
        // mode switch that keeps every key in place moves nothing.
        .animation(motion?.animation, value: signature)
        .frame(maxWidth: .infinity)
        // Pin the entire keyboard render tree to physical LTR. Grid slot
        // positions, the horizontalOffset math above, and the atan2 gesture
        // classification are all physical/absolute, so this cannot affect
        // layout — it only stops the directional hint alignments/paddings
        // (which use semantic leading/trailing) from mirroring under an RTL
        // system language, keeping hints aligned with the physical swipe
        // directions. A lone hint glyph is direction-agnostic, so RTL text
        // still renders correctly. (Finding #4.)
        .environment(\.layoutDirection, .leftToRight)
    }

    // MARK: - Background

    @ViewBuilder
    private var keyboardBackground: some View {
        switch keyboardStyle {
        case .classic:
            Color(.systemBackground)
        case .liquidGlass:
            // A keyboard extension's input view only delivers touches that land
            // on a rendered surface; fully transparent regions pass through. A
            // `Color.clear` root would drop taps that fall in the gaps between
            // keys, so paint a near-invisible fill instead: the whole keyboard
            // becomes a real surface that receives those touches while the keys
            // on top still win the hit-test. ~2% over the glass backdrop reads
            // as clear.
            Color(.systemBackground).opacity(0.02)
        }
    }
}
