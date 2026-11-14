//
//  SettingsChangeBroadcaster.swift
//  Wurstfinger
//
//  Announces host-app settings writes to the keyboard extension.
//

import Foundation

/// Posts `DarwinNotificationCenter.settingsChanged` whenever the host app
/// writes the shared settings store.
///
/// The keyboard extension is a separate process: `UserDefaults` change
/// notifications never cross into it, so it could only pick up a settings
/// change at its next `viewWillAppear`. The Darwin notification this posts
/// crosses the boundary (and carries no payload — the keyboard re-reads the
/// shared defaults itself), letting a *visible* keyboard follow a slider drag
/// in the app live. The keyboard debounces the resulting burst, so this posts
/// on every write without coalescing.
///
/// Only the host app starts this. The extension writes the shared store too
/// (language cycling, label toggles) but must not echo a signal back at
/// itself or at an app that is not listening.
@MainActor
enum SettingsChangeBroadcaster {
    /// Holds the observation for the life of the process.
    private static var observation: TaskHandle?

    /// Starts broadcasting; idempotent.
    static func start(
        defaults: UserDefaults = SharedDefaults.store,
        center: DarwinNotificationCenter = .shared
    ) {
        guard observation == nil else { return }
        let writes = NotificationCenter.default.signals(
            named: UserDefaults.didChangeNotification, object: defaults
        )
        observation = TaskHandle(Task {
            for await _ in writes {
                center.post()
            }
        })
    }
}
