//
//  KeyHintCanvasTests.swift
//  WurstfingerTests
//
//  The one-`Canvas` hint drawing (`KeyHintCanvas`) against the view stacks it
//  replaces: which hints a key shows, how the emphasis animates, and that a
//  rendered key is the same picture either way.
//

import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import WurstfingerKit

@MainActor
@Suite(.serialized)
struct KeyHintCanvasTests {
    // MARK: - Fixtures

    private func binding(_ label: String, _ action: KeyAction? = nil) -> KeyBinding {
        KeyBinding(
            label: label, action: action ?? .commitText(label),
            category: nil, returnAction: nil, accessibilityLabel: nil
        )
    }

    /// A key with all eight hints: letters (the prominent styling) and symbols.
    private var richKey: KeyDefinition {
        .letter("k", tap: "k", swipes: [
            .swipeUp: "u", .swipeDown: "d", .swipeLeft: "(", .swipeRight: "%",
            .swipeUpLeft: "ä", .swipeUpRight: "!", .swipeDownLeft: "[", .swipeDownRight: "…",
        ])
    }

    /// A utility key shaped like the globe key: the input-method icon on the
    /// tap, the language switch on a swipe, dismiss and the clipboard icons on
    /// others (all with the empty label an icon hint carries).
    private var globeKey: KeyDefinition {
        var bindings = [GestureType: KeyBinding]()
        bindings[.tap] = binding("🌐", .advanceToNextInputMode)
        bindings[.swipeLeft] = binding("", .switchToNextLanguage)
        bindings[.swipeDown] = binding("", .dismissKeyboard)
        bindings[.swipeUpRight] = binding("", .cut)
        bindings[.swipeUpLeft] = binding("", .copy)
        bindings[.swipeUp] = binding("", .advanceToNextInputMode)
        return KeyDefinition(
            id: "globe", bindings: bindings, swipeMode: .eightWay,
            slideType: .none, style: .utility, tapCycleActions: nil
        )
    }

    private func hints(
        _ key: KeyDefinition, language: String = "DE", isLanguageShown: Bool = true,
        isVisible: @escaping (KeyBinding) -> Bool = { _ in true }
    ) -> [KeyHintCanvas.Hint] {
        KeyHintCanvas.hints(
            for: key, languageLabel: language, isLanguageLabelShown: isLanguageShown, isLabelVisible: isVisible
        )
    }

    // MARK: - Which hints

    @Test func aRichKeyDrawsAllEightHintsInTheFixedOrder() {
        let drawn = hints(richKey)
        #expect(drawn.map(\.gesture) == KeyView.hintGestureOrder)
        #expect(drawn.map(\.slot) == Array(0 ..< 8))
        // Letters take the prominent styling, symbols the plain one.
        #expect(drawn[0].content == .text("u", isLetter: true))
        #expect(drawn[2].content == .text("(", isLetter: false))
        #expect(drawn[4].content == .text("ä", isLetter: true))
    }

    @Test func aKeyDrawsOnlyTheGesturesItBinds() {
        let key = KeyDefinition.letter("k", tap: "k", swipes: [.swipeRight: "r", .swipeDownLeft: "l"])
        #expect(hints(key).map(\.gesture) == [.swipeRight, .swipeDownLeft])
        // The tap is the centre label, never a hint.
        #expect(hints(.letter("k", tap: "k")).isEmpty)
    }

    @Test func iconActionsDrawIconsEvenWithAnEmptyLabel() {
        let drawn = hints(globeKey)
        let byGesture = Dictionary(uniqueKeysWithValues: drawn.map { ($0.gesture, $0.content) })
        #expect(byGesture[.swipeDown] == .icon(name: "keyboard.chevron.compact.down", isGlobeStyle: true))
        #expect(byGesture[.swipeUp] == .icon(name: "globe", isGlobeStyle: true))
        #expect(byGesture[.swipeUpRight] == .icon(name: "scissors", isGlobeStyle: false))
        #expect(byGesture[.swipeUpLeft] == .icon(name: "doc.on.doc", isGlobeStyle: false))
    }

    @Test func theLanguageSwitchShowsTheLanguageCodeOnlyWhenAsked() {
        #expect(hints(globeKey, language: "FR").contains { $0.content == .language("FR") })
        let hidden = hints(globeKey, isLanguageShown: false)
        // Neither the code nor the fallback icon: the slot stays empty.
        #expect(!hidden.contains { $0.gesture == .swipeLeft })
    }

    @Test func labelVisibilityHidesTextAndIconHintsButNotTheLanguageCode() {
        #expect(hints(richKey, isVisible: { _ in false }).isEmpty)
        let onlyLanguage = hints(globeKey, isVisible: { _ in false })
        #expect(onlyLanguage.map(\.content) == [.language("DE")])
    }

    // MARK: - Geometry tables

    /// The canvas places a hint from `hintAlignments` and grows it from
    /// `hintAnchor`: the two tables describe the same edge or corner.
    @Test func theAlignmentAndTheGrowthAnchorNameTheSameEdge() {
        for gesture in KeyView.hintGestureOrder {
            let alignment = try! #require(KeyView.hintAlignments[gesture])
            #expect(KeyHintCanvas.unitPoint(for: alignment) == KeyView.hintAnchor(for: gesture), "\(gesture)")
        }
        #expect(KeyHintCanvas.unitPoint(for: .center) == .center)
    }

    // MARK: - Emphasis

