//
//  TouchGuideOverlay.swift
//  Wurstfinger
//
//  The card that shows where a flick is going while the finger is still down.
//

import SwiftUI

/// Draws the input engine's `TouchGuide`: a small 3×3 map of the touched key —
/// its eight swipe targets around its tap — placed where the thumb is not.
///
/// **What it shows.** During a quick flick only the targeted cell is drawn, at
/// its spatial position in the map: a bubble above the key that shows exactly
/// what releasing now will type (the label the view model resolved, shift and
/// return swipes included), moving to the side the finger is heading. If the
/// finger lingers, the rest of the map fades in, so a hesitating user sees
/// every option of the key under their thumb, with the current one lit.
///
/// **Where.** Above the key — the thumb covers the key and comes from below —
/// overlapping its top edge if it must; beside it on the top row, since a
/// keyboard extension cannot draw outside its own view.
///
/// **What it costs.** The overlay observes only `KeyPressRegistry.guide`, which
/// the engine changes on touch-down, release and when the target changes — not
/// per drag sample. The delayed fade-in is an animation with a delay, run by
/// the render server: no timer, no main-thread work while the finger rests.
struct TouchGuideOverlay: View {
    let press: KeyPressRegistry
    let keys: [String: KeyDefinition]
    /// The grid's size, which the card is placed and clamped within. Computed
    /// by the grid from its metrics rather than measured with a
    /// `GeometryReader`: the overlay then costs no layout pass of its own, and
    /// nothing at all while no finger is down.
    let gridSize: CGSize
    /// Whether to fade in the full map when the finger lingers.
    var revealsMapOnPause = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let guide = press.guide, let key = keys[guide.keyId] {
                TouchGuideCard(
                    guide: guide, key: key, bounds: gridSize, revealsMapOnPause: revealsMapOnPause
                )
                // A new touch is a new card, which restarts the reveal delay.
                .id(guide.touchID)
            }
        }
        // The card positions itself in the grid's coordinate space, so the
        // container must span the grid exactly.
        .frame(width: gridSize.width, height: gridSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
        // Echoes the gesture under the user's finger; VoiceOver users get the
        // keys' own custom actions instead.
        .accessibilityHidden(true)
    }
}

/// One touch's card. See `TouchGuideOverlay`.
struct TouchGuideCard: View {
    let guide: TouchGuide
    let key: KeyDefinition
    let bounds: CGSize
    let revealsMapOnPause: Bool

    /// Flipped on appear inside a delayed animation, so the map fades in only
    /// once the finger has rested for `revealDelay`.
    @State private var isRevealedAfterDelay = false

    /// Headless hosts pick the state they draw (`SnapshotHooks.swift`).
    @Environment(\.touchGuideReveal) private var reveal

    private var isMapRevealed: Bool {
        switch reveal {
        case .afterPause: isRevealedAfterDelay
        case .immediately: true
        case .never: false
        }
    }

    /// Long enough that a fluent flick (typically 80–200 ms) never shows the
    /// map, short enough to catch a hesitation.
    static let revealDelay: TimeInterval = 0.35

    /// The map's rows: each cell is the gesture whose target sits there.
    static let layout: [[GestureType]] = [
        [.swipeUpLeft, .swipeUp, .swipeUpRight],
        [.swipeLeft, .tap, .swipeRight],
        [.swipeDownLeft, .swipeDown, .swipeDownRight],
    ]

    var body: some View {
        let cell = Self.cellSize(for: guide.keyFrame)
        let side = cell * 3
        let center = Self.placement(cardSide: side, keyFrame: guide.keyFrame, bounds: bounds)
        ZStack {
            RoundedRectangle(cornerRadius: cell * 0.35, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                .opacity(isMapRevealed ? 1 : 0)
            VStack(spacing: 0) {
                ForEach(0 ..< 3, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0 ..< 3, id: \.self) { column in
                            mapCell(Self.layout[row][column], size: cell)
                        }
                    }
                }
            }
        }
        .frame(width: side, height: side)
        .position(center)
        .onAppear {
            guard revealsMapOnPause, reveal == .afterPause else { return }
            withAnimation(.easeOut(duration: 0.15).delay(Self.revealDelay)) {
                isRevealedAfterDelay = true
            }
        }
    }

    // MARK: - Cells

    private var target: GestureType {
        switch guide.candidate {
        case nil, .circularClockwise?, .circularCounterclockwise?: .tap
        case let candidate?: candidate
        }
    }

    @ViewBuilder
    private func mapCell(_ gesture: GestureType, size: CGFloat) -> some View {
        let isTarget = gesture == target && (guide.candidate != nil || isMapRevealed)
        let text = isTarget ? (guide.label ?? Self.label(of: gesture, on: key)) : Self.label(of: gesture, on: key)
        ZStack {
            if isTarget {
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(Color.accentColor)
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
                if guide.isReturn || isCircle {
                    // A return swipe or a circle types something other than
                    // the plain swipe: ring the cell so the difference shows.
                    RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
                        .padding(3)
                }
            }
            if let text, !text.isEmpty {
                Text(text)
                    .font(.system(size: size * (isTarget ? 0.62 : 0.45), weight: isTarget ? .bold : .medium, design: .rounded))
                    .foregroundStyle(isTarget ? Color.white : Color.primary.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .padding(size * 0.06)
            }
        }
        .frame(width: size, height: size)
        // Unlit cells exist only once the map is revealed; the lit one shows
        // from the first frame its gesture is known.
        .opacity(isTarget || isMapRevealed ? 1 : 0)
    }

    private var isCircle: Bool {
        guide.candidate == .circularClockwise || guide.candidate == .circularCounterclockwise
    }

    /// The label a map cell shows when it is not the target: the key's own
    /// binding label, as its hint draws it.
    static func label(of gesture: GestureType, on key: KeyDefinition) -> String? {
        guard let binding = key.bindings[gesture] else { return nil }
        return binding.label.isEmpty ? nil : binding.label
    }

    // MARK: - Geometry

    /// A map cell is a bit under half the key's short side, so the whole card
    /// is about 1.3 keys across: big enough to read past a thumb, small enough
    /// to fit above any key but the top row.
    static func cellSize(for keyFrame: CGRect) -> CGFloat {
        max(min(keyFrame.width, keyFrame.height) * 0.44, 18)
    }

    /// Where the card's centre goes. Above the key whenever there is at least
    /// half a card of room — the thumb comes from below, so above is the one
    /// place it never covers; the card may then overlap the key's top edge,
    /// which holds the same hints the card repeats. Only the top row has no
    /// room, and there the card goes beside the key, on the side with more
    /// space. Always clamped into `bounds`, since an extension cannot draw
    /// outside its view.
    static func placement(cardSide: CGFloat, keyFrame: CGRect, bounds: CGSize) -> CGPoint {
        let gap: CGFloat = 4
        let half = cardSide / 2
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, half), max(bounds.width - half, half)) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, half), max(bounds.height - half, half)) }

        if keyFrame.minY - gap >= half {
            return CGPoint(x: clampX(keyFrame.midX), y: clampY(keyFrame.minY - gap - half))
        }
        let roomLeft = keyFrame.minX
        let roomRight = bounds.width - keyFrame.maxX
        let x = roomLeft >= roomRight
            ? keyFrame.minX - gap - half
            : keyFrame.maxX + gap + half
        return CGPoint(x: clampX(x), y: clampY(keyFrame.midY))
    }
}
