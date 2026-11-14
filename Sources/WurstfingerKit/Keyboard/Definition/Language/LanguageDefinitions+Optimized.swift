//
//  LanguageDefinitions+Optimized.swift
//  Wurstfinger
//
//  The English layout whose letters were placed from measurement.
//

import Foundation

extension LanguageDefinitions {
    // MARK: English (Optimized)

    /// English with four letters moved, chosen by a search over a published
    /// letter and bigram table and a Fitts-law cost model of the real key
    /// geometry — the way Dvorak argued his layout from digraph statistics. The
    /// MessagEase English layout (`english`) stays the default; this is a
    /// second, selectable one.
    ///
    /// **What is and is not different from `english`.** `a h l z` swapped
    /// places and nothing else: `l` is the top-left tap, `a` the middle-left
    /// tap, `h` swiped right on the bottom-centre key, `z` swiped down on the
    /// top-centre key. Every punctuation mark, symbol, dead key and utility
    /// gesture sits where it does on every other layout, because the search
    /// was restricted to the 26 letter slots MessagEase English uses (nine taps
    /// and 17 swipes), and each key's tap letter is the most frequent of the
    /// nine on it, so the glyph the eye sees large stays the commonest one.
    ///
    /// **Why four, not all.** The unconstrained optimum moves 25 of 26 letters
    /// for a 4.6 % lower modelled cost, and that gain does not survive a change
    /// of thumb model. Four moves buy 40 % of it (1.85 %), are the best gain per
    /// moved letter, match the exhaustive optimum for four moves, and keep
    /// their gain in 99 % of 400 perturbed models. MessagEase English is
    /// within a few percent of the model optimum, and `docs/layout-science.md`
    /// says so plainly, with the numbers, the constants and the limits.
    ///
    /// The grid below is the `optimized_layout_k4.json` that
    /// `python3 -I scripts/layout-science/optimize.py` writes;
    /// `OptimizedLayoutTests` pins it to the letters declared here.
    static let englishOptimized = LanguageDescriptor(
        id: "en_US_optimized",
        title: String(localized: "English (Optimized)"),
        localeIdentifier: "en_US",
        family: .optimized,
        // The globe key shows the language code; two English layouts would both
        // say "EN", so this one says which it is.
        globeLabel: "EN+"
    ) { meta in
        GridKeyboardFactory.layout(
            id: meta.id,
            title: meta.title,
            localeIdentifier: meta.localeIdentifier,
            centerCharacters: [
                ["l", "n", "i"],
                ["a", "o", "r"],
                ["t", "e", "s"],
            ],
            directionalOverrides: [
                GridSlot.topLeft: [.swipeDownRight: "v"],
                GridSlot.topCenter: [.swipeDown: "z"],
                GridSlot.topRight: [.swipeDownLeft: "x"],
                GridSlot.midLeft: [.swipeRight: "k"],
                GridSlot.center: [
                    .swipeUpLeft: "q", .swipeUp: "u", .swipeUpRight: "p", .swipeLeft: "c",
                    .swipeRight: "b", .swipeDownLeft: "g", .swipeDown: "d", .swipeDownRight: "j",
                ],
                GridSlot.midRight: [.swipeLeft: "m"],
                GridSlot.bottomLeft: [.swipeUpRight: "y"],
                GridSlot.bottomCenter: [.swipeUp: "w", .swipeRight: "h"],
                GridSlot.bottomRight: [.swipeUpLeft: "f"],
            ]
        )
    }
}
