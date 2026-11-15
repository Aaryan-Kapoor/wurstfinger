//
//  HintFit.swift
//  Wurstfinger
//
//  Scales a key's hints and centre label down when their ink would not fit.
//

import CoreGraphics
import CoreText
import Foundation
import os

/// How much smaller than their normal size a key draws a hint, and its centre
/// label, so that they do not run into each other.
///
/// A key shows nine glyphs in a 3×3 arrangement, and the sizes are chosen for
/// the Latin letters, whose ink is narrower than a third of the key. Scripts
/// with wider letters (Arabic, Persian, Urdu: a letter at the hint size is
/// 16 to 20 pt in a 19 pt third) and the emoji mode's pictographs do not fit
/// the cells, and three of them in a row read as one blob. So each glyph is
/// scaled to its cell, **only when it overflows**, never below `floor`, which is
/// where a letter stops being easy to read and the layout has to give.
///
/// - **A hint** gets the third of the key it hangs in, less the padding from
///   the key's edge and half the gap to its neighbour; it shrinks about the
///   edge it hangs from, so it moves away from its neighbours, not into them.
/// - **The centre label** gets the key less what the hints around it take (as
///   scaled): the left and right ones from the sides, the upper and lower ones
///   from above and below, plus the gap.
///
/// Where ink sits matters as much as how big it is: a glyph's box has room
/// above the letters and below the baseline (a capital with an accent rises
/// past the box, a letter with a tail drops past the baseline), so the extents
/// are measured from the box edge the hint is pinned to to the far end of its
/// *ink*, in the line's own coordinates (`InkMetrics`).
///
/// The ink is measured with Core Text, not with SwiftUI, for two reasons: the
/// same number then drives the `Canvas` hints, the view-stack hints and the
/// centre label (SwiftUI can only measure inside a `Canvas`), so the renderers
/// cannot disagree; and a measurement is cached per text and size
/// (`inkSize(of:pointSize:)`), so a redraw during an emphasis animation looks
/// each glyph up instead of shaping it again. The pixel audit
/// (`EmojiInkAudit`) is the check that this model is right: it renders every
/// glyph and reads the ink back.
enum HintFit {
    /// No glyph is scaled below this.
    nonisolated static let floor: CGFloat = 0.7

    /// Room kept between two neighbouring cells, in points. It is larger than
    /// the point the audit asks for, because the model works from Core Text's
    /// boxes and the glyphs are drawn by SwiftUI's: the difference is up to
    /// about a point and a half for letters, found by running the audit.
    nonisolated static let gap: CGFloat = 2.4

    /// The same for emoji, which fill their boxes more evenly (a colour bitmap
    /// has no overhanging accent or tail to allow for), so that the model needs
    /// no more room than the audit asks.
    nonisolated static let emojiGap: CGFloat = 0.4

    nonisolated static func gap(forEmoji isEmoji: Bool) -> CGFloat { isEmoji ? emojiGap : gap }

    // MARK: - Fitting

    /// The scale of a hint on `gesture`'s edge of a key of `key`, with the
    /// padding the canvas leaves from the key's edge.
    nonisolated static func hintScale(
        metrics: InkMetrics, gesture: GestureType, key: CGSize, horizontalPadding: CGFloat, verticalPadding: CGFloat,
        gap: CGFloat = HintFit.gap
    ) -> CGFloat {
        guard metrics.inkWidth > 0, metrics.inkHeight > 0 else { return 1 }
        var scale: CGFloat = 1
        // Across: a side hint reaches from its edge to the far end of its ink;
        // a middle-column hint is centred, and its ink must fit the third.
        switch gesture.fitColumn {
        case 0, 2:
            let reach = gesture.fitColumn == 0 ? metrics.inkMaxX : metrics.advance - metrics.inkMinX
            scale = min(scale, (key.width / 3 - gap / 2 - horizontalPadding) / reach)
        default:
            scale = min(scale, (key.width / 3 - gap) / metrics.inkWidth)
        }
        switch gesture.fitRow {
        case 0:
            scale = min(scale, (key.height / 3 - gap / 2 - verticalPadding) / (metrics.ascent - metrics.inkMinY))
        case 2:
            scale = min(scale, (key.height / 3 - gap / 2 - verticalPadding) / (metrics.descent + metrics.inkMaxY))
        default:
            scale = min(scale, (key.height / 3 - gap) / metrics.inkHeight)
        }
        return settle(scale)
    }

    /// How far the ink of a hint reaches into the key from each edge it can
    /// reach in from, at `scale`: `.left`/`.right` for the side hints,
    /// `.top`/`.bottom` for the ones above and below.
    nonisolated static func reach(
        metrics: InkMetrics, gesture: GestureType, scale: CGFloat, horizontalPadding: CGFloat, verticalPadding: CGFloat
    ) -> CGSize {
        switch gesture {
        case .swipeLeft: CGSize(width: horizontalPadding + scale * metrics.inkMaxX, height: 0)
        case .swipeRight: CGSize(width: horizontalPadding + scale * (metrics.advance - metrics.inkMinX), height: 0)
        case .swipeUp: CGSize(width: 0, height: verticalPadding + scale * (metrics.ascent - metrics.inkMinY))
        case .swipeDown: CGSize(width: 0, height: verticalPadding + scale * (metrics.descent + metrics.inkMaxY))
        default: .zero
        }
    }

