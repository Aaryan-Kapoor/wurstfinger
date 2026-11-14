//
//  KeyboardLayoutMetrics.swift
//  Wurstfinger
//
//  Single source of truth for the keyboard's rendered geometry.
//
//  The persisted settings are a *wish* (keyboard width in points + key aspect
//  ratio); this type resolves them into the *result* for a concrete render
//  context (container width, current screen height). The resolution is a pure
//  function: fit-clamps may shrink the result, but the wish is never written
//  back to the store — moving to a bigger device restores the wish.
//

import CoreGraphics
import Foundation

/// Resolved keyboard geometry derived from the persisted wish
/// (`keyboardWidthPoints`, `keyAspectRatio`) and the render context.
///
/// All consumers — the SwiftUI grid, `KeyView` fonts, gesture classification,
/// and the controller's height constraint — read from the same instance, so
/// width, row height, and total height cannot desynchronize by construction.
struct KeyboardLayoutMetrics: Equatable, Sendable {
    /// Resolved outer keyboard width in points, including the keyboard's own
    /// horizontal paddings (`Layout.horizontalPadding` on each side).
    let keyboardWidth: CGFloat
    /// Width of a single 1×1 grid cell.
    let cellWidth: CGFloat
    /// Height of a single 1×1 grid cell. Exactly `cellWidth / aspectRatio`.
    let cellHeight: CGFloat
    /// Grid columns the width was resolved against.
    let columns: Int
    /// Grid rows the height was resolved against.
    let rows: Int
    /// The gap between neighbouring keys, in points, both across and down: the
    /// "Key Spacing" setting, clamped. Part of the metrics (not read from the
    /// constants) so the drawn layout, the touch frames, the hit map and the
    /// guide card all use the one value the rows and the height were resolved
    /// with.
    var keySpacing: CGFloat = KeyboardConstants.Layout.defaultKeySpacing
    /// Height of the row above the keys (e.g. word completions), 0 when there
    /// is none. Part of `totalHeight` and of the height guard, so the keys
    /// shrink to make room rather than the keyboard outgrowing the screen.
    var accessoryHeight: CGFloat = 0

    /// Height of a single grid row (identical to the cell height; rows are
    /// sized from the cells, not the other way around).
    var rowHeight: CGFloat {
        cellHeight
    }

    /// Cell aspect ratio (width/height) as actually rendered. Feeds gesture
    /// classification so swipe geometry always matches the visible keys.
    var cellAspectRatio: CGFloat {
        cellHeight > 0 ? cellWidth / cellHeight : 1
    }

    /// Font/hint scale factor for `KeyView`, relative to the reference key
    /// height at which the font size constants are defined (54 pt).
    var fontScale: CGFloat {
        cellHeight / KeyboardConstants.KeyDimensions.height
    }

    /// Total keyboard height: rows plus the constant inter-row spacing and
    /// vertical paddings. This is both the SwiftUI content height and the
    /// controller's height-constraint value — identical by construction.
    var totalHeight: CGFloat {
        cellHeight * CGFloat(rows) + Self.verticalChrome(rows: rows, spacing: keySpacing) + accessoryHeight
    }

    /// Absolute floor for the height cap, as a share of the *screen* height:
    /// the keyboard may always occupy at least this fraction regardless of the
    /// reserved band below. The extension's own window is only keyboard-sized,
    /// so the height guard must be evaluated against screen bounds, never
    /// window bounds.
    static let maxScreenHeightFraction: CGFloat = 0.70

    /// Fixed band of screen height reserved for the host document above the
    /// keyboard (Option C). On tall screens this lets the keyboard grow to
    /// `screenHeight - minReservedScreenHeight` — larger than the 0.70 floor —
    /// so a large wish stays orientation-invariant instead of being shrunk in
    /// landscape purely because the screen got shorter. On the shortest
    /// landscapes the 0.70 floor governs (see `resolve`).
    static let minReservedScreenHeight: CGFloat = 120

