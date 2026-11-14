//
//  FeelShaderSource.swift
//  Wurstfinger
//
//  The Metal source of the feel layer's shaders, compiled at runtime by
//  `FeelShaders` (the package builds without a Metal compiler).
//

/// Metal Shading Language source for the feel shaders.
///
/// Every function is `[[stitchable]]`, the form SwiftUI's shader effects call:
/// a shape style (`half4 f(float2 position, args...)`) or a distortion
/// (`float2 f(float2 position, args...)`). They are kept to a handful of ALU
/// operations per pixel and run only on the few pixels of one pressed key or
/// the trail, only while something is moving or pressed.
///
/// Mirrored by pure-SwiftUI fallbacks (`KeyPressSurface`, `GestureTrailInk`)
/// that draw the same idea with gradients when the shaders are unavailable or
/// Reduce Transparency is on; keep the two in step when tuning.
enum FeelShaderSource {
    /// Function names, checked against the compiled library before SwiftUI
    /// is handed it.
    static let functionNames: Set<String> = ["feelKeySheen", "feelRipple", "feelTrailInk"]

    static let metal = """
    #include <metal_stdlib>
    using namespace metal;

    // A pressed key catching light: a soft Gaussian bloom centred on the
    // touch, a thin rim along the top edge and a faint top-down lift, as on a
    // curved glass cap lit from above. Premultiplied output, drawn over the key.
    //   bounds   the shape's bounding rect (.boundingRect)
    //   touch    the touch point in unit coordinates of the key
    //   strength 0...1 overall opacity of the light
    //   tint     the light's colour
    [[ stitchable ]] half4 feelKeySheen(float2 position, float4 bounds, float2 touch, float strength, half4 tint) {
        float2 size = max(bounds.zw, float2(1.0));
        float2 uv = (position - bounds.xy) / size;
        float scale = min(size.x, size.y);
        float2 d = (position - (bounds.xy + touch * size)) / scale;
        float bloom = exp(-dot(d, d) * 3.4);
        float rim = 1.0 - smoothstep(0.0, 0.16, uv.y);
        float lift = (1.0 - uv.y) * 0.18;
        float a = clamp(strength * (0.72 * bloom + 0.3 * rim + lift), 0.0, 1.0);
        return half4(tint.rgb * half(a), half(a)) * tint.a;
    }

    // One wavelet running out from the touch, bending what it passes over the
    // way a drop disturbs a glass surface. Returns where to sample from.
    //   origin    the touch point, in the layer's points
    //   progress  0...1 along the ripple's life
    //   radius    how far the front travels by the end
    //   amplitude the largest displacement, in points
    [[ stitchable ]] float2 feelRipple(float2 position, float2 origin, float progress, float radius, float amplitude) {
        float2 d = position - origin;
        float dist = length(d);
        float width = max(radius * 0.2, 1.0);
        float x = (dist - progress * radius) / width;
        float wave = exp(-x * x) * sin(x * 3.14159);
        float fade = (1.0 - progress) * (1.0 - progress);
        float2 dir = dist > 0.001 ? d / dist : float2(0.0);
        return position - dir * (wave * amplitude * fade);
    }

    // The gesture trail's ink: full strength at the finger, thinning out
    // toward the tail, with a brighter core right under the finger.
    //   head     the finger, in the canvas' points
    //   span     the distance over which the ink fades to its tail strength
    //   tint     the ink colour
    //   opacity  the ink's opacity at the head
    //   glow     0...1 strength of the core
    [[ stitchable ]] half4 feelTrailInk(float2 position, float2 head, float span, half4 tint, float opacity, float glow) {
        float dist = length(position - head);
        float t = clamp(1.0 - dist / max(span, 1.0), 0.0, 1.0);
        float body = opacity * (0.3 + 0.7 * pow(t, 0.8));
        float core = glow * exp(-(dist * dist) / max(span * span * 0.012, 1.0));
        float a = clamp(body + core * 0.45, 0.0, 1.0);
        half3 rgb = mix(tint.rgb, half3(1.0), half(core * 0.35));
        return half4(rgb * half(a), half(a)) * tint.a;
    }
    """
}
