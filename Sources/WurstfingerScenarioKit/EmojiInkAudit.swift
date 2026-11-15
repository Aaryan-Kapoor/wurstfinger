//
//  EmojiInkAudit.swift
//  WurstfingerScenarioKit
//
//  Measures where every emoji of the emoji mode really puts its ink.
//

import CoreGraphics
import Foundation
import SwiftUI
@testable import WurstfingerKit

/// A pixel audit of the emoji mode's keys.
///
/// Guessing whether nine emoji fit one key does not work: a colour glyph's ink
/// is not its layout box (a hand reaches past its advance, a face is inset in
/// it), and the box is all the canvas knows. So this renders each emoji of a
/// key the way the key draws it (the real `KeyHintCanvas` for the eight hints,
/// the real centre label font for the tap), one glyph per image, at a given
/// layout, and reads the glyph's ink from the alpha channel. Then, in key
/// coordinates:
///
/// - **overflow**: any ink outside the key's visible bounds;
/// - **crowding**: any two glyphs of the key whose ink is closer than
///   `minimumGap` (1 pt by default; touching or overlapping counts), measured
///   on the pixels, not on bounding boxes, so two round faces on a diagonal
///   are not blamed for the corners of their boxes;
///
/// What it cannot see is a glyph the system's emoji font itself draws
/// incomplete (🫡 is cropped at its advance on the macOS this was written on,
/// in `NSAttributedString` drawing as much as in SwiftUI): the pixels of a
/// cropped glyph and of a complete one are equally "ink". Such a glyph is not
/// on a key face (🫡 is a return-swipe variant), and the font is the system's.
///
/// It is the evidence behind `KeyTypography.emojiHintFraction` and the per-glyph
/// rule (`HintFit`), and `EmojiInkAuditTests` pins its result.
@MainActor
enum EmojiInkAudit {
    /// Closest allowed distance between two glyphs' ink, in points.
    nonisolated static let minimumGap: CGFloat = 1

    /// How far apart the search for the closest pair looks, so a report can say
    /// how much room there is, not only that there is enough.
    nonisolated static let searchLimit: CGFloat = 3

    /// Pixels per point of the audit's renders. Four keeps the 1 pt gap at four
    /// pixels, far from the antialiasing fringe (`alphaThreshold`).
    nonisolated static let scale: CGFloat = 4

    /// An alpha below this is the antialiased fringe, not ink.
    nonisolated static let alphaThreshold: UInt8 = 24

    struct Finding: Hashable, CustomStringConvertible {
        enum Kind: Hashable { case overflow(points: Int), crowded(with: String, gapTenths: Int) }
        var key: String
        var page: String
        var tone: EmojiSkinTone
        var glyph: String
        var slot: String
        var kind: Kind

        var description: String {
            let place = "\(page)/\(key) \(slot) \(glyph)" + (tone == .none ? "" : " (\(tone))")
            switch kind {
            case let .overflow(points): return "\(place) overflows the key by \(Double(points) / 10) pt"
            case let .crowded(other, tenths): return "\(place) is \(Double(tenths) / 10) pt from \(other)"
            }
        }
    }

    struct Report {
        var keySize: CGSize
        var glyphsMeasured = 0
        /// Glyphs whose render came out blank: a broken audit, not a clean key.
        var blank = 0
        var blankGlyphs: Set<String> = []
        /// Glyph renders done (the rest came from the cache).
        var renders = 0
        var keysChecked = 0
        var findings: [Finding] = []
        /// The smallest gap between two glyphs of a key anywhere, in points
        /// (capped at what was searched), and the worst overflow.
        var smallestGap: CGFloat = .infinity
        var worstOverflow: CGFloat = 0
    }

