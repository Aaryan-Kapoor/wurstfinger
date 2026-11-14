//
//  DarwinNotificationCenter.swift
//  Wurstfinger
//
//  Cross-process "something changed" signals between the host app and the
//  keyboard extension.
//

import Dispatch
import Foundation
import notify

/// A thin wrapper over the system-wide Darwin notification center
/// (`notify_post` / `notify_register_dispatch` from `<notify.h>`).
///
/// **Why.** `UserDefaults.didChangeNotification` only fires inside the process
/// that wrote the value, so the keyboard extension could notice a host-app
/// settings change only when it next appeared (`viewWillAppear`). A Darwin
/// notification crosses the process boundary, carries no payload (the reader
/// re-reads the shared defaults) and is available on iOS and macOS alike, so
/// the host posts one after writing shared settings and a visible keyboard
/// updates live.
struct DarwinNotificationCenter: Sendable {
    static let shared = DarwinNotificationCenter()

    /// Posted by the host app after it writes shared settings.
    static let settingsChanged = "de.akator.wurstfinger.settingsChanged"

    /// Handlers run here, never on the main thread: the stream's consumer
    /// decides where the work happens, and the system callback itself only
    /// forwards into the stream.
    private static let callbackQueue = DispatchQueue(
        label: "de.akator.wurstfinger.darwin-notifications",
        qos: .userInitiated
    )

    /// Posts `name` to every process listening for it (including this one).
    func post(_ name: String = DarwinNotificationCenter.settingsChanged) {
        notify_post(name)
    }

    /// A stream yielding once per posting of `name`, from any process.
    ///
    /// The system registration happens synchronously inside this call, so a
    /// notification posted any time after it returns is delivered. Bursts
    /// coalesce to one pending signal (`bufferingNewest(1)`): a reader that is
    /// busy for a moment sees "changed" once, which is all it needs. Dropping
    /// the stream (or cancelling the task iterating it) cancels the system
    /// registration.
    func notifications(named name: String = DarwinNotificationCenter.settingsChanged) -> AsyncStream<Void> {
        AsyncStream(Void.self, bufferingPolicy: .bufferingNewest(1)) { continuation in
            var token: Int32 = 0
            let status = notify_register_dispatch(name, &token, Self.callbackQueue) { _ in
                continuation.yield()
            }
            guard status == UInt32(NOTIFY_STATUS_OK) else {
                continuation.finish()
                return
            }
            let registration = token
            continuation.onTermination = { _ in
                notify_cancel(registration)
            }
        }
    }
}
