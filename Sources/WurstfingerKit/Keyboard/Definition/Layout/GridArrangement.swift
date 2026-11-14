//
//  GridArrangement.swift
//  Wurstfinger
//
//  A concrete spatial arrangement of keys in a grid.
//

import Foundation

/// A concrete spatial arrangement of keys.
/// Multiple arrangements can lay out the same key pool differently.
/// Hashable so `GridLayoutSolver` can memoize solved cells per arrangement.
struct GridArrangement: Codable, Hashable, Sendable {
    /// Number of logical columns.
    /// The sum of widthMultipliers in each row (plus columns spanned by keys from
    /// previous rows via heightMultiplier) must equal this value.
    let columns: Int

    /// The placements, organized by row.
    let rows: [[KeyPlacement]]
}

// MARK: - Transformations

extension GridArrangement {
    /// Moves the placements with the given key IDs to the leading edge of their
    /// row while preserving the relative order of all other placements
    /// (utility column left ↔ right without mirroring the letter grid).
    func movingToLeading(keyIds: Set<String>) -> GridArrangement {
        GridArrangement(
            columns: columns,
            rows: rows.map { row in
                row.filter { keyIds.contains($0.keyId) } + row.filter { !keyIds.contains($0.keyId) }
            }
        )
    }

    /// Changes the column count and adjusts a specific key's width.
    func resized(columns newColumns: Int, adjusting keyId: String, toWidth newWidth: Int) -> GridArrangement {
        precondition(newColumns > 0, "newColumns must be positive")
        precondition(newWidth > 0, "newWidth must be positive")
        return GridArrangement(
            columns: newColumns,
            rows: rows.map { row in
                row.map { placement in
                    placement.keyId == keyId
                        ? KeyPlacement(keyId: keyId, widthMultiplier: newWidth, heightMultiplier: placement.heightMultiplier)
                        : placement
                }
            }
        )
    }

    /// Removes a key from all rows (e.g. for more compact layouts).
    func removing(keyId: String) -> GridArrangement {
        GridArrangement(
            columns: columns,
            rows: rows.map { $0.filter { $0.keyId != keyId } }
        )
    }
}

// MARK: - Numpad column and split

extension GridArrangement {
    /// Splits each row into its letter-region placements (the 3×3 grid, the
    /// space bar, the numeric zero) and its utility placements (globe, symbols,
    /// delete, return), keeping each group's order.
    private func regions(of row: [KeyPlacement]) -> (letters: [KeyPlacement], utility: [KeyPlacement]) {
        let utility = StandardArrangements.leadingUtilityKeys
        return (row.filter { !utility.contains($0.keyId) }, row.filter { utility.contains($0.keyId) })
    }

    /// The numpad column's placement in `row` number `index`: the key, or a
    /// one-column gap where the mode carries no numpad keys (see
    /// `addingNumpadColumn`). `nil` for a row beyond the column's four.
    private static func numpadPlacement(row index: Int, keyIds: [String]?) -> KeyPlacement? {
        guard index < NumpadColumn.keyIds.count else { return nil }
        guard let keyIds else { return .gap(columns: 1) }
        return KeyPlacement(keyId: keyIds[index])
    }

    /// Adds one column of numpad keys immediately beside the letter grid, on its
    /// leading or trailing side, one key per row (the bottom one beside the
    /// space bar). The utility column keeps the outer edge on its own side, so
    /// with utility keys trailing a trailing numpad sits *between* the letters
    /// and the utility keys, and a leading one is the keyboard's left edge.
    ///
    /// - Parameter keyIds: The numpad keys, top to bottom (`NumpadColumn.keyIds`),
    ///   or `nil` to reserve the column with a gap instead. A mode without numpad
    ///   keys (the numeric one: it is all digits already) takes the gap, so the
    ///   keyboard keeps its width and every key its place when the mode changes.
    /// - Precondition: a standard portrait-shaped arrangement, whose rows are
    ///   side by side with no row-spanning key (the runtime selects only
    ///   portrait arrangements). Rows past the fourth get no numpad key.
    func addingNumpadColumn(_ placement: NumpadColumnPlacement, keyIds: [String]?) -> GridArrangement {
        guard placement != .off else { return self }
        let newRows = rows.enumerated().map { index, row -> [KeyPlacement] in
            guard let numpad = Self.numpadPlacement(row: index, keyIds: keyIds),
                  let edge = placement == .leading
                  ? row.firstIndex(where: { !StandardArrangements.leadingUtilityKeys.contains($0.keyId) })
                  : row.lastIndex(where: { !StandardArrangements.leadingUtilityKeys.contains($0.keyId) })
            else { return row }
            var updated = row
            updated.insert(numpad, at: placement == .leading ? edge : edge + 1)
            return updated
        }
        return GridArrangement(columns: columns + 1, rows: newRows)
    }

    /// The split layout: the letter grid on one side, the utility column (and
    /// the numpad column, when there is one) on the other, and `gapColumns`
    /// empty columns between them. The utility side follows `utilityLeading`; the
    /// numpad column joins the utility keys, on the inner side of them, because
    /// that is the cluster the other thumb rests on.
    ///
    /// - Parameter numpadKeyIds: As in `addingNumpadColumn`; pass `nil` to
    ///   reserve a gap instead of keys, or leave `includesNumpad` false for no
    ///   column at all.
    func splitting(
        gapColumns: Int,
        utilityLeading: Bool,
        includesNumpad: Bool,
        numpadKeyIds: [String]?
    ) -> GridArrangement {
        let gap = KeyPlacement.gap(columns: max(gapColumns, 1))
        let newRows = rows.enumerated().map { index, row -> [KeyPlacement] in
            let (letters, utility) = regions(of: row)
            let numpad = includesNumpad
                ? Self.numpadPlacement(row: index, keyIds: numpadKeyIds).map { [$0] } ?? []
                : []
            return utilityLeading
                ? utility + numpad + [gap] + letters
                : letters + [gap] + numpad + utility
        }
        return GridArrangement(columns: columns + (includesNumpad ? 1 : 0) + max(gapColumns, 1), rows: newRows)
    }
}
