//
//  KeyboardViewModel+Input.swift
//  Wurstfinger
//
//  The view model's side of the input engine: the callbacks the engine
//  dispatches into, and the side-effect-free resolution behind the live
//  flick preview.
//

import CoreGraphics
import Foundation

extension KeyboardViewModel {
    func makeTouchEngineActions() -> TouchEngineActions {
        TouchEngineActions(
            touchDown: { [weak self] _ in
                self?.touchDown()
            },
            gesture: { [weak self] key, classification in
                self?.handleClassification(classification, keyId: key.id)
            },
            slide: { [weak self] key, phase in
                self?.handleSlide(key, phase: phase)
            },
            longPress: { [weak self] key in
                self?.handleGesture(.longPress, keyId: key.id, isReturn: false) ?? false
            },
            previewLabel: { [weak self] key, classification in
                self?.previewLabel(for: classification, keyId: key.id)
            },
            // Feel hooks (`KeyboardViewModel+Feel.swift`).
            candidateChanged: { [weak self] key, old, new in
                self?.feelCandidateChanged(on: key, from: old, to: new)
            },
            released: { [weak self] key, classification in
                self?.feelReleased(key, classification: classification)
            },
            releaseHandled: { [weak self] in
                self?.feel.flushRelease()
            },
            longPressPhase: { [weak self] key, phase in
                self?.feelLongPress(key, phase: phase)
            }
        )
    }

    /// What releasing with `classification` on `keyId` would do, as the guide
    /// card shows it: a long swipe's action glyph when one would fire (it takes
    /// precedence, as in `handleClassification`), otherwise the key's binding.
    func previewLabel(for classification: GestureClassification, keyId: String) -> String? {
        if let action = gestureTuning.longSwipe.action(for: classification) {
            return action.previewGlyph
        }
        return previewLabel(for: classification.gesture, keyId: keyId, isReturn: classification.isReturn)
    }

    /// What `gesture` on `keyId` would type in the active mode, as its label —
    /// resolved exactly as `handleGesture` would resolve it, but without
    /// dispatching anything. Drives the preview bubble while a finger is
    /// still moving, so it must stay a pure lookup.
    func previewLabel(for gesture: GestureType, keyId: String, isReturn: Bool) -> String? {
        guard let compiled = compiledDefinition?.mode(activeModeName),
              let slot = compiled.slot(for: keyId)
        else { return nil }
        if gesture.isCircular {
            // Same outcome `performGesture` would dispatch: explicit binding,
            // the uppercase centre letter, then the opposite direction.
            switch compiled.circular(slot: slot, clockwise: gesture == .circularClockwise) {
            case let .binding(index): return compiled.binding(at: index).label
            case let .commitUppercase(text): return text
            case .none: return nil
            }
        }
        guard let binding = compiled.binding(slot: slot, gesture: gesture, isReturn: isReturn) else { return nil }
        // Text bindings preview the text they commit, which for a return swipe
        // (and the shifted forms the resolvers produce) can differ from the
        // label the key's hint shows.
        if case let .commitText(text) = binding.action, !text.isEmpty { return text }
        return binding.label
    }

    /// The grid geometry the engine hit-tests against at `containerWidth`, and
    /// the grid's size — computed the way `DataDrivenKeyboardRootView` lays the
    /// grid out. Hosts without a touch surface (the scenario harness, the
    /// snapshot tool) configure the engine from this; the keyboard itself gets
    /// the size from the surface's own bounds.
    func gridGeometry(forContainerWidth containerWidth: CGFloat) -> (geometry: GridGeometry, size: CGSize)? {
        guard let arrangement = currentArrangement else { return nil }
        let metrics = layoutMetrics(forContainerWidth: containerWidth)
        let cells = GridLayoutSolver.solve(arrangement)
        let rows = cells.map { $0.row + $0.rowSpan }.max() ?? 0
        let geometry = GridGeometry(
            cells: cells,
            columns: arrangement.columns,
            rowHeight: metrics.rowHeight,
            horizontalSpacing: KeyboardConstants.Layout.gridHorizontalSpacing,
            verticalSpacing: KeyboardConstants.Layout.gridVerticalSpacing,
            cellAspectRatio: metrics.cellAspectRatio
        )
        let size = CGSize(
            width: metrics.keyboardWidth - 2 * KeyboardConstants.Layout.horizontalPadding,
            height: CGFloat(rows) * metrics.rowHeight
                + CGFloat(max(rows - 1, 0)) * KeyboardConstants.Layout.gridVerticalSpacing
        )
        return (geometry, size)
    }

    /// Configures the engine for the active mode without a touch surface (see
    /// `gridGeometry(forContainerWidth:)`).
    func configureTouchEngine(containerWidth: CGFloat, isLongPressEnabled: Bool) {
        guard let mode = activeModeFromDefinition,
              let (geometry, size) = gridGeometry(forContainerWidth: containerWidth)
        else { return }
        touchEngine.configure(
            geometry: geometry,
            keys: mode.keys,
            tuning: gestureTuning,
            isLongPressEnabled: isLongPressEnabled,
            actions: touchEngineActions
        )
        touchEngine.updateSize(size)
    }
}

extension KeyAction {
    /// A compact glyph for an action that types no text of its own, for the
    /// guide card. Text actions show their text instead.
    var previewGlyph: String {
        switch self {
        case let .commitText(text): text
        case .tab: "⇥"
        case .backTab: "⇤"
        case .escape: "⎋"
        case .newline: "⏎"
        case .space: "␣"
        case .deleteBackward: "⌫"
        case .deleteForward: "⌦"
        case .deleteWordBackward: "⌫⌫"
        case .deleteWordForward: "⌦⌦"
        case .lineUp: "↑"
        case .lineDown: "↓"
        case .cycleWordCase: "Aa"
        case .switchToPreviousLanguage: "🌐"
        case .toggleUtilityColumnSide: "⇆"
        case .lineStart: "⇱"
        case .lineEnd: "⇲"
        case .documentStart: "⤒"
        case .documentEnd: "⤓"
        case .dismissKeyboard: "⌄"
        case .copy: "⧉"
        case .paste: "⎘"
        case .cut, .cutAll: "✂"
        case let .moveCursor(offset): offset < 0 ? "◂" : "▸"
        case .advanceToNextInputMode, .switchToNextLanguage: "🌐"
        case .capitalizeWord: "Aa"
        case let .switchMode(mode):
            switch mode {
            case ModeNames.control: TerminalModifier.control.backLabel
            case ModeNames.alt: TerminalModifier.alt.backLabel
            default: mode
            }
        case let .compose(trigger): trigger
        case .cycleAccents: "◌́"
        case .none: ""
        }
    }
}
