//
//  KeyboardViewModel+Behaviours.swift
//  Wurstfinger
//
//  Where the user's long-press and circle choices meet the compiled tables.
//

import Foundation

extension KeyboardViewModel {
    /// The binding `gesture` fires on the key at `slot`, with the long-press
    /// choice applied: a hold resolves per `typingBehavior.longPress`
    /// (Capitals reads its own table), everything else is the compiled table.
    ///
    /// The one resolution `performGesture`, the guide's preview and the feel
    /// layer share, so what is typed, what the guide shows and what the haptics
    /// pop can never disagree about a hold. A pure lookup: no store read, no
    /// allocation.
    @inline(__always)
    func resolvedBinding(in compiled: CompiledMode, slot: Int, gesture: GestureType, isReturn: Bool) -> KeyBinding? {
        if gesture == .longPress {
            return compiled.longPressBinding(slot: slot, type: typingBehavior.longPress)
        }
        return compiled.binding(slot: slot, gesture: gesture, isReturn: isReturn)
    }

    /// What a circle (`gesture` is `.circularClockwise` or
    /// `.circularCounterclockwise`) does on the key at `slot`, with that
    /// direction's circle behaviour applied. Shared like `resolvedBinding`.
    @inline(__always)
    func resolvedCircle(in compiled: CompiledMode, slot: Int, gesture: GestureType) -> CircularOutcome {
        let isClockwise = gesture == .circularClockwise
        return compiled.circular(
            slot: slot,
            clockwise: isClockwise,
            type: isClockwise ? typingBehavior.clockwiseCircle : typingBehavior.counterclockwiseCircle
        )
    }
}
