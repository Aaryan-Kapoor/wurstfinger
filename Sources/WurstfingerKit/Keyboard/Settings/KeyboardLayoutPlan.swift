//
//  KeyboardLayoutPlan.swift
//  Wurstfinger
//
//  The one place that turns the layout settings and a render context into the
//  arrangement to draw and the metrics to draw it with.
//

import CoreGraphics
import Foundation

/// Which arrangement a mode is drawn with, and the metrics resolved for it.
///
/// The arrangement and the metrics depend on each other — the numpad column and
/// the split's empty middle change the column count the width is resolved
/// against, and the split picks its gap from the key size the metrics produce —
/// so they are resolved together, here, and every consumer (the SwiftUI grid,
/// the touch engine's `GridGeometry`, the controller's height constraint, the
/// scenario harness, the settings preview) reads the same plan. That is what
/// keeps the touch frames identical to the drawn frames by construction.
struct KeyboardLayoutPlan: Equatable, Sendable {
    let arrangement: GridArrangement
    let metrics: KeyboardLayoutMetrics
    /// Whether the arrangement is the split one.
    let isSplit: Bool

    // MARK: - Split rules

    /// Narrowest container the split applies to, in points. Below this the two
    /// clusters would have no room between them to be worth separating: it keeps
    /// a floating iPad keyboard (~320 pt), Slide Over and Split View panes and
    /// the smallest landscape phones (SE: 568 pt) on the single block, while an
    /// iPad (744 pt and up) or a large phone in landscape (812 pt and up)
    /// qualifies.
    static let splitMinimumWidth: CGFloat = 700

    /// Whether the split layout is in force: the user asked for it, the
    /// container is wide enough, and the screen is in landscape. The screen
    /// rather than the container decides the orientation, because a keyboard
    /// extension's own window is only keyboard-sized (see
    /// `KeyboardViewModel.updateWindowBounds`).
    static func isSplitApplicable(isEnabled: Bool, containerWidth: CGFloat, screen: CGSize) -> Bool {
        isEnabled && containerWidth >= splitMinimumWidth && screen.width > screen.height
    }

    // MARK: - Resolution

    /// Inputs a plan is resolved from; settings snapshot plus render context.
    struct Inputs: Sendable {
        /// The mode's arrangement for the user's utility-column side.
        var base: GridArrangement
        /// Whether the mode carries the numpad column's keys.
        var hasNumpadKeys: Bool
        var numpadColumn: NumpadColumnPlacement
        var isUtilityLeading: Bool
        var isSplitEnabled: Bool
        var wishWidth: CGFloat
        var aspectRatio: CGFloat
        var spacing: CGFloat
        /// Width of the view hosting the keyboard (0 = unknown).
        var containerWidth: CGFloat
        /// The width a single block may not exceed (the screen's shortest side,
        /// or the narrower pane): see `KeyboardViewModel.keyboardWidthCap`.
        var widthCap: CGFloat
        var screen: CGSize
        /// The row above the keys, if any (`KeyboardLayoutMetrics.accessoryHeight`).
        var accessoryHeight: CGFloat = 0
    }

    static func resolve(_ inputs: Inputs) -> KeyboardLayoutPlan {
        let base = inputs.base
        let rows = base.rows.count
        let numpadKeyIds: [String]? = inputs.hasNumpadKeys ? NumpadColumn.keyIds : nil
        // A column that is switched on but whose keys the mode lacks (numeric)
        // is reserved as a gap, so the keyboard keeps its shape across modes.
        let isNumpadOn = inputs.numpadColumn.isEnabled

        if isSplitApplicable(
            isEnabled: inputs.isSplitEnabled, containerWidth: inputs.containerWidth, screen: inputs.screen
        ) {
            return resolveSplit(inputs, rows: rows, isNumpadOn: isNumpadOn, numpadKeyIds: numpadKeyIds)
        }

        let arrangement = isNumpadOn
            ? base.addingNumpadColumn(inputs.numpadColumn, keyIds: numpadKeyIds)
            : base
        let available = inputs.containerWidth > 0
            ? min(inputs.containerWidth, inputs.widthCap) : inputs.widthCap
        let metrics = KeyboardLayoutMetrics.resolve(
            wishWidth: inputs.wishWidth,
            aspectRatio: inputs.aspectRatio,
            columns: arrangement.columns,
            wishColumns: base.columns,
            rows: rows,
            availableWidth: available,
            screenHeight: inputs.screen.height,
            spacing: inputs.spacing,
            accessoryHeight: inputs.accessoryHeight
        )
        return KeyboardLayoutPlan(arrangement: arrangement, metrics: metrics, isSplit: false)
    }