    @Test func theTargetSwellsAndTheOthersRecede() {
        let emphasis = HintEmphasis(candidate: .swipeRight, isGuided: true)
        let target = KeyView.hintGestureOrder.firstIndex(of: .swipeRight)!
        for slot in 0 ..< 8 {
            #expect(emphasis.lift[slot] == (slot == target ? 1 : 0))
            #expect(emphasis.opacity[slot] == (slot == target ? 1 : HintEmphasis.receded))
        }
    }

    @Test func aCircleRecedesEveryHintAndSwellsNone() {
        let emphasis = HintEmphasis(candidate: .circularClockwise, isGuided: true)
        #expect(emphasis.lift == .zero)
        #expect(emphasis.opacity == SIMD8(repeating: HintEmphasis.receded))
    }

    @Test func noFingerLeavesEveryHintAtRest() {
        let emphasis = HintEmphasis(candidate: nil, isGuided: false)
        #expect(emphasis == HintEmphasis.rest)
        #expect(emphasis.lift == .zero)
        #expect(emphasis.opacity == .one)
    }

    /// What `Animatable` needs: interpolation is linear and lands on the end
    /// values, so a spring over it moves the hint smoothly from rest to target.
    @Test func emphasisInterpolatesLinearlyBetweenRestAndTarget() {
        let rest = HintEmphasis.rest
        let target = HintEmphasis(candidate: .swipeUp, isGuided: true)
        var halfway = target - rest
        halfway.scale(by: 0.5)
        let mid = rest + halfway
        let slot = KeyView.hintGestureOrder.firstIndex(of: .swipeUp)!
        let other = (slot + 1) % 8
        #expect(mid.lift[slot] == 0.5)
        #expect(mid.opacity[slot] == 1)
        #expect(mid.lift[other] == 0)
        #expect(abs(mid.opacity[other] - (1 + HintEmphasis.receded) / 2) < 1e-12)

        var scaled = target
        scaled.scale(by: 2)
        #expect(abs(scaled.magnitudeSquared - 4 * target.magnitudeSquared) < 1e-9)
        #expect(HintEmphasis.zero.magnitudeSquared == 0)
        #expect(rest + HintEmphasis.zero == rest)
    }

    // MARK: - The picture is the same

    /// Renders `key` in a 72 x 72 pt frame (a whole number of pixels at
    /// every scale, so SwiftUI's pixel snapping has nothing to round) and
    /// returns its RGBA bytes.
    private func pixels(
        of key: KeyDefinition, rendering: HintRendering, candidate: GestureType? = nil,
        scheme: ColorScheme = .light, language: String = "DE"
    ) throws -> [UInt8] {
        KeyView.hintRendering = rendering
        let registry = KeyPressRegistry()
        registry.setCandidate(candidate, isReturn: false, keyId: key.id)
        let metrics = KeyboardLayoutMetrics.reference
        let view = KeyView(
            key: key, onGesture: { _, _, _ in },
            pressCell: registry.cell(for: key.id),
            settings: KeyRenderSettings(), metrics: metrics,
            languageLabel: language, isLanguageLabelShown: true
        )
        .frame(width: 72, height: 72)
        .background(scheme == .dark ? Color.black : Color.white)
        .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        renderer.isOpaque = true
        let image = try #require(renderer.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    /// Both renderings must give the same picture. The first render in a
    /// process differs from the later ones by a rounding step in the text
    /// rasterizer, so one render of each is thrown away first; under the
    /// parallel suite's load the step can recur (a symbol's glyph cache
    /// shared with other tests), so a differing pair is rendered again, up
    /// to `attempts` times. A real divergence differs every time.
    private func expectSamePicture(
        _ key: KeyDefinition, candidate: GestureType? = nil, scheme: ColorScheme = .light,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let saved = KeyView.hintRendering
        defer { KeyView.hintRendering = saved }
        _ = try pixels(of: key, rendering: .views, candidate: candidate, scheme: scheme)
        _ = try pixels(of: key, rendering: .canvas, candidate: candidate, scheme: scheme)
        let attempts = 3
        var views: [UInt8] = []
        var differing = 0
        for _ in 0 ..< attempts {
            views = try pixels(of: key, rendering: .views, candidate: candidate, scheme: scheme)
            let canvas = try pixels(of: key, rendering: .canvas, candidate: candidate, scheme: scheme)
            differing = zip(views, canvas).filter { $0 != $1 }.count
            if differing == 0 { break }
        }
        #expect(differing == 0, "\(differing) bytes differ", sourceLocation: sourceLocation)
        // A blank render would make the comparison vacuous.
        #expect(Set(views).count > 8, "the key drew something", sourceLocation: sourceLocation)
    }

    @Test func aRestingKeyDrawsTheSamePictureAsTheViewStacks() throws {
        try expectSamePicture(richKey)
        try expectSamePicture(richKey, scheme: .dark)
    }

    @Test func theIconKeyDrawsTheSamePictureAsTheViewStacks() throws {
        try expectSamePicture(globeKey)
    }

    @Test func theEmphasizedHintDrawsTheSamePictureAsTheViewStacks() throws {
        // The swelling, the accent colour, the bold weight and the receding
        // of the rest, for a text hint and for an icon hint.
        try expectSamePicture(richKey, candidate: .swipeRight)
        try expectSamePicture(richKey, candidate: .swipeUpLeft, scheme: .dark)
        try expectSamePicture(globeKey, candidate: .swipeDown)
        try expectSamePicture(richKey, candidate: .circularClockwise)
    }
}
