//
//  TaskHandle.swift
//  Wurstfinger
//
//  Ties a long-lived task to the lifetime of its owner.
//

import Foundation

/// Cancels its task when the last reference goes away.
///
/// The view model and the keyboard controller are main-actor classes, and a
/// non-isolated `deinit` may not touch their main-actor state. Holding the
/// observation task in this `Sendable` box sidesteps that: the owner just
/// drops the box (or is deallocated) and the task is cancelled, with no
/// `deinit` on the owner at all.
final class TaskHandle: Sendable {
    private let task: Task<Void, Never>

    init(_ task: Task<Void, Never>) {
        self.task = task
    }

    /// Cancels now, without waiting for deallocation.
    func cancel() {
        task.cancel()
    }

    deinit {
        task.cancel()
    }
}

/// Removes a `NotificationCenter` observer when it is deallocated.
///
/// `NSObjectProtocol` observer tokens are not `Sendable`, so they cannot be
/// stored on a main-actor class and removed from its non-isolated `deinit`.
/// The token is only ever used to call `removeObserver`, which
/// `NotificationCenter` documents as thread-safe.
final class ObserverToken: @unchecked Sendable {
    // @unchecked Sendable: `observer` is an immutable `let` that is only passed
    // to `NotificationCenter.removeObserver`, which is thread-safe; nothing
    // else reads or mutates it.
    private let center: NotificationCenter
    private let observer: NSObjectProtocol

    init(center: NotificationCenter = .default, observer: NSObjectProtocol) {
        self.center = center
        self.observer = observer
    }

    deinit {
        center.removeObserver(observer)
    }
}

extension NotificationCenter {
    /// A stream that yields once per posting of `name` (from `object`, when
    /// given), without carrying the `Notification` itself.
    ///
    /// The payload is dropped on purpose: `Notification` is not `Sendable`, so
    /// carrying it across an async boundary is a data-race diagnostic in Swift
    /// 6, and every consumer here only needs "something changed". Buffering
    /// keeps just the newest pending signal, which is all a "reload settings"
    /// consumer can use, so a burst of posts cannot pile up behind a slow
    /// reader.
    func signals(named name: Notification.Name, object: AnyObject? = nil) -> AsyncStream<Void> {
        AsyncStream(Void.self, bufferingPolicy: .bufferingNewest(1)) { continuation in
            let token = ObserverToken(
                center: self,
                observer: addObserver(forName: name, object: object, queue: nil) { _ in
                    continuation.yield()
                }
            )
            continuation.onTermination = { _ in
                // Captured only to keep it alive; deallocating it removes the
                // observer.
                withExtendedLifetime(token) {}
            }
        }
    }
}

extension Task where Success == Never, Failure == Never {
    /// Sleeps `duration` on the continuous clock with **no timer leeway**.
    ///
    /// `Task.sleep(for:)` leaves the system free to coalesce the wake-up with
    /// other timers, which measurably delays it (see `docs/performance.md`,
    /// section 6: the default sleep fires a median ~1-2 ms late against ~0.2-0.7
    /// ms for a zero-tolerance sleep, and `DispatchQueue.asyncAfter` sits
    /// between). The long-press timer and the trail fade each fire once per
    /// gesture, so giving up coalescing costs nothing worth saving, and the
    /// press fires when the user expects it. Throws `CancellationError` like
    /// any sleep.
    static func sleepWithoutLeeway(for duration: Duration) async throws {
        try await sleep(
            until: ContinuousClock.now.advanced(by: duration),
            tolerance: .zero,
            clock: .continuous
        )
    }
}
