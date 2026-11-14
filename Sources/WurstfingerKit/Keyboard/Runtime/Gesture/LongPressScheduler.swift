//
//  LongPressScheduler.swift
//  Wurstfinger
//
//  Shared long-press timer + touch-consumption bookkeeping extracted from
//  KeyGestureRecognizer and SlideGestureHandler. Only the timer lifecycle and
//  the consumed-touch flag are shared; each recognizer keeps its own distinct
//  fire-guard predicate (passed as the `fire` closure).
//

import Foundation

/// Owns the long-press timer lifecycle and the consumed-touch flag for a
/// gesture recognizer.
///
/// A reference type so it can live in `@State` and mutate in place across
/// SwiftUI body re-evaluations. The recognizer supplies its fire guard as the
/// `fire` closure, evaluated at fire time so that it reads live `@State`.
///
/// **Main-actor, task-based.** The timer is a `Task` that sleeps and then runs
/// the guard on the main actor; cancelling it is `Task.cancel()`. The previous
/// implementation was a `DispatchWorkItem` on `DispatchQueue.main.asyncAfter`,
/// which is not isolation-checked: nothing in the type system said the work
/// item's closure — which reads `@State` and may type a digit — ran on the main
/// actor. Here that is a compile-time fact. The task sleeps without timer
/// leeway (`Task.sleepWithoutLeeway`), which the bench measured as the
/// lowest-lateness of the three candidates — median ~0.2-0.75 ms against ~0.9-1.8
/// ms for `asyncAfter` and ~1-2.3 ms for a default `Task.sleep`
/// (`docs/performance.md`, section 6).
///
/// **Cancellation is race-free.** Both the cancel and the fire run on the main
/// actor, so a `cancel()` that lands between the sleep ending and the guard
/// running is observed by the `Task.isCancelled` check at the top of the fire
/// step; a stale timer can never run its guard after being replaced.
@MainActor
final class LongPressScheduler {
    private var pending: Task<Void, Never>?

    /// True once a fired long press dispatched an action and thereby consumed
    /// the touch, so the release must not also produce a tap or slide end.
    private(set) var consumedTouch = false

    /// Whether a long-press timer is currently armed.
    var isScheduled: Bool {
        pending != nil
    }

    /// Arms the long-press timer, cancelling any previously armed one. `fire`
    /// is the recognizer's guard predicate, evaluated when the timer fires;
    /// returning `true` marks the touch consumed.
    func schedule(
        after delay: TimeInterval = KeyboardConstants.LongPress.duration,
        fire: @escaping @MainActor () -> Bool
    ) {
        cancel()
        pending = Task { [weak self] in
            do {
                try await Task.sleepWithoutLeeway(for: .seconds(delay))
            } catch {
                return // cancelled while sleeping
            }
            guard !Task.isCancelled else { return }
            self?.runFire(fire)
        }
    }

    /// Cancels any armed timer without touching `consumedTouch`.
    func cancel() {
        pending?.cancel()
        pending = nil
    }

    /// Evaluates the fire guard synchronously and records touch consumption.
    /// Not private so it can be unit-tested without a real 0.7 s timer.
    func runFire(_ fire: @MainActor () -> Bool) {
        pending = nil
        if fire() { consumedTouch = true }
    }

    /// Clears the consumed-touch flag before the next touch sequence.
    func clearConsumed() {
        consumedTouch = false
    }

    /// Drops both halves of a touch that ends without a release: the armed
    /// timer and the consumed-touch flag. Cancelling only the timer would
    /// leave the next touch on this key starting out already consumed.
    func abandon() {
        cancel()
        clearConsumed()
    }
}
