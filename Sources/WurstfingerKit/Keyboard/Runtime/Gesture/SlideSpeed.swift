//
//  SlideSpeed.swift
//  Wurstfinger
//
//  How fast the finger slides along the space bar, and the word boundaries a
//  fast slide steps over.
//

import CoreGraphics
import Foundation
import NaturalLanguage

/// Tells a deliberate slide from a sweep: the caret moves by characters at
/// normal speed and by words once the finger is clearly sweeping.
///
/// The speed is an exponentially weighted rate: every sample's travel counts
/// for `window` seconds, fading out, so the estimate needs no stored history
/// (a value type, no allocation) and decays by itself when the finger slows
/// or stops.
///
/// **Hysteresis.** The slide turns to words above `wordEnter` and back to
/// characters only below `wordExit`, half of it. A finger hovering near one
/// number therefore does not flicker between the two, and a slow slide after a
/// fast one returns to characters once the estimate has decayed under
/// `wordExit` (about `window` after the finger slows, since the estimate falls
/// by 1/e per `window`). Reversing direction starts over in characters: the
/// user turned around to correct.
///
/// **The numbers.** Measured with the scenario harness's slide paths
/// (`WordSlideTests`): its ordinary drag is 500 pt/s, which must never step by
/// words, and a deliberate sweep is 1000 pt/s and up, which must. Entering at
/// 750 pt/s (1.5 times an ordinary drag) and leaving at 375 keeps both sides
/// with margin, and a constant 1000 pt/s sweep crosses 750 after about 80 ms,
/// so a sweep starts in characters and turns to words as it gathers speed.
struct SlideSpeedTracker: Sendable, Equatable {
    /// Seconds of travel the estimate remembers.
    static let window: TimeInterval = 0.06
    /// Points per second above which the slide steps by words.
    static let wordEnter: CGFloat = 750
    /// Points per second below which it goes back to characters.
    static let wordExit: CGFloat = 375
    /// A gap this long between samples means the finger paused: the speed
    /// before it no longer says anything about the movement after it.
    static let pause: TimeInterval = 0.25

    /// The smoothed speed, in points per second.
    private(set) var rate: CGFloat = 0
    /// Whether the slide is currently stepping by words.
    private(set) var isSweeping = false
    private var lastTime: TimeInterval?
    private var lastDirection = 0

    /// Forgets the slide (a new one begins).
    mutating func reset() {
        self = SlideSpeedTracker()
    }

    /// Accounts for `deltaX` points of travel at `time` and returns whether the
    /// slide now steps by words. A sample with no time passed since the last
    /// (or none at all, as when a caller has no clock) leaves the estimate
    /// alone: speed unknown reads as slow.
    @discardableResult
    mutating func note(deltaX: CGFloat, at time: TimeInterval) -> Bool {
        let direction = deltaX < 0 ? -1 : 1
        if lastDirection != 0, direction != lastDirection {
            reset()
        }
        lastDirection = direction
        let elapsed: TimeInterval
        if let lastTime {
            elapsed = time - lastTime
            guard elapsed > 0 else { return isSweeping }
        } else {
            elapsed = 1.0 / 120 // the first sample of a slide: assume a frame
        }
        lastTime = time
        let decayed = elapsed >= Self.pause ? 0 : rate * CGFloat(exp(-elapsed / Self.window))
        rate = decayed + abs(deltaX) / CGFloat(Self.window)
        if isSweeping {
            if rate < Self.wordExit { isSweeping = false }
        } else if rate >= Self.wordEnter {
            isSweeping = true
        }
        return isSweeping
    }
}

/// Word boundaries in the text around the caret, for the sweep.
///
/// Boundaries come from the system's word segmenter (`NLTokenizer`, with the
/// layout's language), so scripts written without spaces (Chinese, Japanese,
/// Thai) step by the words the segmenter finds and not by whitespace, and
/// text in a right-to-left script steps by its words in logical order, which
/// is what the proxy's context is. Text the segmenter finds no word in falls
/// back to `PartialWord`'s idea of one (a run of letters).
enum WordBoundary {
    /// Characters of context looked at each way: enough for a sweep's worth of
    /// words, bounded so a long paragraph is never segmented whole.
    static let window = 240

    /// UTF-16 distances for `count` successive word steps, each from where the
    /// last landed. Backward steps land on a word's start, forward steps on a
    /// word's end (both passing over the spaces and marks in between). Fewer
    /// than `count` when the context runs out of words.
    static func steps(in context: String, count: Int, backward: Bool, locale: Locale) -> [Int] {
        guard count > 0, !context.isEmpty else { return [] }
        let text = backward ? String(context.suffix(window)) : String(context.prefix(window))
        let ranges = wordRanges(in: text, locale: locale)
        guard !ranges.isEmpty else { return [] }

        // Distances of each boundary from the caret, nearest first.
        var distances: [Int] = []
        if backward {
            for range in ranges.reversed() {
                distances.append(text.utf16.distance(from: range.lowerBound, to: text.endIndex))
            }
        } else {
            for range in ranges {
                distances.append(text.utf16.distance(from: text.startIndex, to: range.upperBound))
            }
        }
        var previous = 0
        var steps: [Int] = []
        for distance in distances where distance > previous {
            steps.append(distance - previous)
            previous = distance
            if steps.count == count { break }
        }
        return steps
    }

    private static func wordRanges(in text: String, locale: Locale) -> [Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        if let language = locale.language.languageCode?.identifier {
            tokenizer.setLanguage(NLLanguage(rawValue: language))
        }
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex ..< text.endIndex) { range, _ in
            ranges.append(range)
            return true
        }
        if !ranges.isEmpty { return ranges }
        // Nothing the segmenter calls a word: runs of letters, as typing sees them.
        var start: String.Index?
        for index in text.indices {
            if PartialWord.isWordCharacter(text[index]) {
                if start == nil { start = index }
            } else if let begin = start {
                ranges.append(begin ..< index)
                start = nil
            }
        }
        if let begin = start { ranges.append(begin ..< text.endIndex) }
        return ranges
    }
}

extension KeyboardViewModel {
    /// WORD STEP feel hook: the caret stepped over a word. On top of the
    /// ordinary caret tick (`feelSlideStep`, which also drives the ratchet and
    /// the key click) it plays the firm detent the direction picks use, so a
    /// word step is felt and heard as heavier than a character step. Asks
    /// nothing of the feel layer beyond `play(_:)` with an existing cue.
    func feelWordStep(direction: Int) {
        feel.play(.directionDetent)
    }
}
