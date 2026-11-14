//
//  KeyboardGeometry.swift
//  WurstfingerScenarioKit
//
//  Where each key sits on screen, worked out from the same pure layout code the
//  keyboard view renders with (`GridLayoutSolver`, `KeyboardLayoutMetrics`), so
//  a synthetic touch or a drawn trail can be placed on a real key.
//

import CoreGraphics
import Foundation
@testable import WurstfingerKit

@MainActor
enum KeyboardGeometry {
    struct Layout: Sendable {
        /// Size of the key grid.
        var gridSize: CGSize
        /// Where the grid's top-left corner sits in the keyboard root view.
        var gridOrigin: CGPoint
        /// Total height of the keyboard view.
        var keyboardHeight: CGFloat
        /// The drawn bounds of each key, in the grid's own coordinate space —
        /// the space `GestureTrailRecorder` records in.
        var keyFrames: [String: CGRect]

        func center(of keyId: String) -> CGPoint? {
            keyFrames[keyId].map { CGPoint(x: $0.midX, y: $0.midY) }
        }
    }

    /// Lays the view model's active mode out against `containerWidth`.
    static func layout(of viewModel: KeyboardViewModel, containerWidth: CGFloat) -> Layout? {
        guard let plan = viewModel.layoutPlan(forContainerWidth: containerWidth) else { return nil }
        let arrangement = plan.arrangement
        let metrics = plan.metrics
        let padding = KeyboardConstants.Layout.horizontalPadding
        let hSpacing = metrics.keySpacing
        let vSpacing = metrics.keySpacing

        let cells = GridLayoutSolver.solve(arrangement)
        let gridWidth = metrics.keyboardWidth - 2 * padding
        let columnWidth = (gridWidth - CGFloat(arrangement.columns - 1) * hSpacing) / CGFloat(arrangement.columns)
        let rows = cells.map { $0.row + $0.rowSpan }.max() ?? 0
        let gridHeight = CGFloat(rows) * metrics.rowHeight + CGFloat(max(rows - 1, 0)) * vSpacing

        var frames: [String: CGRect] = [:]
        for cell in cells {
            frames[cell.keyId] = CGRect(
                x: CGFloat(cell.column) * (columnWidth + hSpacing),
                y: CGFloat(cell.row) * (metrics.rowHeight + vSpacing),
                width: CGFloat(cell.columnSpan) * columnWidth + CGFloat(cell.columnSpan - 1) * hSpacing,
                height: CGFloat(cell.rowSpan) * metrics.rowHeight + CGFloat(cell.rowSpan - 1) * vSpacing
            )
        }

        // `DataDrivenKeyboardRootView` centres the keyboard and shifts it by
        // the free width times the position's offset from the middle.
        let free = containerWidth - metrics.keyboardWidth
        let originX = free / 2 + free * (viewModel.keyboardHorizontalPosition - 0.5) + padding
        return Layout(
            gridSize: CGSize(width: gridWidth, height: gridHeight),
            gridOrigin: CGPoint(x: originX, y: KeyboardConstants.Layout.verticalPaddingTop),
            keyboardHeight: metrics.totalHeight,
            keyFrames: frames
        )
    }

    static func frames(of viewModel: KeyboardViewModel, containerWidth: CGFloat) -> [String: CGRect] {
        layout(of: viewModel, containerWidth: containerWidth)?.keyFrames ?? [:]
    }
}
