//
//  FeelOverlay.swift
//  Wurstfinger
//
//  The feel layer's transient visuals over the key grid: committed glyphs
//  lifting off, the long-press ring, the slide ratchet.
//

import SwiftUI

/// Draws `FeelBoard` over the key grid, in the grid's coordinate space (the
/// same one the input engine's key frames are in).
///
/// Three independent parts, each reading one property of the board, so a
/// commit re-renders only the pops, a long press only the ring, a slide step
/// only the ratchet — and none of them a key. Each one draws nothing at
/// all while its property is empty; every animation is a SwiftUI animation
/// that stops when it is done (no timeline, no timer).
struct FeelOverlay: View {
    let board: FeelBoard

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                RatchetOverlay(board: board, bounds: proxy.size)
                RingOverlay(board: board, bounds: proxy.size)
                PopOverlay(board: board, bounds: proxy.size)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        // Echoes what the user just did; VoiceOver announces the typed text.
        .accessibilityHidden(true)
        // The shaders compile in the background the first time a keyboard
        // shows; until then every effect draws its fallback.
        .onAppear { FeelShaders.shared.prepare() }
    }
}

// MARK: - Commit pops

private struct PopOverlay: View {
    let board: FeelBoard
    let bounds: CGSize

    var body: some View {
        ForEach(board.pops) { pop in
            CommitPopView(pop: pop, bounds: bounds) { board.removePop(id: pop.id) }
        }
    }
}

/// One committed glyph lifting off and fading.
///
/// It starts where the guide card showed it lit — the user was looking there
/// — and keeps the card's look, so the lit bubble seems to float off when the
/// finger lifts instead of vanishing. A long press, which has no lit cell,
/// uses the card's centre. Under Reduce Motion it only fades, in place.
///
/// Taps get no pop: their glyph is the key's own label, and a ghost of it
/// rising at typing speed reads as flicker. A tap is confirmed by the key
/// springing back and the release click.
struct CommitPopView: View {
    let pop: FeelBoard.Pop
    let bounds: CGSize
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.feelStillFrame) private var stillFrame
    @State private var animatedProgress: CGFloat = 0

    private var progress: CGFloat { stillFrame ?? animatedProgress }

    /// Where the pop starts (the centre of its cell on the guide card) and
    /// the cell's size.
    static func origin(of pop: FeelBoard.Pop, in bounds: CGSize) -> (center: CGPoint, cell: CGFloat) {
        let cell = TouchGuideCard.cellSize(for: pop.keyFrame)
        let center = TouchGuideCard.placement(cardSide: cell * 3, keyFrame: pop.keyFrame, bounds: bounds)
        let offset = FeelGeometry.mapOffset(of: pop.gesture)
        return (CGPoint(x: center.x + offset.dx * cell, y: center.y + offset.dy * cell), cell)
    }

    /// How far the pop rises at `progress`, kept inside the keyboard: an
    /// extension cannot draw above its own view, and a bubble sliding under
    /// that edge reads as clipped, not as lifting off.
    static func rise(progress: CGFloat, center: CGPoint, cell: CGFloat) -> CGFloat {
        let room = max(center.y - cell * FeelMotion.popScale / 2, 0)
        return min(FeelMotion.popRise * cell, room) * progress
    }

    var body: some View {
        let origin = Self.origin(of: pop, in: bounds)
        let cell = origin.cell
        let rise = reduceMotion ? 0 : Self.rise(progress: progress, center: origin.center, cell: cell)
        let scale = reduceMotion ? 1 : 1 + (FeelMotion.popScale - 1) * progress
        Text(pop.text)
            .font(.system(size: cell * 0.62, weight: .bold, design: .rounded))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .padding(cell * 0.06)
            .frame(width: cell, height: cell)
            .background(
                RoundedRectangle(cornerRadius: cell * 0.3, style: .continuous)
                    .fill(Color.accentColor)
            )
            .scaleEffect(scale)
            .opacity(Double(1 - progress))
            .position(x: origin.center.x, y: origin.center.y - rise)
        .onAppear {
            guard stillFrame == nil else { return }
            withAnimation(reduceMotion ? FeelMotion.popReduced : FeelMotion.pop) {
                animatedProgress = 1
            } completion: {
                onFinish()
            }
        }
    }
}

// MARK: - Long-press ring

private struct RingOverlay: View {
    let board: FeelBoard
    let bounds: CGSize

    var body: some View {
        if let ring = board.ring {
            LongPressRingView(ring: ring, bounds: bounds) { board.clearRing(id: ring.id) }
                .id(ring.id)
                .transition(.opacity.animation(FeelMotion.ringCancel))
        }
    }
}