    /// How much bigger a split key is than the block's. A split keyboard is
    /// typed with two thumbs on a large screen held at its sides, where each
    /// thumb covers only its own half: the keys can grow without the reach
    /// growing past the thumb, and bigger targets are what a split is for.
    static let splitKeyScale: CGFloat = 1.2

    /// The share of the container one cluster may span: a thumb resting at the
    /// edge of a landscape iPad reaches roughly this far in comfort, so keys
    /// stop growing before the inner column leaves its arc.
    static let splitClusterShare: CGFloat = 0.36

    /// The split: keys a little larger than the block's (`splitKeyScale`, never
    /// past what lets a cluster stay within `splitClusterShare` of the width,
    /// and never past the height guard), and an empty middle taking whatever
    /// width is left — a whole number of columns, so the grid stays uniform and
    /// the hit map's cell table stays exact. The column count is rounded *up*,
    /// so the cell is never larger than the one asked for (and the keyboard
    /// fills the container instead of being shrunk again), and never more than
    /// one column's worth smaller.
    private static func resolveSplit(
        _ inputs: Inputs, rows: Int, isNumpadOn: Bool, numpadKeyIds: [String]?
    ) -> KeyboardLayoutPlan {
        let base = inputs.base
        let available = inputs.containerWidth
        // The key size the single block would have: width wish against the
        // standard columns, height guard applied, no width clamp.
        let single = KeyboardLayoutMetrics.resolve(
            wishWidth: inputs.wishWidth,
            aspectRatio: inputs.aspectRatio,
            columns: base.columns,
            rows: rows,
            availableWidth: 0,
            screenHeight: inputs.screen.height,
            spacing: inputs.spacing,
            accessoryHeight: inputs.accessoryHeight
        )
        let clusterColumns = base.columns + (isNumpadOn ? 1 : 0)
        // The bigger split key, capped twice: by the thumb's reach (the
        // wider cluster — the letters, or the utility column with the numpad —
        // within its share) and by the height guard (the block's
        // height-guarded cell, scaled, may not exceed what the guard allows at
        // that aspect ratio).
        let widestCluster = max(base.columns - 1, 1 + (isNumpadOn ? 1 : 0))
        let reachCap = (available * splitClusterShare - CGFloat(widestCluster - 1) * inputs.spacing
            - KeyboardConstants.Layout.horizontalPadding) / CGFloat(widestCluster)
        let heightCapped = KeyboardLayoutMetrics.resolve(
            wishWidth: single.cellWidth * splitKeyScale * CGFloat(base.columns)
                + KeyboardLayoutMetrics.horizontalChrome(columns: base.columns, spacing: inputs.spacing),
            aspectRatio: inputs.aspectRatio,
            columns: base.columns,
            rows: rows,
            availableWidth: 0,
            screenHeight: inputs.screen.height,
            spacing: inputs.spacing,
            accessoryHeight: inputs.accessoryHeight
        )
        let cell = max(min(heightCapped.cellWidth, reachCap), single.cellWidth)
        let pitch = max(cell + inputs.spacing, 1)
        let usable = available - 2 * KeyboardConstants.Layout.horizontalPadding + inputs.spacing
        let fitting = Int((usable / pitch).rounded(.up))
        let gapColumns = max(fitting - clusterColumns, 1)

        let arrangement = base.splitting(
            gapColumns: gapColumns,
            utilityLeading: inputs.isUtilityLeading,
            includesNumpad: isNumpadOn,
            numpadKeyIds: numpadKeyIds
        )
        // The keyboard spans the container: `wishWidth` is the container, so the
        // resolver divides it across the columns (and applies the height guard,
        // which cannot bind here — see above).
        let metrics = KeyboardLayoutMetrics.resolve(
            wishWidth: available,
            aspectRatio: inputs.aspectRatio,
            columns: arrangement.columns,
            rows: rows,
            availableWidth: available,
            screenHeight: inputs.screen.height,
            spacing: inputs.spacing,
            accessoryHeight: inputs.accessoryHeight
        )
        return KeyboardLayoutPlan(arrangement: arrangement, metrics: metrics, isSplit: true)
    }
}

extension GridGeometry {
    /// The touch geometry for `cells` laid out with `metrics`: the same row
    /// height, spacing and aspect ratio the SwiftUI grid places the keys with.
    init(cells: [SolvedCell], columns: Int, metrics: KeyboardLayoutMetrics) {
        self.init(
            cells: cells,
            columns: columns,
            rowHeight: metrics.rowHeight,
            horizontalSpacing: metrics.keySpacing,
            verticalSpacing: metrics.keySpacing,
            cellAspectRatio: metrics.cellAspectRatio
        )
    }
}
