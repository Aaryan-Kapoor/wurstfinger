//
//  KeyboardGridView.swift
//  Wurstfinger
//
//  Generic SwiftUI grid renderer for any GridArrangement + key pool.
//

import SwiftUI

/// Generic grid renderer for a `GridArrangement` and key pool.
///
/// Uses `GridLayoutSolver` to resolve the arrangement into absolutely
/// positioned cells and `KeyboardGridLayout` to place them, so keys can span
/// multiple columns **and** rows (e.g. the landscape return key with
/// `heightMultiplier == 2`). Width/height multipliers map directly onto the
/// cell's column/row span, without hardcoding any positions.
struct KeyboardGridView: View {
    let arrangement: GridArrangement
    let keys: [String: KeyDefinition]
    /// Performs a gesture directly; the keys' VoiceOver custom actions use it.
    let onGesture: (KeyDefinition, GestureType, Bool) -> Void

    /// The input engine every touch on this grid goes to, and the callbacks it
    /// dispatches into (both owned by the view model).
    let engine: TouchEngine
    let touchActions: TouchEngineActions
    /// Active-language hint for the switch key, supplied by `KeyboardViewModel`
    /// so it reflects the loaded definition rather than re-derived storage.
    var languageLabel: String = ""
    var isLanguageLabelShown: Bool = false

    /// Render settings snapshot forwarded to every `KeyView`, read once in
    /// `DataDrivenKeyboardRootView` (see `KeyRenderSettings`). Undefaulted
    /// like `metrics`: the snapshot must come from the one observing read
    /// site, so a missing injection is a build error rather than a keyboard
    /// that silently ignores the user's label-visibility and long-press
    /// settings.
    let renderSettings: KeyRenderSettings

    /// Resolved layout metrics injected by `DataDrivenKeyboardRootView` from
    /// the view model rather than read via `@AppStorage`: the root view
    /// derives the keyboard *width* from the same metrics, and reading the
    /// settings from a second source desynchronizes width and row height
    /// whenever the view model is configured programmatically (screenshot and
    /// showcase modes with `shouldPersistSettings: false`).
    let metrics: KeyboardLayoutMetrics

    /// The user's resolved gesture settings, forwarded to every `KeyView`.
    /// Undefaulted for the same reason as `renderSettings` and `metrics`.
    let tuning: GestureTuning

    /// A recorder a headless host supplies to draw a trail it feeds itself
    /// (see `SnapshotHooks.swift`); nil in the app.
    @Environment(\.gestureTrailRecorderOverride) private var injectedTrail

    /// Hosts without a real screen (the snapshot tool) cannot render a native
    /// view, so they switch the touch surface off and drive the engine
    /// directly (see `SnapshotHooks.swift`).
    @Environment(\.isTouchSurfaceEnabled) private var isTouchSurfaceEnabled

    /// The feel layer's transient visuals (commit pops, long-press ring,
    /// slide ratchet), if the host has a view model to supply them.
    @Environment(\.feelBoard) private var feelBoard

    private var gestureTrail: GestureTrailRecorder {
        injectedTrail ?? engine.trail
    }