/// A thin accent line running once around the key while the finger rests,
/// completing as the long press fires; then a short flash outward.
///
/// Shows only after `LongPressFeel.ringLeadIn`, so a tap never flashes it.
/// The fill is a single linear animation started on appear and run by
/// SwiftUI to the moment the press fires: no timer, no per-frame work on our
/// side. It is a progress indicator, so it stays under Reduce Motion; only
/// the outward flash is dropped there.
struct LongPressRingView: View {
    let ring: FeelBoard.Ring
    let bounds: CGSize
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A headless pose: the fill at this fraction (or mid-flash once fired).
    @Environment(\.feelStillFrame) private var stillProgress
    @State private var progress: CGFloat = 0
    @State private var isShown = false
    @State private var flash: CGFloat = 0

    var body: some View {
        let key = FeelGeometry.visibleKeyRect(touchFrame: ring.keyFrame, in: bounds)
        let shape = KeyOutline(cornerRadius: KeyboardConstants.KeyDimensions.cornerRadius)
        let shown = stillProgress != nil || isShown
        // A still of a fired ring shows its flash at the posed fraction.
        let fill = ring.hasFired ? 1 : (stillProgress ?? progress)
        let flashed = ring.hasFired ? (stillProgress ?? flash) : flash
        ZStack {
            shape.stroke(Color.accentColor.opacity(0.18), lineWidth: 2)
            shape.trim(from: 0, to: fill)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.25, lineCap: .round))
        }
        .frame(width: key.width - 1, height: key.height - 1)
        .scaleEffect(1 + flashed * (reduceMotion ? 0 : 0.08))
        .opacity(shown ? Double(1 - flashed) : 0)
        .position(x: key.midX, y: key.midY)
        .onAppear {
            guard stillProgress == nil else { return }
            let lead = min(LongPressFeel.ringLeadIn, ring.duration)
            withAnimation(FeelMotion.ringAppear.delay(lead)) { isShown = true }
            withAnimation(.linear(duration: max(ring.duration - lead, 0.01)).delay(lead)) { progress = 1 }
        }
        .onChange(of: ring.hasFired) { _, fired in
            guard fired else { return }
            // Snap the line closed (the timer and the animation may be a
            // frame apart), then flash it out.
            var snap = Transaction()
            snap.disablesAnimations = true
            withTransaction(snap) {
                progress = 1
                isShown = true
            }
            withAnimation(FeelMotion.ringFire) { flash = 1 } completion: { onFinish() }
        }
    }
}

/// A key's rounded outline traced from the middle of its top edge,
/// clockwise, so a trimmed stroke fills like a progress ring (a
/// `RoundedRectangle` starts at a corner).
struct KeyOutline: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: radius
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: radius
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: radius
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: radius
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - Slide ratchet

private struct RatchetOverlay: View {
    let board: FeelBoard
    let bounds: CGSize

    var body: some View {
        ZStack {
            if let ratchet = board.ratchet {
                SlideRatchetView(ratchet: ratchet, bounds: bounds)
                    .transition(.opacity)
            }
        }
        .animation(FeelMotion.ratchetFade, value: board.ratchet?.keyId)
    }
}

/// A strip of fine detents along the bottom of a sliding space or delete key
/// that moves one notch per caret step or deleted character — the visual twin
/// of the slide's haptic ticks, a thumbwheel turning under the finger.
///
/// The strip is periodic and its ends fade out, so each step can jump it back
/// by one notch unseen and spring it forward to rest: it advances forever
/// without its offset ever growing. Under Reduce Motion the notches stay put
/// and only the centre mark (tinted by direction) shows the slide.
struct SlideRatchetView: View {
    let ratchet: FeelBoard.Ratchet
    let bounds: CGSize

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Distance between two notches, in points.
    static let pitch: CGFloat = 7
    /// Notches on each side of the centre.
    static let reach = 7

    var body: some View {
        let key = FeelGeometry.visibleKeyRect(touchFrame: ratchet.keyFrame, in: bounds)
        let width = min(key.width * 0.7, CGFloat(Self.reach * 2) * Self.pitch)
        let tint = ratchet.slideType == .delete ? Color.red : Color.accentColor
        let direction = CGFloat(ratchet.lastDirection)
        let moves = !reduceMotion
        ZStack {
            HStack(spacing: Self.pitch - 2) {
                ForEach(-Self.reach ... Self.reach, id: \.self) { _ in
                    Capsule()
                        .fill(Color.primary.opacity(0.3))
                        .frame(width: 2, height: 6)
                }
            }
            .keyframeAnimator(initialValue: CGFloat(0), trigger: ratchet.steps) { strip, offset in
                strip.offset(x: offset)
            } keyframes: { _ in
                MoveKeyframe(moves ? -direction * Self.pitch : 0)
                SpringKeyframe(CGFloat(0), duration: 0.16, spring: .init(response: 0.14, dampingRatio: 0.7))
            }
            .frame(width: width, height: 10)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.32),
                        .init(color: .black, location: 0.68),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            Capsule()
                .fill(tint)
                .frame(width: 3, height: 10)
        }
        .position(x: key.midX, y: key.maxY - min(key.height * 0.17, 10))
    }
}
