//
//  CostModel.swift
//  WurstfingerLayoutLab
//
//  The Fitts-law cost of typing one character after another on the real key
//  geometry. A port of `scripts/layout-science/model.py` (one-thumb, primary
//  constants); `CostModelTests` holds the two to the same numbers. Every
//  constant is documented in docs/layout-science.md.
//


import Foundation
@testable import WurstfingerKit

/// A place a character can be typed from: a key of the 3x3 grid (0...8, row
/// major) or the space bar (9), and the gesture on it.
struct LabSlot: Hashable, Comparable {
    var key: Int
    var gesture: GestureType

    static let space = LabSlot(key: 9, gesture: .tap)

    static func < (lhs: LabSlot, rhs: LabSlot) -> Bool {
        (lhs.key, lhs.gesture.rawValue) < (rhs.key, rhs.gesture.rawValue)
    }

    /// The grid slot name (`GridSlot.topLeft` ...) of a grid key.
    var keyName: String { GridSlot.allSlots.joined().map { $0 }[key] }
}

/// Every tunable constant of the model, with the primary values.
struct CostModelParameters: Equatable {
    /// Keyboard width in points (iPhone 15 portrait).
    var width: Double = 393
    /// Cell aspect ratio, width over height (`DeviceLayout.defaultKeyAspectRatio`).
    var aspect: Double = 1.0
    /// Swipe target distance from the key centre, as a share of the cell: the
    /// hint's place in the key's 3x3 sub-grid.
    var hintFraction: Double = 1.0 / 3.0
    /// Shortest path the classifier counts as a swipe, in points.
    var minSwipeLength: Double = Double(GestureClassificationThresholds.defaultMinSwipeLength)
    /// Same-key re-aim floor: the ID of a re-aim of `repeatFloor` key widths.
    var repeatFloor: Double = 0.5
}

/// Geometry and per-transition costs.
struct CostModel {
    let parameters: CostModelParameters
    let cellWidth: Double
    let cellHeight: Double
    /// Key centres of the nine grid keys and the space bar.
    let centres: [(x: Double, y: Double)]
    /// Key sizes (the space bar is three cells wide).
    let sizes: [(width: Double, height: Double)]

    init(_ parameters: CostModelParameters = CostModelParameters()) {
        self.parameters = parameters
        let padding = Double(KeyboardConstants.Layout.horizontalPadding)
        let spacingX = Double(KeyboardConstants.Layout.gridHorizontalSpacing)
        let spacingY = Double(KeyboardConstants.Layout.gridVerticalSpacing)
        let top = Double(KeyboardConstants.Layout.verticalPaddingTop)
        let columns = 4.0
        // The same resolution `KeyboardLayoutMetrics.resolve` does (width
        // fit-clamp only, no height guard).
        let chrome = padding * 2 + spacingX * (columns - 1)
        cellWidth = max((parameters.width - chrome) / columns, 1)
        cellHeight = cellWidth / parameters.aspect
        let pitchX = cellWidth + spacingX
        let pitchY = cellHeight + spacingY
        var centres: [(Double, Double)] = []
        for row in 0 ..< 3 {
            for column in 0 ..< 3 {
                centres.append((
                    padding + cellWidth / 2 + Double(column) * pitchX,
                    top + cellHeight / 2 + Double(row) * pitchY
                ))
            }
        }
        let spaceWidth = 3 * cellWidth + 2 * spacingX
        centres.append((padding + spaceWidth / 2, top + cellHeight / 2 + 3 * pitchY))
        self.centres = centres
        sizes = Array(repeating: (cellWidth, cellHeight), count: 9) + [(spaceWidth, cellHeight)]
    }

    private static let vectors: [GestureType: (Double, Double)] = [
        .swipeUp: (0, -1), .swipeDown: (0, 1), .swipeLeft: (-1, 0), .swipeRight: (1, 0),
        .swipeUpLeft: (-1, -1), .swipeUpRight: (1, -1), .swipeDownLeft: (-1, 1), .swipeDownRight: (1, 1),
    ]

    /// Where the thumb ends a gesture relative to the key centre: the hint's
    /// position, lengthened to the classifier's minimum swipe if closer.
    func endOffset(_ gesture: GestureType) -> (x: Double, y: Double) {
        guard let (ux, uy) = Self.vectors[gesture] else { return (0, 0) }
        var ox = ux * cellWidth * parameters.hintFraction
        var oy = uy * cellHeight * parameters.hintFraction
        let amplitude = hypot(ox, oy)
        if amplitude < parameters.minSwipeLength {
            let factor = parameters.minSwipeLength / amplitude
            ox *= factor
            oy *= factor
        }
        return (ox, oy)
    }

    /// Shannon-form index of difficulty in bits.
    static func fittsID(distance: Double, width: Double) -> Double {
        log2(distance / width + 1)
    }

    /// The swipe as a second constrained movement, in bits; a tap is 0.
    func strokeBits(_ gesture: GestureType) -> Double {
        guard gesture != .tap else { return 0 }
        let offset = endOffset(gesture)
        let amplitude = hypot(offset.x, offset.y)
        let tolerance = min(cellWidth, cellHeight) * parameters.hintFraction
        return Self.fittsID(distance: amplitude, width: tolerance)
    }

    private func floorBits(key: Int) -> Double {
        let size = min(sizes[key].width, sizes[key].height)
        return Self.fittsID(distance: parameters.repeatFloor * size, width: size)
    }

    /// Cost in bits of typing `next` right after `previous` with one thumb:
    /// pointing from where the previous gesture ended to the next key, the
    /// same-key repeat floor, and the next gesture's stroke.
    func transitionBits(from previous: LabSlot, to next: LabSlot) -> Double {
        let start = centres[previous.key]
        let end = endOffset(previous.gesture)
        let target = centres[next.key]
        let dx = target.x - (start.x + end.x)
        let dy = target.y - (start.y + end.y)
        let distance = hypot(dx, dy)
        let width = min(sizes[next.key].width, sizes[next.key].height)
        let pointing = distance < 1e-9 ? 0 : Self.fittsID(distance: distance, width: width)
        let stroke = strokeBits(next.gesture)
        if previous.key == next.key {
            return max(pointing, floorBits(key: next.key)) + stroke
        }
        return pointing + stroke
    }

    /// Straight-line travel in points between the end of `previous` and the next key.
    func travel(from previous: LabSlot, to next: LabSlot) -> Double {
        let start = centres[previous.key]
        let end = endOffset(previous.gesture)
        let target = centres[next.key]
        return hypot(target.x - (start.x + end.x), target.y - (start.y + end.y))
    }
}