    /// One glyph's ink in key coordinates, as a bit mask at `scale`, with what
    /// the checks need worked out once: the ink's pixel bounds, its outline
    /// (the only pixels that can be nearest to anything), and how far it
    /// reaches outside the key.
    fileprivate struct Ink {
        var width: Int
        var height: Int
        /// Key-space point of pixel (0, 0).
        var origin: CGPoint
        var bits: [Bool]
        var bounds: CGRect?
        var outline: [(x: Int, y: Int)]
        var overflow: CGFloat

        init(width: Int, height: Int, origin: CGPoint, bits: [Bool], key: CGSize) {
            self.width = width
            self.height = height
            self.origin = origin
            self.bits = bits
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            var outline: [(x: Int, y: Int)] = []
            var worst: CGFloat = 0
            bits.withUnsafeBufferPointer { b in
                for y in 0 ..< height {
                    for x in 0 ..< width where b[y * width + x] {
                        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                        let inside = x > 0 && y > 0 && x < width - 1 && y < height - 1
                            && b[y * width + x - 1] && b[y * width + x + 1]
                            && b[(y - 1) * width + x] && b[(y + 1) * width + x]
                        if !inside { outline.append((x, y)) }
                    }
                }
            }
            if maxX >= 0 {
                self.bounds = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
                let left = origin.x + CGFloat(minX) / EmojiInkAudit.scale
                let right = origin.x + CGFloat(maxX + 1) / EmojiInkAudit.scale
                let top = origin.y + CGFloat(minY) / EmojiInkAudit.scale
                let bottom = origin.y + CGFloat(maxY + 1) / EmojiInkAudit.scale
                worst = max(max(-left, right - key.width), max(-top, bottom - key.height))
            } else {
                self.bounds = nil
            }
            self.outline = outline
            self.overflow = max(worst, 0)
        }
    }

    // MARK: - Running it

    /// Audits both pages of the emoji mode at `metrics`, in `tones`.
    ///
    /// The recent key is audited with the seed's emoji, since its content is
    /// whatever was typed (any emoji of the map is a possible entry, and each
    /// one is audited in its own key).
    static func run(
        metrics: KeyboardLayoutMetrics, tones: [EmojiSkinTone] = EmojiSkinTone.allCases, minimumGap: CGFloat = minimumGap,
        keys only: Set<String>? = nil
    ) -> Report {
        var audit = Audit(metrics: metrics, minimumGap: minimumGap)
        for tone in tones {
            let modes = EmojiLayouts.modes(tone: tone)
            for page in [ModeNames.emoji, ModeNames.emojiMore] {
                guard let mode = modes[page] else { continue }
                var keyIds = GridSlot.allSlots.flatMap(\.self)
                if tone == tones.first { keyIds.append(GridSlot.recent) } // its content has no tone
                for keyId in keyIds where only?.contains(keyId) ?? true {
                    guard let definition = mode.keys[keyId] else { continue }
                    audit.add(definition, page: page, tone: tone)
                }
            }
        }
        return audit.finish()
    }

    /// Audits the letter keys of `modes` (the lowercase letters by default) of
    /// every layout in `definitions`, at `metrics`. A key whose glyphs are the
    /// ones of a key already checked at the same place is not rendered again,
    /// so the layouts that share most of their letters cost little.
    static func run(
        layouts definitions: [KeyboardDefinition], modes: [String] = [ModeNames.main],
        metrics: KeyboardLayoutMetrics, minimumGap: CGFloat = minimumGap
    ) -> Report {
        var audit = Audit(metrics: metrics, minimumGap: minimumGap)
        var seen = Set<String>()
        for definition in definitions {
            for name in modes {
                guard let mode = definition.mode(name) else { continue }
                for keyId in GridSlot.allSlots.flatMap(\.self) {
                    guard let key = mode.keys[keyId] else { continue }
                    let fingerprint = keyId + "|" + EmojiInkAudit.fingerprint(of: key)
                    guard seen.insert(fingerprint).inserted else { continue }
                    audit.add(key, page: "\(definition.id)/\(name)", tone: .none)
                }
            }
        }
        return audit.finish()
    }

    /// What decides how a key draws: its tap and the text of every hint.
    fileprivate static func fingerprint(of key: KeyDefinition) -> String {
        let hints = KeyView.hintGestureOrder.map { key.bindings[$0]?.label ?? "" }
        return (key.bindings[.tap]?.label ?? "") + "|" + hints.joined(separator: "|")
    }

    /// One glyph to render, as a key draws it: a hint at a slot, or the centre
    /// letter at the scale `KeyView.centerFit` gave it (in thousandths).
    fileprivate enum Spec: Hashable {
        case hint(slot: Int, content: KeyHintCanvas.Hint.Content)
        case center(label: String, fitMilli: Int)
    }

