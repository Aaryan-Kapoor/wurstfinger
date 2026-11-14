//
//  KeyHitMapLayoutTests.swift
//  WurstfingerTests
//
//  The touch geometry for every layout the settings can produce — key spacing
//  from none to the widest, the numpad column on either side, and the split's
//  empty middle: the touch frames tile the keyboard with no dead strip between
//  keys, the hit map answers exactly what the frames say, and the empty middle
//  maps to "no key" without taking touches from the keys beside it.
//

import CoreGraphics
import Foundation
import Testing
@testable import WurstfingerKit

/// One layout the settings can produce, with the geometry the engine and the
/// grid are both built from.
private struct LayoutCase: CustomTestStringConvertible {
    var name: String
    var plan: KeyboardLayoutPlan

    var testDescription: String { name }

    var cells: [SolvedCell] { GridLayoutSolver.solve(plan.arrangement) }
    var rows: Int { cells.map { $0.row + $0.rowSpan }.max() ?? 0 }
    var size: CGSize { plan.metrics.gridSize(rows: rows) }
    var geometry: GridGeometry { GridGeometry(cells: cells, columns: plan.arrangement.columns, metrics: plan.metrics) }
    var hitMap: KeyHitMap { KeyHitMap(geometry: geometry, size: size) }

    /// The drawn frames, from the same function the SwiftUI layout places with.
    var frames: [CGRect] {
        KeyboardGridLayout.cellFrames(
            cells: cells, columns: plan.arrangement.columns,
            bounds: CGRect(origin: .zero, size: size),
            rowHeight: plan.metrics.rowHeight,
            horizontalSpacing: plan.metrics.keySpacing, verticalSpacing: plan.metrics.keySpacing
        )
    }

    static func make(
        _ name: String, spacing: CGFloat = 5, numpad: NumpadColumnPlacement = .off,
        utilityLeading: Bool = false, split: Bool = false, container: CGFloat = 393,
        screen: CGSize = CGSize(width: 393, height: 852), numeric: Bool = false
    ) -> LayoutCase {
        let table = numeric ? StandardArrangements.numeric3x3 : StandardArrangements.grid3x3
        let plan = KeyboardLayoutPlan.resolve(KeyboardLayoutPlan.Inputs(
            base: table[utilityLeading ? .portraitUtilityLeft : .portrait]!,
            hasNumpadKeys: !numeric,
            numpadColumn: numpad, isUtilityLeading: utilityLeading, isSplitEnabled: split,
            wishWidth: container > 700 ? 380 : 270, aspectRatio: 1.0, spacing: spacing,
            containerWidth: container, widthCap: min(container, min(screen.width, screen.height)),
            screen: screen
        ))
        return LayoutCase(name: name, plan: plan)
    }

    static let landscape = CGSize(width: 1366, height: 1024)

    static let all: [LayoutCase] = {
        var cases: [LayoutCase] = []
        for spacing in [CGFloat(0), 5, 12] {
            let tag = "spacing \(Int(spacing))"
            cases.append(make("block, \(tag)", spacing: spacing))
            for placement in [NumpadColumnPlacement.leading, .trailing] {
                for utilityLeading in [false, true] {
                    cases.append(make(
                        "numpad \(placement.rawValue), utility \(utilityLeading ? "left" : "right"), \(tag)",
                        spacing: spacing, numpad: placement, utilityLeading: utilityLeading
                    ))
                }
            }
            cases.append(make("numeric with reserved column, \(tag)", spacing: spacing, numpad: .trailing, numeric: true))
            cases.append(make(
                "split, \(tag)", spacing: spacing, split: true, container: 1366, screen: landscape
            ))
            cases.append(make(
                "split with numpad, \(tag)", spacing: spacing, numpad: .trailing, split: true,
                container: 1366, screen: landscape
            ))
            cases.append(make(
                "split with numpad, utility left, \(tag)", spacing: spacing, numpad: .trailing,
                utilityLeading: true, split: true, container: 1366, screen: landscape
            ))
            cases.append(make(
                "split on a landscape phone, \(tag)", spacing: spacing, numpad: .leading, split: true,
                container: 852, screen: CGSize(width: 852, height: 393)
            ))
        }
        return cases
    }()
}

