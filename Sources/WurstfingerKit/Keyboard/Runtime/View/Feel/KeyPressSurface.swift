//
//  KeyPressSurface.swift
//  Wurstfinger
//
//  How a key looks and moves under a finger: the cap's fill, the light a
//  press throws, the sink and spring-back, the glass ripple, and the label
//  cross-fade when the mode changes.
//

import SwiftUI

/// The key's cap: its fill in either style, the pressed state, and the light
/// a press throws on it (`KeyLight`).
///
/// The pressed state renders on the touch-down frame — the press transaction
/// carries no animation — and only the release is animated
/// (`FeelMotion.keyRelease`), so a key never lags behind the finger that
/// pressed it.
struct KeyPressSurface: View {
    let keyStyle: KeyStyle
    let keyboardStyle: KeyboardStyle
    let isPressed: Bool
    /// Where the finger landed, in unit coordinates of the key.
    let touchPoint: CGPoint
    /// The "Key Animations" setting.
    let isAnimated: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: KeyboardConstants.KeyDimensions.cornerRadius)
        ZStack {
            switch keyboardStyle {
            case .classic:
                shape.fill(KeyView.backgroundColor(for: keyStyle, active: isPressed))
            case .liquidGlass:
                shape.fill(.bar)
                    .overlay(shape.fill(Color.primary.opacity(isPressed ? 0.16 : 0)))
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            }
            if isPressed, isAnimated {
                KeyLight(keyboardStyle: keyboardStyle, touchPoint: touchPoint)
                    .transition(.opacity)
            }
        }
        .animation(releaseAnimation, value: isPressed)
    }

    /// Nil on press (instant), the release spring otherwise.
    private var releaseAnimation: Animation? {
        guard !isPressed, isAnimated else { return nil }
        return reduceMotion ? FeelMotion.keyReleaseReduced : FeelMotion.keyRelease
    }
}

/// The light a press throws on the key: a soft bloom where the finger landed,
/// a rim along the top edge and a faint top-down lift — a curved cap catching
/// light, strongest on glass.
///
/// Drawn by the `feelKeySheen` shader when the feel shaders are compiled, and
/// by two gradients that approximate it otherwise (or with Reduce
/// Transparency on). Exists only while the key is pressed, so only a pressed
/// key reads the shader library.
struct KeyLight: View {
    let keyboardStyle: KeyboardStyle
    let touchPoint: CGPoint

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Peak opacity of the light. Glass catches far more than the opaque
    /// classic cap, and both less on a dark keyboard, where white light
    /// reads stronger.
    static func strength(for style: KeyboardStyle, scheme: ColorScheme) -> Double {
        switch (style, scheme) {
        case (.liquidGlass, .dark): 0.34
        case (.liquidGlass, _): 0.62
        case (.classic, .dark): 0.13
        case (.classic, _): 0.24
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: KeyboardConstants.KeyDimensions.cornerRadius)
        let strength = Self.strength(for: keyboardStyle, scheme: colorScheme)
        if !reduceTransparency, let library = FeelShaders.shared.library {
            shape.fill(library.feelKeySheen(
                .boundingRect,
                .float2(touchPoint.x, touchPoint.y),
                .float(strength),
                .color(.white)
            ))
            .allowsHitTesting(false)
        } else {
            ZStack {
                shape.fill(EllipticalGradient(
                    colors: [.white.opacity(strength * 0.72), .white.opacity(0)],
                    center: UnitPoint(x: touchPoint.x, y: touchPoint.y),
                    startRadiusFraction: 0,
                    endRadiusFraction: 0.75
                ))
                shape.fill(LinearGradient(
                    colors: [.white.opacity(strength * 0.32), .white.opacity(strength * 0.06)],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.22)
                ))
            }
            .allowsHitTesting(false)
        }
    }
}

/// The motion of a pressed key, applied to its whole content (cap, label,
/// hints): a slight sink toward the finger on press, a spring back on
/// release, the glass ripple, and a cross-fade of the labels when the mode or
/// language changes the key's bindings.
///
/// Reads nothing but its own key's state (passed in from the key's own
/// `KeyPressCell`), so pressing one key animates that key alone. Motion is
/// dropped under Reduce Motion (the fill still changes) and with the "Key
/// Animations" setting off (then nothing animates, as before).
struct KeyPressFeel: ViewModifier {
    let key: KeyDefinition
    let isPressed: Bool
    let touchPoint: CGPoint
    let keyboardStyle: KeyboardStyle
    let isAnimated: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Counts presses, to restart the ripple on each one.
    @State private var pressCount = 0