    /// One audit in progress. Keys are `add`ed, which only plans what to
    /// render; `finish` renders every distinct glyph once, in batches (one
    /// `ImageRenderer` pass costs about as much for a hundred glyphs as for
    /// one), then checks each key.
    @MainActor private struct Audit {
        struct Cell {
            var slot: String
            var glyph: String
            var spec: Spec
        }

        struct Planned {
            var key: String
            var page: String
            var tone: EmojiSkinTone
            var cells: [Cell]
        }

        let typography: KeyTypography
        let key: CGSize
        let minimumGap: CGFloat
        var planned: [Planned] = []

        init(metrics: KeyboardLayoutMetrics, minimumGap: CGFloat) {
            typography = KeyTypography(metrics: metrics)
            key = CGSize(width: metrics.cellWidth, height: metrics.cellHeight)
            self.minimumGap = minimumGap
        }

        mutating func add(_ definition: KeyDefinition, page: String, tone: EmojiSkinTone) {
            // The cells: the hints that are text or emoji (an icon is not what
            // overflows) and the tap, each as the key draws it.
            var cells: [Cell] = []
            for (slot, gesture) in KeyView.hintGestureOrder.enumerated() {
                guard let binding = definition.bindings[gesture], !binding.label.isEmpty,
                      KeyView.hintIcon(for: binding.action) == nil, binding.action != .switchToNextLanguage
                else { continue }
                let content: KeyHintCanvas.Hint.Content = EmojiText.isEmoji(binding.label)
                    ? .emoji(binding.label)
                    : .text(binding.label, isLetter: binding.label.first?.isLetter ?? false)
                cells.append(Cell(slot: gesture.rawValue, glyph: binding.label, spec: .hint(slot: slot, content: content)))
            }
            if let tap = definition.bindings[.tap], !tap.label.isEmpty, definition.style == .primary {
                let fit = KeyView.centerFit(key: definition, typography: typography, isLabelVisible: { _ in true })
                cells.append(Cell(slot: "tap", glyph: tap.label, spec: .center(label: tap.label, fitMilli: Int(fit * 1000))))
            }
            planned.append(Planned(key: definition.id, page: page, tone: tone, cells: cells))
        }

        func finish() -> Report {
            var report = Report(keySize: key)
            let specs = Array(Set(planned.flatMap { $0.cells.map(\.spec) }))
            var inks: [Spec: Ink] = [:]
            for start in stride(from: 0, to: specs.count, by: EmojiInkAudit.batchSize) {
                let batch = Array(specs[start ..< min(start + EmojiInkAudit.batchSize, specs.count)])
                for (spec, ink) in zip(batch, EmojiInkAudit.render(batch, typography: typography, key: key)) { inks[spec] = ink }
                report.renders += batch.count
            }
            for item in planned {
                let cells = item.cells.map { ($0, inks[$0.spec]!) }
                report.keysChecked += 1
                report.glyphsMeasured += cells.count
                let blanks = cells.filter { $0.1.bounds == nil }
                report.blank += blanks.count
                report.blankGlyphs.formUnion(blanks.map(\.0.glyph))

                for (cell, ink) in cells {
                    report.worstOverflow = max(report.worstOverflow, ink.overflow)
                    if ink.overflow > 0.05 {
                        report.findings.append(Finding(
                            key: item.key, page: item.page, tone: item.tone, glyph: cell.glyph, slot: cell.slot,
                            kind: .overflow(points: Int((ink.overflow * 10).rounded()))
                        ))
                    }
                }
                for first in cells.indices {
                    for second in cells.indices where second > first {
                        let gap = EmojiInkAudit.distance(cells[first].1, cells[second].1, limit: EmojiInkAudit.searchLimit)
                        report.smallestGap = min(report.smallestGap, gap)
                        if gap < minimumGap {
                            report.findings.append(Finding(
                                key: item.key, page: item.page, tone: item.tone,
                                glyph: cells[first].0.glyph, slot: cells[first].0.slot,
                                kind: .crowded(
                                    with: "\(cells[second].0.glyph) (\(cells[second].0.slot))", gapTenths: Int((gap * 10).rounded())
                                )
                            ))
                        }
                    }
                }
            }
            return report
        }
    }

