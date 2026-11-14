//
//  TimerSource.swift
//  Wurstfinger
//
//  The one place the input path gets a deadline from, so tests can hold the
//  clock in their hand.
//

import Foundation

/// A one-shot timer and the clock it is measured on.
///
/// Every deadline on the input path — the long press, the rollover hold, the
/// trail's fade-out, the settings-signal debounce — used to spawn its own
/// `Task` that slept on the wall clock. Correct, but it meant that the only
/// way to test "the long press fires at 0.7 s" was to wait 0.7 s, and on a
/// machine busy enough the wait lost. A `TimerSource` is what those places
/// ask instead: production hands them `SystemTimerSource` (a main-actor task
/// sleeping without leeway, exactly what they did before), tests hand them a
/// `ManualTimerSource` and advance it by hand, so a timing test cannot fail
/// because the machine is busy — it never waits for anything.
///
/// `now` is in seconds on the clock touch timestamps use (system uptime in
/// production); the engine compares its touch-time deadlines against it, so
/// a test that drives touches with synthetic times drives the same times into
/// the manual source.
@MainActor
protocol TimerSource: AnyObject {
    /// The current time, in seconds.
    var now: TimeInterval { get }

    /// Arms a one-shot timer: `action` runs on the main actor once `delay`
    /// seconds have passed, unless the handle is cancelled first. A
    /// non-positive delay still runs asynchronously, never inside the call.
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> TimerHandle

    /// Makes a `Waker` that runs `action` on the main actor, soon after a
    /// `poke()`, without spending a timer per poke. For work a keystroke
    /// wants done *after* it (the word completion lookup), where arming a
    /// fresh timer on every keystroke would put an allocation on the
    /// keystroke path.
    func makeWaker(_ action: @escaping @MainActor () -> Void) -> Waker
}

extension TimerSource {
    /// A waker built on `schedule(after: 0)`: a poke arms one timer and pokes
    /// that arrive before it fires share it. What a manual clock wants (a test
    /// advances it by hand), and what any source gets without overriding.
    func makeWaker(_ action: @escaping @MainActor () -> Void) -> Waker {
        let pending = PendingTimer()
        return Waker(
            poke: { [self] in
                guard pending.handle == nil else { return }
                pending.handle = schedule(after: 0) {
                    pending.handle = nil
                    action()
                }
            },
            cancel: {
                pending.handle?.cancel()
                pending.handle = nil
            }
        )
    }
}

/// The timer a `Waker` built on `schedule` has armed, if any.
@MainActor
private final class PendingTimer {
    var handle: TimerHandle?
}

/// "Run this soon", pokeable from the keystroke path without allocating.
///
/// `poke()` asks for one run of the action it was made with, on the main
/// actor after the current turn; pokes that come in before it runs share it.
/// The production source backs it with one long-lived task reading an
/// `AsyncStream` (a poke is a `yield` into a one-element buffer), so a poke
/// costs no timer and no allocation; the manual clock backs it with
/// `schedule(after: 0)`.
@MainActor
final class Waker {
    private let onPoke: @MainActor () -> Void
    private let onCancel: @MainActor () -> Void
    /// Whatever must live as long as the waker (the task reading the stream;
    /// its `TaskHandle` cancels it when the waker goes).
    private let keepAlive: AnyObject?

    init(
        poke: @escaping @MainActor () -> Void,
        cancel: @escaping @MainActor () -> Void = {},
        keepAlive: AnyObject? = nil
    ) {
        onPoke = poke
        onCancel = cancel
        self.keepAlive = keepAlive
    }

    /// Asks for the action to run soon. A no-op while a run is already pending.
    func poke() {
        onPoke()
    }

    /// Drops a pending run where the source can (the manual clock's timer).
    /// The production source cannot take a buffered poke back; callers whose
    /// action may find nothing to do must tolerate a late run either way.
    func cancelPending() {
        onCancel()
    }
}

/// An armed timer. Cancelling it is idempotent; a fired timer reads as
/// inactive.
@MainActor
final class TimerHandle {
    private(set) var isActive = true
    private let onCancel: @MainActor () -> Void