    /// The scale of the centre label, given how far the hints around it reach
    /// into the key (`reach`, 0 for a side with no hint).
    nonisolated static func centerScale(
        metrics: InkMetrics, key: CGSize, horizontalPadding: CGFloat, verticalPadding: CGFloat,
        left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat, gap: CGFloat = HintFit.gap
    ) -> CGFloat {
        guard metrics.inkWidth > 0, metrics.inkHeight > 0 else { return 1 }
        // The label is centred in its box: its ink reaches this far from the centre.
        let centerX = metrics.advance / 2
        let centerY = (metrics.ascent - metrics.descent) / 2
        let reachLeft = max(centerX - metrics.inkMinX, 0), reachRight = max(metrics.inkMaxX - centerX, 0)
        let above = max(metrics.inkMaxY - centerY, 0), below = max(centerY - metrics.inkMinY, 0)
        func room(_ half: CGFloat, _ taken: CGFloat, _ padding: CGFloat) -> CGFloat {
            half - (taken > 0 ? taken + gap : padding)
        }
        var scale: CGFloat = 1
        if reachLeft > 0 { scale = min(scale, room(key.width / 2, left, horizontalPadding) / reachLeft) }
        if reachRight > 0 { scale = min(scale, room(key.width / 2, right, horizontalPadding) / reachRight) }
        if above > 0 { scale = min(scale, room(key.height / 2, top, verticalPadding) / above) }
        if below > 0 { scale = min(scale, room(key.height / 2, bottom, verticalPadding) / below) }
        return settle(scale)
    }

    /// A hair under 1 is rounding, not overflow; and nothing goes below the floor.
    nonisolated private static func settle(_ scale: CGFloat) -> CGFloat {
        scale >= 0.98 ? 1 : max(scale, floor)
    }

    // MARK: - Measuring

    /// A text's line metrics and ink, in points, with x from the line's origin
    /// and y up from its baseline (Core Text's coordinates).
    struct InkMetrics: Sendable, Equatable {
        var advance: CGFloat
        var ascent: CGFloat
        var descent: CGFloat
        var inkMinX: CGFloat
        var inkMaxX: CGFloat
        var inkMinY: CGFloat
        var inkMaxY: CGFloat

        var inkWidth: CGFloat { inkMaxX - inkMinX }
        var inkHeight: CGFloat { inkMaxY - inkMinY }

        static let zero = InkMetrics(advance: 0, ascent: 0, descent: 0, inkMinX: 0, inkMaxX: 0, inkMinY: 0, inkMaxY: 0)
    }

    private struct Measured: Hashable {
        var text: String
        var pointSize: CGFloat
    }

    private static let cache = OSAllocatedUnfairLock<[Measured: InkMetrics]>(initialState: [:])

    /// Most measurements kept. A keyboard on screen shows about a hundred
    /// glyphs at two or three sizes, but a live resize (a window dragged, the
    /// size slider) asks for every glyph at a new size each frame: past this
    /// the cache starts over instead of growing with the drag.
    nonisolated static let cacheLimit = 1024

    /// `text` shaped at `pointSize` with the system font and its fallbacks.
    /// Cached per text and size.
    nonisolated static func inkMetrics(of text: String, pointSize: CGFloat) -> InkMetrics {
        let key = Measured(text: text, pointSize: pointSize)
        if let known = cache.withLock({ $0[key] }) { return known }
        let measured = measure(text, pointSize: pointSize)
        cache.withLock { cache in
            if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[key] = measured
        }
        return measured
    }

    /// Measurements cached now, for tests.
    nonisolated static var cachedCount: Int { cache.withLock { $0.count } }

    /// Drops every measurement (the keyboard shedding memory for suspension;
    /// the next draw measures again).
    nonisolated static func evictAll() {
        cache.withLock { $0.removeAll() }
    }

    nonisolated private static func measure(_ text: String, pointSize: CGFloat) -> InkMetrics {
        let font = CTFontCreateUIFontForLanguage(.system, pointSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, pointSize, nil)
        let attributes = [kCTFontAttributeName: font] as CFDictionary
        guard let string = CFAttributedStringCreate(nil, text as CFString, attributes) else { return .zero }
        let line = CTLineCreateWithAttributedString(string)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let outline = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        return InkMetrics(
            advance: advance, ascent: ascent, descent: descent,
            inkMinX: min(outline.minX, 0), inkMaxX: max(outline.maxX, advance),
            inkMinY: outline.minY, inkMaxY: outline.maxY
        )
    }
}

extension GestureType {
    /// The column of the key's 3×3 map this gesture's hint is in: 0 left, 1
    /// middle, 2 right.
    nonisolated var fitColumn: Int {
        switch self {
        case .swipeLeft, .swipeUpLeft, .swipeDownLeft: 0
        case .swipeRight, .swipeUpRight, .swipeDownRight: 2
        default: 1
        }
    }

    /// The row: 0 top, 1 middle, 2 bottom.
    nonisolated var fitRow: Int {
        switch self {
        case .swipeUp, .swipeUpLeft, .swipeUpRight: 0
        case .swipeDown, .swipeDownLeft, .swipeDownRight: 2
        default: 1
        }
    }
}
