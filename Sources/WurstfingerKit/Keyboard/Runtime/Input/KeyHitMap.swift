//
//  KeyHitMap.swift
//  Wurstfinger
//
//  Which key is under a point, answered in constant time.
//

import CoreGraphics

/// The touch geometry of one laid-out key grid: every key's touch frame, and
/// a dense column × row table that turns a point into a key without searching.
///
/// **Why a table.** The input engine asks "which key?" once per touch-down,
/// for every finger, on the main thread between the touch event and the key
/// lighting up. The grid is uniform — equal column pitch, equal row pitch,
/// with spans covering whole cells — so the cell under a point is two
/// divisions, and the key in that cell is one array read. No frame is
/// compared, nothing allocates.
///
/// The touch frames are `KeyboardGridLayout.cellFrames`, the same frames the
/// layout places the keys in: they reach to the middle of each inter-key gap,
/// so the table's cells tile the grid with no dead strip between keys. A point
/// outside the grid is clamped to the nearest edge cell, so a touch that lands
/// in the keyboard's outer padding still belongs to the key beside it.
struct KeyHitMap: Sendable, Equatable {
    /// One entry per laid-out key, in `GridLayoutSolver` order.
    struct Key: Sendable, Equatable {
        let id: String
        /// The touch frame, in the grid's coordinate space.
        let frame: CGRect
        /// Width over height of the key as drawn, which the classifier uses to
        /// normalize swipe angles (a span of 2×1 is twice as wide).
        let aspectRatio: CGFloat
        /// The key's drawn size (spans and the gaps inside them included), the
        /// unit long swipes are measured in.
        let size: CGSize
    }

    let keys: [Key]
    let size: CGSize
    /// Key id → index into `keys`. The feel layer asks for a key's frame by
    /// id on every release and slide latch; a scan of the keys was fine for
    /// tests but not on that path.
    private let indexByID: [String: Int]

    private let columns: Int
    private let rows: Int
    private let columnPitch: CGFloat
    private let rowPitch: CGFloat
    private let horizontalSpacing: CGFloat
    private let verticalSpacing: CGFloat
    /// `rows * columns` entries, row-major: the index into `keys` of the key
    /// covering that grid cell, or -1 where no key is placed.
    private let cellToKey: [Int32]

    static let empty = KeyHitMap(
        cells: [], columns: 0, size: .zero, rowHeight: 0,
        horizontalSpacing: 0, verticalSpacing: 0, cellAspectRatio: 1
    )

    /// - Parameters:
    ///   - cells: The solved arrangement (`GridLayoutSolver.solve`).
    ///   - columns: The arrangement's column count.
    ///   - size: The grid's laid-out size (its bounds in its own space).
    ///   - rowHeight / spacings: As passed to `KeyboardGridLayout`.
    ///   - cellAspectRatio: `KeyboardLayoutMetrics.cellAspectRatio`, the
    ///     drawn aspect ratio of a 1×1 key.
    init(
        cells: [SolvedCell],
        columns: Int,
        size: CGSize,
        rowHeight: CGFloat,
        horizontalSpacing: CGFloat,
        verticalSpacing: CGFloat,
        cellAspectRatio: CGFloat
    ) {
        let rows = cells.map { $0.row + $0.rowSpan }.max() ?? 0
        let frames = KeyboardGridLayout.cellFrames(
            cells: cells,
            columns: columns,
            bounds: CGRect(origin: .zero, size: size),
            rowHeight: rowHeight,
            horizontalSpacing: horizontalSpacing,
            verticalSpacing: verticalSpacing
        )
        let columnWidth = columns > 0
            ? max((size.width - CGFloat(columns - 1) * horizontalSpacing) / CGFloat(columns), 0)
            : 0
        keys = zip(cells, frames).map { cell, frame in
            Key(
                id: cell.keyId,
                frame: frame,
                aspectRatio: cellAspectRatio * CGFloat(cell.columnSpan) / CGFloat(max(cell.rowSpan, 1)),
                size: CGSize(
                    width: CGFloat(cell.columnSpan) * columnWidth + CGFloat(cell.columnSpan - 1) * horizontalSpacing,
                    height: CGFloat(cell.rowSpan) * rowHeight + CGFloat(cell.rowSpan - 1) * verticalSpacing
                )
            )
        }
        self.size = size
        self.columns = columns
        self.rows = rows
        indexByID = Dictionary(keys.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
        columnPitch = columnWidth + horizontalSpacing
        rowPitch = rowHeight + verticalSpacing

        var table = [Int32](repeating: -1, count: rows * columns)
        for (index, cell) in cells.enumerated() {
            for row in cell.row ..< min(cell.row + cell.rowSpan, rows) {
                for column in cell.column ..< min(cell.column + cell.columnSpan, columns) {
                    table[row * columns + column] = Int32(index)
                }
            }
        }
        cellToKey = table
    }

    /// The key whose touch frame contains `point` (grid coordinates), clamping
    /// points outside the grid to the nearest edge cell. `nil` only for an
    /// empty grid or a cell no key covers.
    func key(at point: CGPoint) -> Key? {
        guard let index = keyIndex(at: point) else { return nil }
        return keys[index]
    }

    /// Index into `keys` for `point`; see `key(at:)`.
    func keyIndex(at point: CGPoint) -> Int? {
        guard columns > 0, rows > 0, columnPitch > 0, rowPitch > 0 else { return nil }
        // A touch frame starts half a gap before its key, so shifting by half
        // a gap makes each pitch-wide band exactly one column's touch frame.
        let column = Self.band(point.x + horizontalSpacing / 2, pitch: columnPitch, count: columns)
        let row = Self.band(point.y + verticalSpacing / 2, pitch: rowPitch, count: rows)
        let index = cellToKey[row * columns + column]
        return index >= 0 ? Int(index) : nil
    }

    /// The key with `id`, if it is laid out in this grid.
    func key(withId id: String) -> Key? {
        indexByID[id].map { keys[$0] }
    }

    private static func band(_ value: CGFloat, pitch: CGFloat, count: Int) -> Int {
        let raw = (value / pitch).rounded(.down)
        guard raw.isFinite else { return 0 }
        return min(max(Int(raw), 0), count - 1)
    }
}