    // MARK: - Rendering

    /// Margin around the key in the render, so ink past the edge is seen.
    private static let margin: CGFloat = 6

    /// Glyphs per `ImageRenderer` pass.
    private static let batchSize = 48
    private static let batchColumns = 8

    /// Renders `specs`, each in its own key-sized cell of one image, and reads
    /// every cell's ink back.
    fileprivate static func render(_ specs: [Spec], typography: KeyTypography, key: CGSize) -> [Ink] {
        let cell = CGSize(width: key.width + 2 * margin, height: key.height + 2 * margin)
        func view(_ spec: Spec) -> AnyView {
            switch spec {
            case let .hint(slot, content):
                AnyView(KeyHintCanvas(hints: [.init(slot: slot, content: content)], typography: typography, emphasis: .rest)
                    .frame(width: key.width, height: key.height))
            case let .center(label, fitMilli):
                AnyView(Text(label).font(EmojiText.isEmoji(label) ? typography.centerEmoji : typography.label(for: .primary))
                    .lineLimit(1)
                    .scaleEffect(CGFloat(fitMilli) / 1000)
                    .frame(width: key.width, height: key.height))
            }
        }
        let columns = batchColumns
        let rows = (specs.count + columns - 1) / columns
        let sheet = VStack(spacing: 0) {
            ForEach(0 ..< rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0 ..< columns, id: \.self) { column in
                        let index = row * columns + column
                        Group {
                            if index < specs.count { view(specs[index]) } else { Color.clear }
                        }
                        .frame(width: cell.width, height: cell.height)
                    }
                }
            }
        }
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = scale
        guard let image = renderer.cgImage else {
            return specs.map { _ in Ink(width: 0, height: 0, origin: .zero, bits: [], key: key) }
        }
        let pixels = CGSize(width: cell.width * scale, height: cell.height * scale)
        return specs.indices.map { index in
            let rect = CGRect(
                x: CGFloat(index % columns) * pixels.width, y: CGFloat(index / columns) * pixels.height,
                width: pixels.width, height: pixels.height
            )
            guard let part = image.cropping(to: rect) else {
                return Ink(width: 0, height: 0, origin: .zero, bits: [], key: key)
            }
            return mask(of: part, origin: CGPoint(x: -margin, y: -margin), key: key)
        }
    }

    fileprivate static func mask(of image: CGImage, origin: CGPoint, key: CGSize) -> Ink {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var bits = [Bool](repeating: false, count: width * height)
        for index in 0 ..< width * height where pixels[index * 4 + 3] > alphaThreshold {
            bits[index] = true
        }
        return Ink(width: width, height: height, origin: origin, bits: bits, key: key)
    }

    // MARK: - Geometry

    /// The distance between two glyphs' ink in points, or `limit` when it is at
    /// least that (searching no further). Exact to a pixel: it grows a disc
    /// around every outline pixel of `first` and looks for `second`'s ink.
    fileprivate static func distance(_ first: Ink, _ second: Ink, limit: CGFloat) -> CGFloat {
        guard first.width == second.width, first.height == second.height,
              let firstBounds = first.bounds, let secondBounds = second.bounds,
              firstBounds.insetBy(dx: -limit * scale, dy: -limit * scale).intersects(secondBounds)
        else { return limit }
        let radius = Int((limit * scale).rounded(.up))
        let extents = (-radius ... radius).map { Int(Double(radius * radius - $0 * $0).squareRoot()) }
        let width = second.width, height = second.height
        var best = radius * radius + 1 // squared pixels
        second.bits.withUnsafeBufferPointer { bits in
            for (x, y) in first.outline {
                for dy in -radius ... radius {
                    let ny = y + dy
                    guard ny >= 0, ny < height else { continue }
                    let reach = extents[dy + radius]
                    for dx in -reach ... reach {
                        let nx = x + dx
                        if nx >= 0, nx < width, bits[ny * width + nx] { best = min(best, dx * dx + dy * dy) }
                    }
                }
            }
        }
        return best > radius * radius ? limit : CGFloat(Double(best).squareRoot()) / scale
    }
}