    var body: some View {
        let cells = GridLayoutSolver.solve(arrangement)
        let totalRows = cells.reduce(0) { max($0, $1.row + $1.rowSpan) }
        // One set of fonts for the whole grid (see `KeyTypography`).
        let typography = KeyTypography(metrics: metrics)
        // The grid's own size, computed rather than measured: the width is the
        // keyboard minus its padding (what the root frames this view to) and
        // the height is what `KeyboardGridLayout.sizeThatFits` reports. The
        // guide overlay places its card inside these bounds without a
        // `GeometryReader` between it and the grid.
        let gridSize = metrics.gridSize(rows: totalRows)
        KeyboardGridLayout(
            cells: cells,
            columns: arrangement.columns,
            rowHeight: metrics.rowHeight,
            horizontalSpacing: metrics.keySpacing,
            verticalSpacing: metrics.keySpacing
        ) {
            // Identity by slot id: the same slot in the next mode is the same
            // view, updated rather than rebuilt, which is what makes a mode
            // switch a diff of ~40 keys instead of a teardown and rebuild.
            ForEach(cells, id: \.keyId) { cell in
                cellContent(for: cell, totalRows: totalRows, typography: typography)
            }
        }
        // Registered here rather than on the root view so it exists wherever a
        // key is rendered — showcase, screenshot and preview hosts included —
        // and so the recorded points land in exactly the bounds the overlay
        // below draws in, with no padding or offset math to keep in sync.
        .coordinateSpace(GestureTrailRecorder.coordinateSpace)
        // Tells the recorder the trail setting from the settings snapshot, so
        // a touch-down never has to read it from the store. `initial: true`
        // delivers it before the first touch.
        .onChange(of: tuning.isTrailEnabled, initial: true) { _, isEnabled in
            gestureTrail.useEnabledSetting(isEnabled)
        }
        .overlay {
            GestureTrailOverlay(
                recorder: gestureTrail,
                headWidth: GestureTrailOverlay.headWidth(for: metrics)
            )
        }
        // Feel hook: pops, the long-press ring and the slide ratchet, between
        // the trail and the guide card.
        .overlay {
            if let feelBoard, renderSettings.areKeyAnimationsEnabled {
                FeelOverlay(board: feelBoard)
            }
        }
        .overlay {
            TouchGuideOverlay(press: engine.press, keys: keys, gridSize: gridSize)
        }
        // Topmost, so it receives every touch on the grid: one native view for
        // all fingers instead of a gesture per key (see `TouchEngine`).
        .overlay {
            if isTouchSurfaceEnabled {
                TouchSurface(engine: engine, configuration: TouchSurfaceConfiguration(
                    geometry: GridGeometry(cells: cells, columns: arrangement.columns, metrics: metrics),
                    keys: keys,
                    tuning: tuning,
                    isLongPressEnabled: renderSettings.isLongPressDigitEnabled,
                    actions: touchActions
                ))
                .accessibilityHidden(true)
            }
        }
        // For the overlays above, which outline a key inside its touch frame.
        .environment(\.keyGridSpacing, metrics.keySpacing)
    }

    @ViewBuilder
    private func cellContent(for cell: SolvedCell, totalRows: Int, typography: KeyTypography) -> some View {
        if let key = keys[cell.keyId] {
            KeyView(
                key: key,
                onGesture: onGesture,
                pressCell: engine.press.cell(for: key.id),
                visualInset: visualInset(for: cell, totalRows: totalRows),
                settings: renderSettings,
                metrics: metrics,
                typography: typography,
                languageLabel: languageLabel,
                isLanguageLabelShown: isLanguageLabelShown
            )
            // Skip the body when nothing the key draws changed (see
            // `KeyView`'s `Equatable` conformance).
            .equatable()
        } else {
            Color.clear
        }
    }

    /// Inset that keeps the key's drawn bounds unchanged while its touch cell
    /// fills the gaps to neighbouring keys. Mirrors `KeyboardGridLayout`, which
    /// grows the cell frame by the same amount.
    private func visualInset(for cell: SolvedCell, totalRows: Int) -> EdgeInsets {
        let insets = KeyboardGridLayout.gapInsets(
            for: cell,
            columns: arrangement.columns,
            totalRows: totalRows,
            horizontalSpacing: metrics.keySpacing,
            verticalSpacing: metrics.keySpacing
        )
        return EdgeInsets(
            top: insets.top,
            leading: insets.leading,
            bottom: insets.bottom,
            trailing: insets.trailing
        )
    }

    // MARK: - Span Inspection (Test Hooks)

    /// Returns the `(rows, columns)` grid span for a placement. Pure function
    /// so the spanning behavior can be unit tested without introspecting the
    /// rendered SwiftUI tree.
    static func gridCellSpan(for placement: KeyPlacement) -> (rows: Int, columns: Int) {
        (placement.heightMultiplier, placement.widthMultiplier)
    }
}
