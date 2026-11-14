//
//  KeyPressState.swift
//  Wurstfinger
//
//  What the input engine shows while a finger is down: which keys are
//  pressed, and which binding the in-flight gesture is heading for.
//

import CoreGraphics
import Observation

/// One key's live touch state.
///
/// A separate `@Observable` object per key, so a key view that reads its own
/// cell is invalidated by its own touches and nobody else's: pressing one key
/// re-renders that key alone, and the 120 Hz stream of drag samples re-renders
/// nothing at all unless the predicted binding actually changes.
@MainActor
@Observable
final class KeyPressCell {
    /// A finger is on the key.
    fileprivate(set) var isPressed = false

    /// The gesture the in-flight touch would produce if released now, when it
    /// is something other than a tap. Drives the emphasized hint on the key.
    fileprivate(set) var candidate: GestureType?

    /// Whether `candidate` is a return swipe.
    fileprivate(set) var candidateIsReturn = false
}

/// The guide card for the finger most recently put down on a flick key: where
/// the key is, which of its gestures the finger is heading for, and what that
/// gesture would type.
struct TouchGuide: Equatable, Sendable {
    let keyId: String
    /// The key's touch frame, in the grid's coordinate space.
    let keyFrame: CGRect
    /// Identifies the touch, so a new touch on the same key gets a fresh card.
    let touchID: UInt64
    /// The gesture releasing now would produce, unless it is a tap.
    var candidate: GestureType?
    var isReturn = false
    /// What the candidate would type, resolved by the view model exactly as
    /// the release will resolve it (shift state and return swipes included).
    var label: String?
}

/// The live touch state of one keyboard: a cell per key and the guide card.
///
/// The registry itself is not observed: views reach their own cell through
/// `cell(for:)`, and only the cell's properties are tracked. The engine writes
/// through the registry, only on actual changes.
@MainActor
@Observable
final class KeyPressRegistry {
    @ObservationIgnored private var cells: [String: KeyPressCell] = [:]

    /// The guide card's content, or nil when no finger is on a flick key.
    /// Observed by the guide overlay only, and changed only when the target
    /// changes — not per drag sample.
    private(set) var guide: TouchGuide?

    /// The cell for `keyId`, created on first use.
    func cell(for keyId: String) -> KeyPressCell {
        if let cell = cells[keyId] { return cell }
        let cell = KeyPressCell()
        cells[keyId] = cell
        return cell
    }

    func setPressed(_ isPressed: Bool, keyId: String) {
        let cell = cell(for: keyId)
        if cell.isPressed != isPressed { cell.isPressed = isPressed }
        if !isPressed { setCandidate(nil, isReturn: false, keyId: keyId) }
    }

    func setCandidate(_ gesture: GestureType?, isReturn: Bool, keyId: String) {
        let cell = cell(for: keyId)
        if cell.candidate != gesture { cell.candidate = gesture }
        if cell.candidateIsReturn != isReturn { cell.candidateIsReturn = isReturn }
    }

    func setGuide(_ guide: TouchGuide?) {
        if self.guide != guide { self.guide = guide }
    }

    /// Updates the guide for touch `touchID`, if it is the one shown.
    func updateGuide(touchID: UInt64, _ update: (inout TouchGuide) -> Void) {
        guard var current = guide, current.touchID == touchID else { return }
        update(&current)
        setGuide(current)
    }

    /// Hides the guide for touch `touchID`, if it is the one shown.
    func clearGuide(touchID: UInt64) {
        if guide?.touchID == touchID { guide = nil }
    }

    /// Releases every key: the touches were cancelled or the layout changed.
    func clearAll() {
        for (keyId, cell) in cells where cell.isPressed || cell.candidate != nil {
            setPressed(false, keyId: keyId)
        }
        setGuide(nil)
    }

    /// Ids of the keys currently pressed.
    var pressedKeyIds: Set<String> {
        Set(cells.filter { $0.value.isPressed }.map(\.key))
    }
}