struct KeyHitMapLayoutTests {
    /// Whether `point` is strictly inside `frame` (not on an edge, where two
    /// frames meet and either answer is right).
    private func isInside(_ point: CGPoint, _ frame: CGRect, margin: CGFloat = 0.01) -> Bool {
        point.x > frame.minX + margin && point.x < frame.maxX - margin
            && point.y > frame.minY + margin && point.y < frame.maxY - margin
    }

    @Test(arguments: LayoutCase.all)
    private func theTouchFramesNeverOverlap(_ layout: LayoutCase) {
        let frames = layout.frames
        for i in frames.indices {
            for j in (i + 1) ..< frames.count {
                let overlap = frames[i].intersection(frames[j])
                #expect(
                    overlap.isNull || overlap.width < 0.001 || overlap.height < 0.001,
                    "\(layout.name): \(layout.cells[i].keyId) overlaps \(layout.cells[j].keyId)"
                )
            }
        }
    }

    /// Frames cover the surface except the empty columns: their areas sum to
    /// the bounds minus the gap rectangle (zero for a plain block).
    @Test(arguments: LayoutCase.all)
    private func theTouchFramesTileEverythingExceptTheGap(_ layout: LayoutCase) {
        let frames = layout.frames
        let bounds = CGRect(origin: .zero, size: layout.size)
        let covered = frames.reduce(0) { $0 + $1.width * $1.height }
        let gap = gapRect(of: layout)
        let expected = bounds.width * bounds.height - (gap?.width ?? 0) * (gap?.height ?? 0)
        #expect(abs(covered - expected) < 1, "\(layout.name): frames cover \(covered), expected \(expected)")
    }

    /// The empty rectangle in a layout with empty columns (the split's middle, or
    /// the numeric mode's reserved numpad column), or nil: from
    /// the right edge of the keys before the first empty column to the left edge
    /// of the keys after the last one.
    private func gapRect(of layout: LayoutCase) -> CGRect? {
        let cells = layout.cells
        let occupied = Set(cells.flatMap { Array($0.column ..< $0.column + $0.columnSpan) })
        let empty = (0 ..< layout.plan.arrangement.columns).filter { !occupied.contains($0) }
        guard let first = empty.first, let last = empty.last else { return nil }
        let before = zip(cells, layout.frames).filter { $0.0.column + $0.0.columnSpan == first }.map(\.1.maxX)
        let after = zip(cells, layout.frames).filter { $0.0.column == last + 1 }.map(\.1.minX)
        guard let start = before.max(), let end = after.min() else { return nil }
        return CGRect(x: start, y: 0, width: end - start, height: layout.size.height)
    }

    @Test(arguments: LayoutCase.all)
    private func theMapAnswersWhatTheFramesSay(_ layout: LayoutCase) {
        let map = layout.hitMap
        let frames = layout.frames
        let size = layout.size
        // A dense scan, including points on the sub-point boundaries.
        var checked = 0
        for x in stride(from: CGFloat(0.3), to: size.width, by: 7.3) {
            for y in stride(from: CGFloat(0.3), to: size.height, by: 5.9) {
                let point = CGPoint(x: x, y: y)
                let owner = frames.indices.first { isInside(point, frames[$0]) }
                let hit = map.key(at: point)
                if let owner {
                    #expect(hit?.id == layout.cells[owner].keyId, "\(layout.name) at \(point)")
                } else if frames.allSatisfy({ !$0.insetBy(dx: -0.01, dy: -0.01).contains(point) }) {
                    #expect(hit == nil, "\(layout.name): a dead point hit \(hit?.id ?? "-") at \(point)")
                }
                checked += 1
            }
        }
        #expect(checked > 100)
    }

    @Test(arguments: LayoutCase.all)
    private func everyKeyIsHitAtItsCentreAndItsFrameCorners(_ layout: LayoutCase) {
        let map = layout.hitMap
        for (cell, frame) in zip(layout.cells, layout.frames) {
            #expect(map.key(at: CGPoint(x: frame.midX, y: frame.midY))?.id == cell.keyId, "\(layout.name): \(cell.keyId)")
            for corner in [
                CGPoint(x: frame.minX + 0.5, y: frame.minY + 0.5),
                CGPoint(x: frame.maxX - 0.5, y: frame.minY + 0.5),
                CGPoint(x: frame.minX + 0.5, y: frame.maxY - 0.5),
                CGPoint(x: frame.maxX - 0.5, y: frame.maxY - 0.5),
            ] {
                #expect(map.key(at: corner)?.id == cell.keyId, "\(layout.name): corner of \(cell.keyId)")
            }
        }
    }

    @Test(arguments: LayoutCase.all)
    private func aBlockHasNoPointThatHitsNothing(_ layout: LayoutCase) {
        guard !layout.plan.isSplit else { return }
        let map = layout.hitMap
        let size = layout.size
        // Numeric mode reserves a column for the numpad: a gap in a block too.
        let reservesAGap = layout.name.contains("reserved")
        for x in stride(from: CGFloat(0.2), to: size.width, by: 3.7) {
            for y in stride(from: CGFloat(0.2), to: size.height, by: 3.1) {
                if map.key(at: CGPoint(x: x, y: y)) == nil {
                    #expect(reservesAGap, "\(layout.name): dead point at (\(x), \(y))")
                }
            }
        }
    }

    // MARK: Spacing extremes

    @Test func atNoSpacingTheKeysTouchAndTheBoundaryIsTheEdge() throws {
        let layout = LayoutCase.make("tight", spacing: 0)
        let map = layout.hitMap
        let a = try #require(map.key(withId: GridSlot.topLeft))
        let b = try #require(map.key(withId: GridSlot.topCenter))
        #expect(a.frame.maxX == b.frame.minX)
        #expect(map.key(at: CGPoint(x: a.frame.maxX - 0.01, y: a.frame.midY))?.id == GridSlot.topLeft)
        #expect(map.key(at: CGPoint(x: a.frame.maxX + 0.01, y: a.frame.midY))?.id == GridSlot.topCenter)
    }

    @Test func atTheWidestSpacingTheBoundaryIsTheMiddleOfTheGap() throws {
        let layout = LayoutCase.make("loose", spacing: 12)
        let map = layout.hitMap
        let a = try #require(map.key(withId: GridSlot.topLeft))
        let b = try #require(map.key(withId: GridSlot.topCenter))
        // Touch frames meet in the middle of the 12 pt gap.
        #expect(abs(a.frame.maxX - b.frame.minX) < 0.001)
        let boundary = a.frame.maxX
        #expect(map.key(at: CGPoint(x: boundary - 0.05, y: a.frame.midY))?.id == GridSlot.topLeft)
        #expect(map.key(at: CGPoint(x: boundary + 0.05, y: a.frame.midY))?.id == GridSlot.topCenter)
        // The drawn key ends 6 pt before that boundary.
        let drawn = FeelGeometry.visibleKeyRect(touchFrame: a.frame, in: layout.size, spacing: 12)
        #expect(abs(boundary - drawn.maxX - 6) < 0.001)
        // Vertically too: a touch in the gap between two rows belongs to one of them.
        let below = try #require(map.key(withId: GridSlot.midLeft))
        let rowBoundary = a.frame.maxY
        #expect(abs(rowBoundary - below.frame.minY) < 0.001)
        #expect(map.key(at: CGPoint(x: a.frame.midX, y: rowBoundary - 0.05))?.id == GridSlot.topLeft)
        #expect(map.key(at: CGPoint(x: a.frame.midX, y: rowBoundary + 0.05))?.id == GridSlot.midLeft)
    }

    @Test func spacingDoesNotMoveTheKeyboardsOuterEdges() throws {
        for spacing in [CGFloat(0), 12] {
            let layout = LayoutCase.make("edges", spacing: spacing)
            let map = layout.hitMap
            let first = try #require(map.key(withId: GridSlot.topLeft))
            #expect(first.frame.minX == 0)
            #expect(first.frame.minY == 0)
            let last = try #require(map.key(withId: UtilitySlot.return))
            #expect(abs(last.frame.maxX - layout.size.width) < 0.001)
            #expect(abs(last.frame.maxY - layout.size.height) < 0.001)
        }
    }

    // MARK: Numpad column

    @Test(arguments: [NumpadColumnPlacement.leading, .trailing])
    private func aNumpadKeyIsAnOrdinaryOneByOneKey(_ placement: NumpadColumnPlacement) throws {
        let layout = LayoutCase.make("numpad", numpad: placement)
        let map = layout.hitMap
        for id in NumpadColumn.keyIds {
            let key = try #require(map.key(withId: id))
            #expect(abs(key.size.width - layout.plan.metrics.cellWidth) < 0.001)
            #expect(abs(key.aspectRatio - layout.plan.metrics.cellAspectRatio) < 0.001)
        }
        // The bottom numpad key sits beside the space bar, not in the utility column.
        let bottom = try #require(map.key(withId: NumpadColumn.keyIds[3]))
        let space = try #require(map.key(withId: UtilitySlot.space))
        #expect(abs(bottom.frame.minY - space.frame.minY) < 0.001)
        #expect(bottom.frame.minX == space.frame.maxX || bottom.frame.maxX == space.frame.minX)
    }

    // MARK: Split

    @Test func theSplitsEmptyMiddleHitsNothing() throws {
        let layout = LayoutCase.make(
            "split", numpad: .trailing, split: true, container: 1366, screen: LayoutCase.landscape
        )
        let map = layout.hitMap
        let top = try #require(map.key(withId: GridSlot.topRight))
        let numpad = try #require(map.key(withId: NumpadColumn.keyIds[0]))
        let mid = (top.frame.maxX + numpad.frame.minX) / 2
        for y in stride(from: CGFloat(3), to: layout.size.height, by: 17) {
            #expect(map.key(at: CGPoint(x: mid, y: y)) == nil)
            #expect(map.key(at: CGPoint(x: top.frame.maxX + 2, y: y)) == nil)
            #expect(map.key(at: CGPoint(x: numpad.frame.minX - 2, y: y)) == nil)
        }
    }

    @Test func theKeysBesideTheGapKeepTheirFullTouchFrames() throws {
        let layout = LayoutCase.make(
            "split", numpad: .trailing, split: true, container: 1366, screen: LayoutCase.landscape
        )
        let map = layout.hitMap
        let top = try #require(map.key(withId: GridSlot.topRight))
        let numpad = try #require(map.key(withId: NumpadColumn.keyIds[0]))
        // Just inside each frame's edge facing the gap.
        #expect(map.key(at: CGPoint(x: top.frame.maxX - 0.1, y: top.frame.midY))?.id == GridSlot.topRight)
        #expect(map.key(at: CGPoint(x: numpad.frame.minX + 0.1, y: numpad.frame.midY))?.id == NumpadColumn.keyIds[0])
        // And the keys' own frames are exactly the ones the layout draws in.
        #expect(top.frame == layout.frames[try #require(layout.cells.firstIndex { $0.keyId == GridSlot.topRight })])
    }

    @Test func theSplitCreatesNoKeysThatDoNotExist() {
        let layout = LayoutCase.make(
            "split", numpad: .trailing, split: true, container: 1366, screen: LayoutCase.landscape
        )
        let plain = LayoutCase.make("plain", numpad: .trailing)
        #expect(Set(layout.hitMap.keys.map(\.id)) == Set(plain.hitMap.keys.map(\.id)))
        #expect(!layout.hitMap.keys.contains { $0.id == KeyPlacement.gapKeyId })
    }

    @Test func touchesOutsideTheSplitClampToTheEdgeKeysNotToTheGap() throws {
        let layout = LayoutCase.make(
            "split", split: true, container: 1366, screen: LayoutCase.landscape
        )
        let map = layout.hitMap
        #expect(map.key(at: CGPoint(x: -30, y: -30))?.id == GridSlot.topLeft)
        #expect(map.key(at: CGPoint(x: layout.size.width + 30, y: 5))?.id == UtilitySlot.globe)
    }
}
