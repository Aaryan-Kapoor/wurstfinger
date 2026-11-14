//
//  SettingsLayoutMetrics.swift
//  wurstfinger
//
//  The keyboard geometry the settings screens report and simulate.
//

import CoreGraphics

/// Resolves the stored size wish the way the settings screens present it:
/// without a render context, so the numbers are device- and
/// orientation-independent — exactly what the size slider edits.
///
/// The wish is a statement about the standard four-column block (the portrait
/// grid is kept in all orientations, see `KeyboardViewModel.currentContext`),
/// so the cell this resolves is the cell the keyboard renders — with or without
/// the numpad column, which adds a column to the width and leaves the cell as
/// it is (`KeyboardLayoutMetrics.resolve`'s `wishColumns`).
enum SettingsLayoutMetrics {
    private static let gridColumns = 4

    static func forStoredWish(width: CGFloat, aspectRatio: CGFloat) -> KeyboardLayoutMetrics {
        KeyboardLayoutMetrics.resolve(
            wishWidth: width,
            aspectRatio: aspectRatio,
            columns: gridColumns,
            availableWidth: 0,
            screenHeight: 0
        )
    }
}