    /// Smallest cell either fit-clamp may produce. `cellAspectRatio`,
    /// `fontScale` and the gesture geometry all divide by the cell, so a
    /// degenerate render context must still yield a strictly positive one.
    static let minCellSize: CGFloat = 1

    /// Reference metrics at the iPhone default wish (270 pt, square cells)
    /// with no fit-clamp engaged. For tests and previews that need a valid
    /// geometry without a render context.
    static let reference = resolve(
        wishWidth: 270,
        aspectRatio: 1.0,
        columns: 4,
        availableWidth: 270,
        screenHeight: 0
    )

    /// Resolves the persisted wish into concrete metrics for a render context.
    ///
    /// - Parameters:
    ///   - wishWidth: Persisted keyboard width wish in points (device- and
    ///     orientation-independent).
    ///   - aspectRatio: Persisted cell aspect ratio (width/height).
    ///   - columns: Columns of the active arrangement.
    ///   - wishColumns: The columns `wishWidth` was asked for, when they differ
    ///     from `columns` (see below). Defaults to `columns`.
    ///   - rows: Rows of the keyboard (letters + space row).
    ///   - availableWidth: Actual container width (view width capped by the
    ///     hosting window). The keyboard's own 12 pt horizontal paddings are
    ///     part of `wishWidth`, so they double as the minimal side margin.
    ///   - screenHeight: Screen height in the *current* orientation for the
    ///     height guard. Pass `0` to skip the guard (unknown context).
    ///   - spacing: Gap between keys (`LayoutSettings.keySpacing`).
    ///   - accessoryHeight: The row above the keys (`accessoryHeight`).
    ///
    /// **Extra columns grow the keyboard; they do not shrink the keys.** The
    /// width wish is a statement about the standard four-column keyboard, so
    /// the key size it implies is `(wish - chrome) / wishColumns`. An arrangement
    /// with more columns (the numpad column makes five) keeps that key size and
    /// is wider by the extra columns — flick distances and muscle memory do not
    /// change when a column is switched on. Only if the result does not fit
    /// `availableWidth` do the keys shrink, exactly as the plain wish does.
    static func resolve(
        wishWidth: CGFloat,
        aspectRatio: CGFloat,
        columns: Int,
        wishColumns: Int? = nil,
        rows: Int = KeyboardConstants.KeyDimensions.totalRows,
        availableWidth: CGFloat,
        screenHeight: CGFloat,
        spacing: CGFloat = KeyboardConstants.Layout.defaultKeySpacing,
        accessoryHeight: CGFloat = 0
    ) -> KeyboardLayoutMetrics {
        let columns = max(columns, 1)
        let spacing = (spacing.isFinite && spacing >= 0) ? spacing : KeyboardConstants.Layout.defaultKeySpacing
        let rows = max(rows, 1)
        // Harden against corrupt stored values: a zero/non-finite aspect
        // ratio must not propagate NaN into the render tree.
        let aspect = (aspectRatio.isFinite && aspectRatio > 0) ? aspectRatio : 1.0
        let wish = (wishWidth.isFinite && wishWidth > 0) ? wishWidth : 270

        // The width the wish asks for at this column count: the wish itself
        // for the standard grid, the wish plus the extra columns' worth of
        // keys otherwise (see above).
        let wishColumns = max(wishColumns ?? columns, 1)
        let desiredWidth: CGFloat
        if wishColumns == columns {
            desiredWidth = wish
        } else {
            let desiredCell = max(
                (wish - Self.horizontalChrome(columns: wishColumns, spacing: spacing)) / CGFloat(wishColumns),
                Self.minCellSize
            )
            desiredWidth = desiredCell * CGFloat(columns) + Self.horizontalChrome(columns: columns, spacing: spacing)
        }

        // Width fit-clamp: the wish may exceed the hosting container
        // (smaller device, Slide Over pane). Render smaller, never persist.
        var width = availableWidth > 0 ? min(desiredWidth, availableWidth) : desiredWidth

        let horizontalChrome = Self.horizontalChrome(columns: columns, spacing: spacing)
        var cellWidth = max((width - horizontalChrome) / CGFloat(columns), Self.minCellSize)
        var cellHeight = cellWidth / aspect

        // Height guard (Option C — clamp only on genuine overflow): the cap is
        // whichever is *more* generous of a fixed reserved band
        // (`screenHeight - minReservedScreenHeight`) or the 0.70 floor. Taking
        // the max keeps invariance for every wish that fits within
        // `screenHeight - reserve`, and only shrinks on true landscape
        // overflow. When it does shrink, the cells scale proportionally —
        // spacing and paddings are constants — so the aspect ratio is
        // preserved exactly.
        //
        // Shortest-landscape caveat: on the shortest landscapes the reserved
        // band drops below the 0.70 floor (screenHeight ≲ 400 ⇒
        // screenHeight - 120 < 0.70·screenHeight), so the floor governs and
        // the very largest wishes still clamp there — Option C cannot make
        // them invariant without letting the keyboard exceed the screen.
        let accessoryHeight = (accessoryHeight.isFinite && accessoryHeight > 0) ? accessoryHeight : 0
        // The accessory row is constant chrome too: it never scales.
        let verticalChrome = Self.verticalChrome(rows: rows, spacing: spacing) + accessoryHeight
        if screenHeight > 0 {
            let maxHeight = max(
                screenHeight - Self.minReservedScreenHeight,
                screenHeight * Self.maxScreenHeightFraction
            )
            let contentHeight = cellHeight * CGFloat(rows) + verticalChrome
            if contentHeight > maxHeight {
                // Both axes take the same factor, so the aspect ratio survives
                // exactly. Floored at the scale that still leaves a cell of
                // `minCellSize`: for a small-positive screen height the cap
                // falls below the constant chrome, and an unfloored scale of
                // zero would hand the render tree zero-size cells.
                let scale = max(
                    (maxHeight - verticalChrome) / (cellHeight * CGFloat(rows)),
                    Self.minCellSize / cellHeight
                )
                cellWidth *= scale
                cellHeight *= scale
                width = cellWidth * CGFloat(columns) + horizontalChrome
            }
        }

        return KeyboardLayoutMetrics(
            keyboardWidth: width,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            columns: columns,
            rows: rows,
            keySpacing: spacing,
            accessoryHeight: accessoryHeight
        )
    }