    init(onCancel: @escaping @MainActor () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        guard isActive else { return }
        isActive = false
        onCancel()
    }

    /// The source reports that the timer ran.
    fileprivate func markFired() {
        isActive = false
    }
}

/// The production source: a main-actor `Task` that sleeps with no timer
/// leeway (`Task.sleepWithoutLeeway`, measured in `docs/performance.md` as the
/// lowest-lateness of the mechanisms available) and runs the action on the
/// actor. Cancellation is `Task.cancel()`, re-checked after the sleep on the
/// actor, so a cancel that lands between wake-up and action wins.
@MainActor
final class SystemTimerSource: TimerSource {
    private let clock: () -> TimeInterval

    /// - Parameter now: The clock to report; system uptime by default, the
    ///   clock `UITouch.timestamp` and `NSEvent.timestamp` use.
    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        clock = now
    }

    var now: TimeInterval { clock() }

    func makeWaker(_ action: @escaping @MainActor () -> Void) -> Waker {
        // One element of buffer, newest wins: a poke while a run is pending
        // changes nothing, and a poke while the action is running asks for one
        // more run after it.
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let reader = TaskHandle(Task { @MainActor in
            for await _ in stream {
                guard !Task.isCancelled else { return }
                action()
            }
        })
        return Waker(poke: { continuation.yield() }, keepAlive: reader)
    }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> TimerHandle {
        let box = TaskBox()
        let handle = TimerHandle { box.task?.cancel() }
        box.task = Task { @MainActor in
            do {
                try await Task.sleepWithoutLeeway(for: .seconds(max(delay, 0)))
            } catch {
                return // cancelled while sleeping
            }
            guard !Task.isCancelled, handle.isActive else { return }
            handle.markFired()
            action()
        }
        return handle
    }

    /// Lets the handle refer to the task that is created after it.
    private final class TaskBox {
        var task: Task<Void, Never>?
    }
}

/// A source whose time only moves when told to: `advance` runs every timer
/// whose deadline it passes, in deadline order, with `now` set to that
/// deadline while it runs (so a timer that arms another sees a consistent
/// clock). For tests and tools; nothing in the keyboard uses it.
@MainActor
final class ManualTimerSource: TimerSource {
    private struct Entry {
        let order: UInt64
        let deadline: TimeInterval
        let handle: TimerHandle
        let action: @MainActor () -> Void
    }

    private(set) var now: TimeInterval
    private var entries: [Entry] = []
    private var nextOrder: UInt64 = 0

    /// How many timers were ever armed, fired or not: lets a test know that a
    /// burst of signals has all been consumed (each one arms a timer).
    var scheduledTotal: Int { Int(nextOrder) }

    init(now: TimeInterval = 0) {
        self.now = now
    }

    /// Timers armed and not yet fired or cancelled.
    var pendingCount: Int {
        entries.count
    }

    /// The earliest armed deadline, if any.
    var nextDeadline: TimeInterval? {
        entries.map(\.deadline).min()
    }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> TimerHandle {
        let order = nextOrder
        nextOrder &+= 1
        let handle = TimerHandle { [weak self] in
            self?.entries.removeAll { $0.order == order }
        }
        entries.append(Entry(order: order, deadline: now + max(delay, 0), handle: handle, action: action))
        return handle
    }

    /// Moves the clock to `time`, firing every timer due on the way.
    func advance(to time: TimeInterval) {
        precondition(time >= now, "a manual clock does not run backwards")
        while let next = entries.filter({ $0.deadline <= time }).min(by: {
            ($0.deadline, $0.order) < ($1.deadline, $1.order)
        }) {
            entries.removeAll { $0.order == next.order }
            now = max(now, next.deadline)
            next.handle.markFired()
            next.action()
        }
        now = time
    }

    /// Moves the clock forward by `delta`, firing every timer due on the way.
    func advance(by delta: TimeInterval) {
        advance(to: now + delta)
    }
}
