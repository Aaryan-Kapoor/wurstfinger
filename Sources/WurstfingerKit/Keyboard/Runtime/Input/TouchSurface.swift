//
//  TouchSurface.swift
//  Wurstfinger
//
//  The one view that receives the keyboard's touches and hands them to the
//  input engine.
//

import SwiftUI

/// Everything the engine needs from the view layer for the current layout.
@MainActor
struct TouchSurfaceConfiguration {
    var geometry: GridGeometry
    var keys: [String: KeyDefinition]
    var tuning: GestureTuning
    var isLongPressEnabled: Bool
    var actions: TouchEngineActions

    func apply(to engine: TouchEngine) {
        engine.configure(
            geometry: geometry,
            keys: keys,
            tuning: tuning,
            isLongPressEnabled: isLongPressEnabled,
            actions: actions
        )
    }
}

#if os(iOS)
import UIKit

/// A transparent native view laid over the key grid that receives every touch
/// on it — all fingers, at the hardware sample rate — and forwards them to a
/// `TouchEngine` without any gesture recognizer in between.
///
/// Configuration happens in `updateUIView`, the representable's sanctioned
/// place for imperative updates: it runs right after SwiftUI re-evaluates the
/// grid, so the engine's layout and settings are current before the next touch
/// event can arrive.
struct TouchSurface: UIViewRepresentable {
    let engine: TouchEngine
    let configuration: TouchSurfaceConfiguration

    func makeUIView(context _: Context) -> TouchSurfaceView {
        TouchSurfaceView(engine: engine)
    }

    func updateUIView(_ view: TouchSurfaceView, context _: Context) {
        view.engine = engine
        configuration.apply(to: engine)
    }
}

/// See `TouchSurface`.
final class TouchSurfaceView: UIView {
    var engine: TouchEngine {
        didSet {
            if engine !== oldValue { engine.updateSize(bounds.size) }
        }
    }

    /// Reused per event, so a moving finger allocates nothing.
    private var samples: [TouchSample] = []
    private var predicted: [CGPoint] = []

    init(engine: TouchEngine) {
        self.engine = engine
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        backgroundColor = .clear
        // Touch plumbing only: VoiceOver reads and activates the keys beneath,
        // and an activation's synthesized touch lands here like a finger.
        isAccessibilityElement = false
        samples.reserveCapacity(16)
        predicted.reserveCapacity(4)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        engine.updateSize(bounds.size)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with _: UIEvent?) {
        for touch in touches {
            engine.began(Self.pointerID(touch), at: touch.location(in: self), time: touch.timestamp)
            InputLatencyProbe.shared.touchHandled(eventTime: touch.timestamp)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            samples.removeAll(keepingCapacity: true)
            // Every hardware sample since the last event — up to four per
            // frame on a 240 Hz digitizer — not just the latest.
            if let coalesced = event?.coalescedTouches(for: touch), !coalesced.isEmpty {
                for sample in coalesced {
                    samples.append(TouchSample(location: sample.location(in: self), time: sample.timestamp))
                }
            } else {
                samples.append(TouchSample(location: touch.location(in: self), time: touch.timestamp))
            }
            predicted.removeAll(keepingCapacity: true)
            for prediction in event?.predictedTouches(for: touch) ?? [] {
                predicted.append(prediction.location(in: self))
            }
            engine.moved(Self.pointerID(touch), samples: samples, predicted: predicted)
            InputLatencyProbe.shared.touchHandled(eventTime: touch.timestamp)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with _: UIEvent?) {
        for touch in touches {
            engine.ended(Self.pointerID(touch), at: touch.location(in: self), time: touch.timestamp)
            // Includes classification, dispatch and `insertText`.
            InputLatencyProbe.shared.touchHandled(eventTime: touch.timestamp)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with _: UIEvent?) {
        for touch in touches {
            engine.cancelled(Self.pointerID(touch))
        }
    }

    /// A `UITouch` is the same object from began to ended, so its identity is
    /// the finger's identity.
    private static func pointerID(_ touch: UITouch) -> PointerID {
        Int(bitPattern: UInt(bitPattern: ObjectIdentifier(touch)))
    }
}

#elseif os(macOS)
import AppKit

/// The Mac stand-in: the mouse is one finger. Lets the Mac build's test area
/// type through the same engine the keyboard uses.
struct TouchSurface: NSViewRepresentable {
    let engine: TouchEngine
    let configuration: TouchSurfaceConfiguration

    func makeNSView(context _: Context) -> TouchSurfaceView {
        TouchSurfaceView(engine: engine)
    }

    func updateNSView(_ view: TouchSurfaceView, context _: Context) {
        view.engine = engine
        configuration.apply(to: engine)
    }
}

/// See `TouchSurface`.
final class TouchSurfaceView: NSView {
    var engine: TouchEngine {
        didSet {
            if engine !== oldValue { engine.updateSize(bounds.size) }
        }
    }

    private static let mouse: PointerID = 0

    init(engine: TouchEngine) {
        self.engine = engine
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Top-left origin, like the SwiftUI space the grid lays out in.
    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        engine.updateSize(newSize)
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        engine.began(Self.mouse, at: location(of: event), time: event.timestamp)
        InputLatencyProbe.shared.touchHandled(eventTime: event.timestamp)
    }

    override func mouseDragged(with event: NSEvent) {
        engine.moved(Self.mouse, samples: [TouchSample(location: location(of: event), time: event.timestamp)])
        InputLatencyProbe.shared.touchHandled(eventTime: event.timestamp)
    }

    override func mouseUp(with event: NSEvent) {
        engine.ended(Self.mouse, at: location(of: event), time: event.timestamp)
        InputLatencyProbe.shared.touchHandled(eventTime: event.timestamp)
    }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }
}
#endif