    /// Constant horizontal space around/between the cells: outer paddings
    /// plus inter-column gaps. Never scaled.
    static func horizontalChrome(
        columns: Int, spacing: CGFloat = KeyboardConstants.Layout.defaultKeySpacing
    ) -> CGFloat {
        KeyboardConstants.Layout.horizontalPadding * 2 + spacing * CGFloat(max(columns, 1) - 1)
    }

    /// Constant vertical space around/between the rows: top/bottom paddings
    /// plus inter-row gaps. Never scaled.
    static func verticalChrome(
        rows: Int, spacing: CGFloat = KeyboardConstants.Layout.defaultKeySpacing
    ) -> CGFloat {
        KeyboardConstants.Layout.verticalPaddingTop +
            KeyboardConstants.Layout.verticalPaddingBottom +
            spacing * CGFloat(max(rows, 1) - 1)
    }

    /// The grid's own size inside the keyboard's paddings: what the root frames
    /// the grid to, and what the guide card and the hit map are laid out in.
    /// `rows` is the arrangement's row count (spans included).
    func gridSize(rows gridRows: Int) -> CGSize {
        CGSize(
            width: keyboardWidth - 2 * KeyboardConstants.Layout.horizontalPadding,
            height: CGFloat(gridRows) * rowHeight + CGFloat(max(gridRows - 1, 0)) * keySpacing
        )
    }
}
