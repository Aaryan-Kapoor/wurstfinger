//
//  EmojiInkAuditTests.swift
//  WurstfingerKitTests
//
//  Pins what `EmojiInkAudit` measures about the emoji keys: every emoji's real
//  ink, rendered the way the key draws it, stays inside its key and keeps
//  clear of the other eight on it. Run `swift run WurstfingerSnapshots
//  --emoji-audit` for the same numbers at five key sizes (all six tones: pass
//  `tones: EmojiSkinTone.allCases` to `EmojiInkAudit.run`; it takes about a minute
//  in a debug build, too long for the suite).
//

import CoreGraphics
import Testing
@testable import WurstfingerKit
@testable import WurstfingerScenarioKit

@MainActor
struct EmojiInkAuditTests {
    /// The keys with the widest glyphs, the hands and the recent key: the other
    /// sizes are audited on these, the whole map by the command line tool.
    private static let sampleKeys: Set<String> = [GridSlot.topRight, GridSlot.center, GridSlot.bottomRight, GridSlot.recent]

    private func metrics(keyboardWidth: Double) -> KeyboardLayoutMetrics {
        KeyboardScenario(
            language: "en_US", containerWidth: 1366, settings: [.keyboardWidthPoints: keyboardWidth]
        ).metrics
    }

    /// The phone keys (the iPhone SE and every other phone at the default
    /// width are 57.75 pt): no glyph reaches outside its key, and no two on a
    /// key are closer than 1.5 pt, a half point more than the 1 pt asked for.
    @Test func everyEmojiOfEveryKeyKeepsClearAtThePhoneKeySize() {
        let phone = metrics(keyboardWidth: 270)
        #expect(abs(phone.cellWidth - 57.75) < 0.5, "the audit's key is the phone's")
        let report = EmojiInkAudit.run(metrics: phone, tones: [.none, .dark], minimumGap: 1.5)
        #expect(report.blank == 0, "a blank render would make the audit pass for nothing")
        #expect(report.keysChecked == 38, "both pages, nine keys and the recent key, in the default and the darkest tone's hands")
        #expect(report.glyphsMeasured == 342)
        #expect(report.worstOverflow < 0.05)
        #expect(report.findings.isEmpty, "\(report.findings.map(\.description).sorted())")
        #expect(report.smallestGap >= 1.5)
    }

    /// The iPad's keys are 85 pt: the emoji grow with the key (a fraction of
    /// it), so the picture is the same there, with the centre larger as well.
    @Test func theSamePictureHoldsAtTheIPadKeySize() {
        let report = EmojiInkAudit.run(metrics: metrics(keyboardWidth: 380), tones: [.none], keys: Self.sampleKeys)
        #expect(report.keySize.width > 80)
        #expect(report.keysChecked == 8)
        #expect(report.findings.isEmpty, "\(report.findings.map(\.description).sorted())")
        #expect(report.smallestGap >= 2.5)
    }

    /// The smallest keys a user can ask for are smaller than the phone's, so
    /// they have less room in points: 1 pt is still kept, and nothing leaves
    /// the key (to within the antialiased edge).
    @Test func smallKeysKeepAPointAndStayInside() {
        let report = EmojiInkAudit.run(metrics: metrics(keyboardWidth: 200), tones: [.none], keys: Self.sampleKeys)
        #expect(report.keySize.width < 45)
        // A corner emoji's soft edge can reach a quarter point past a 40 pt key.
        #expect(report.worstOverflow < 0.5)
        let crowded = report.findings.filter { if case .crowded = $0.kind { true } else { false } }
        #expect(crowded.isEmpty, "\(crowded.map(\.description).sorted())")
    }

    /// The audit can fail: on keys far too small for nine emoji it says so.
    @Test func theAuditSeesACrowdedKey() {
        let report = EmojiInkAudit.run(metrics: metrics(keyboardWidth: 90), tones: [.none], keys: [GridSlot.center])
        #expect(report.keySize.width < 25)
        #expect(!report.findings.isEmpty)
    }

    /// The size is a fraction of the key at every size, so the centre stays
    /// the larger glyph (the iPad used to flatten it against the hints).
    @Test func theCentreIsAlwaysLargerThanTheHints() {
        for width in [90.0, 200, 270, 380, 520] {
            let m = metrics(keyboardWidth: width)
            let cell = min(m.cellWidth, m.cellHeight)
            #expect(cell * KeyTypography.emojiCenterFraction > cell * KeyTypography.emojiHintFraction * 1.4, "\(width)")
        }
    }

    // MARK: - Every layout's letters

    /// The letter keys of every shipped layout, lowercase, at the phone key
    /// size: every hint and the centre letter of each key stays inside the key
    /// and a point clear of the others, except where a glyph is already at its
    /// floor (`HintFit.floor`) and the layout simply has too much on the key.
    ///
    /// The one such case today is the Tagalog full layout's `↓` hint under the
    /// descender of `g`. The list of exceptions is exactly that, so a layout
    /// that starts crowding fails here, and so does one that stops (remove it).
    @Test func everyLayoutsLettersKeepClearAtThePhoneKeySize() {
        let definitions = KeyboardRegistry.available.compactMap { KeyboardRegistry.load(id: $0.id) }
        #expect(definitions.count == KeyboardRegistry.available.count)
        let report = EmojiInkAudit.run(layouts: definitions, metrics: metrics(keyboardWidth: 270))
        #expect(report.keySize.width > 57 && report.keySize.width < 58)
        #expect(report.keysChecked > 250, "the layouts' keys were audited")
        // A lone combining mark has no area and is never drawn (see KeyHintCanvas).
        #expect(report.blankGlyphs.allSatisfy { $0.unicodeScalars.allSatisfy { $0.properties.generalCategory == .nonspacingMark } },
                "\(report.blankGlyphs.sorted())")
        #expect(report.worstOverflow < 0.05)
        let unexpected = report.findings.filter { !Self.knownFloorBound.contains($0.description) }
        #expect(unexpected.isEmpty, "\(unexpected.map(\.description).sorted())")
        #expect(report.findings.count == Self.knownFloorBound.count, "a known case no longer crowds: remove it")
    }

    private static let knownFloorBound: Set<String> = [
        "tl_PH_full/main/bottomRight swipeDown ↓ is 0.8 pt from g (tap)",
    ]
}

struct HintFitCacheTests {
    /// A live resize measures every glyph at a new size each frame: the cache
    /// starts over at its limit rather than growing with the drag.
    @Test func aResizeDoesNotGrowTheCacheWithoutBound() {
        for step in 0 ..< HintFit.cacheLimit * 2 {
            _ = HintFit.inkMetrics(of: "ش", pointSize: 10 + CGFloat(step) * 0.01)
        }
        #expect(HintFit.cachedCount <= HintFit.cacheLimit)
    }

    @Test func aMeasurementIsTheSameFromTheCache() {
        let first = HintFit.inkMetrics(of: "ضخپ", pointSize: 17.25)
        #expect(HintFit.inkMetrics(of: "ضخپ", pointSize: 17.25) == first)
        HintFit.evictAll()
        #expect(HintFit.inkMetrics(of: "ضخپ", pointSize: 17.25) == first, "measured again, the same")
    }
}