    private var isMotionAllowed: Bool { isAnimated && !reduceMotion }

    /// The ripple runs on glass only: on an opaque cap a refraction has
    /// nothing to bend and reads as a glitch. And only where the shader tier
    /// allows its offscreen pass (`FeelShaderTier`).
    private var isRippleWanted: Bool {
        isMotionAllowed && keyboardStyle == .liquidGlass && FeelShaders.shared.allowsRipple
    }

    func body(content: Content) -> some View {
        // Only a key that has been pressed reads the library, so its one-time
        // arrival never re-renders the untouched keys.
        let library = isRippleWanted && (isPressed || pressCount > 0) ? FeelShaders.shared.library : nil
        let anchor = UnitPoint(x: touchPoint.x, y: touchPoint.y)
        content
            .contentTransition(.interpolate)
            // Keyed by the key's label, not the whole definition: a mode or
            // language switch changes it on every key that changes, and
            // comparing a string per key per update is far cheaper than
            // comparing every binding (the mode-switch invalidation, S2).
            .animation(isAnimated ? FeelMotion.labelSwap : nil, value: key.bindings[.tap]?.label)
            .modifier(GlassRipple(isWanted: isRippleWanted, library: library, touchPoint: touchPoint, trigger: pressCount))
            .scaleEffect(isPressed && isMotionAllowed ? FeelMotion.pressedScale : 1, anchor: anchor)
            .animation(isPressed || !isMotionAllowed ? nil : FeelMotion.keyRelease, value: isPressed)
            .onChange(of: isPressed) { _, pressed in
                if pressed, isRippleWanted { pressCount &+= 1 }
            }
    }
}

/// One wavelet running out from the touch point across the pressed key
/// (`feelRipple`). A keyframe animation restarted by `trigger`; the
/// distortion is switched off whenever it is not running, so an idle key
/// costs no offscreen pass.
///
/// The view structure depends only on `isWanted` (the style and the motion
/// settings), never on whether the shader library has arrived: switching
/// structure on a key's first press rebuilt its whole subtree in the very
/// frame the press had to show. Without a library the distortion simply stays
/// disabled.
private struct GlassRipple: ViewModifier {
    let isWanted: Bool
    let library: ShaderLibrary?
    let touchPoint: CGPoint
    let trigger: Int

    /// A headless pose of the ripple (see `feelStillFrame`).
    @Environment(\.feelStillFrame) private var stillFrame

    /// Stands in for the library while it is not there: never compiled, since
    /// the effect is disabled then.
    private nonisolated static let placeholder = ShaderLibrary(data: Data())

    func body(content: Content) -> some View {
        if isWanted, let stillFrame {
            content.visualEffect { [library] effect, proxy in
                Self.ripple(effect, library: library, touchPoint: touchPoint, progress: stillFrame, size: proxy.size)
            }
        } else if isWanted {
            content.keyframeAnimator(initialValue: CGFloat(1), trigger: trigger) { [library, touchPoint] view, progress in
                view.visualEffect { effect, proxy in
                    Self.ripple(effect, library: library, touchPoint: touchPoint, progress: progress, size: proxy.size)
                }
            } keyframes: { _ in
                MoveKeyframe(CGFloat(0))
                CubicKeyframe(CGFloat(1), duration: FeelMotion.rippleDuration)
            }
        } else {
            content
        }
    }

    private nonisolated static func ripple(
        _ effect: EmptyVisualEffect, library: ShaderLibrary?, touchPoint: CGPoint, progress: CGFloat, size: CGSize
    ) -> some VisualEffect {
        effect.distortionEffect(
            (library ?? placeholder).feelRipple(
                .float2(touchPoint.x * size.width, touchPoint.y * size.height),
                .float(progress),
                .float(max(size.width, size.height) * 1.1),
                .float(FeelMotion.rippleAmplitude)
            ),
            maxSampleOffset: CGSize(width: FeelMotion.rippleAmplitude, height: FeelMotion.rippleAmplitude),
            isEnabled: library != nil && progress > 0 && progress < 1
        )
    }
}
