//
//  GestureTrailOverlay.swift
//  Wurstfinger
//
//  Draws the optional gesture trail on top of the key grid: a dot under a
//  press, a tapered ribbon under a swipe.
//

import SwiftUI

/// Renders the trail recorded by `GestureTrailRecorder`.
///
/// Sits in an `.overlay` on the grid layout, which is also where the recorder's
/// coordinate space is registered — so the recorded points map onto this view's
/// bounds one to one, with no padding or offset correction.
struct GestureTrailOverlay: View {
    /// Read in `body` (for `isVisible`), which is what subscribes this view —
    /// and only this view — to the recorder's visibility flips.
    let recorder: GestureTrailRecorder

    /// Width of the ribbon at the finger, scaled from the rendered key size by
    /// `headWidth(for:)`.
    let headWidth: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        // Nothing is rendered — and no display-linked timer runs — unless a
        // trail is in flight.
        if recorder.isVisible {
            TimelineView(.animation) { timeline in
                Canvas { context, _ in
                    draw(in: &context, at: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
            .allowsHitTesting(false)
            // Purely decorative: it echoes a gesture the user is making right
            // now, so it has nothing to announce and must not sit between
            // VoiceOver and the keys underneath.
            .accessibilityHidden(true)
        }
    }

    /// Head width for a rendered key size, clamped so the trail stays
    /// proportionate on both a compact one-handed keyboard and a full-width
    /// iPad layout.
    static func headWidth(for metrics: KeyboardLayoutMetrics) -> CGFloat {
        let scaled = metrics.rowHeight * KeyboardConstants.GestureTrail.widthFraction
        return min(
            max(scaled, KeyboardConstants.GestureTrail.minWidth),
            KeyboardConstants.GestureTrail.maxWidth
        )
    }

    private func draw(in context: inout GraphicsContext, at now: TimeInterval) {
        let trail = recorder.trail
        // The recorder drops a faded-out trail from a main-actor fade-out task, so
        // a busy main thread can hand this a trail whose fade already expired.
        // Those frames would build the full ribbon only to fill it at zero
        // opacity; bail before the geometry instead.
        guard !trail.isFinished(at: now) else { return }
        let samples = trail.samples[trail.visibleSampleRange(at: now)]
        guard let head = samples.last?.point else { return }
        // While the finger is down, run the ribbon out to where the system
        // predicts it is going, so the head sits under the finger.
        let predicted = trail.releaseTime == nil ? recorder.predicted : []

        // Feel: ink-like — thinner where the finger moved fast, fading toward
        // the tail, glowing under the finger (`GestureTrailInk`).
        let path = GestureTrailInk.shape(
            samples: samples, predicted: predicted, headWidth: headWidth, scratch: recorder.drawScratch
        )
        // One fill of one closed contour, so the alpha is the shading's alone
        // even where the path crosses itself.
        // A long swipe that will fire on release reads in the accent colour,
        // and a little stronger than the neutral trail so the change registers.
        let isArmed = recorder.isLongSwipeArmed
        let opacity = isArmed
            ? KeyboardConstants.GestureTrail.armedOpacity
            : KeyboardConstants.GestureTrail.opacity
        // A light core reads as a glow on the accent ink and on light ink
        // over a dark keyboard; on dark ink over a light one it would read
        // as a grey smudge.
        let glow = isArmed ? 0.7 : (colorScheme == .dark ? 0.45 : 0)
        context.opacity = trail.fadeOpacity(at: now)
        context.fill(path, with: GestureTrailInk.shading(
            head: predicted.last ?? head,
            headWidth: headWidth,
            color: isArmed ? .accentColor : .primary,
            opacity: opacity,
            glow: glow,
            library: reduceTransparency ? nil : FeelShaders.shared.library
        ))
    }
}
