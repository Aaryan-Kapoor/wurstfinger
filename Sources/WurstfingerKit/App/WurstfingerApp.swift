//
//  WurstfingerApp.swift
//  wurstfinger
//
//  Created by Claas Flint on 24.10.25.
//

import SwiftUI

/// The app's entry point. Public so the `Wurstfinger` executable target can
/// launch it from `main.swift`; everything else stays internal to the module.
public struct WurstfingerApp: App {
    @Environment(\.scenePhase) private var scenePhase

    private let screenshotType: ScreenshotType

    private enum ScreenshotType {
        case none
        case keyboardOnly // SCREENSHOT_MODE - keyboard showcase only
        case appStore // APPSTORE_SCREENSHOT_MODE - keyboard with chat UI
    }

    public init() {
        // Migrate a legacy keyboardScale into keyboardWidthPoints BEFORE
        // registering defaults: a registered width would make the key appear
        // present and mask a pending migration.
        LayoutSettings.migrateLegacyScaleIfNeeded(in: SharedDefaults.store)

        // The onboarding checklist is app-only state; installs from earlier
        // versions still hold it in the shared app-group suite, so move it
        // before the views read it.
        OnboardingProgress.migrateFromSharedStoreIfNeeded()

        let defaults: [String: Any] = [
            SettingsKey.keyAspectRatio.rawValue: DeviceLayout.defaultKeyAspectRatio,
            SettingsKey.keyboardWidthPoints.rawValue: DeviceLayout.defaultKeyboardWidth,
            SettingsKey.keyboardHorizontalPosition.rawValue: DeviceLayout.defaultKeyboardPosition
        ]
        SharedDefaults.store.register(defaults: defaults)

        // Tell a running keyboard extension about every settings write, so it
        // updates live instead of at its next appearance.
        SettingsChangeBroadcaster.start()

        // Determine screenshot mode from launch arguments
        let args = ProcessInfo.processInfo.arguments
        if args.contains("APPSTORE_SCREENSHOT_MODE") {
            screenshotType = .appStore
        } else if args.contains("SCREENSHOT_MODE") {
            screenshotType = .keyboardOnly
        } else {
            screenshotType = .none
        }
    }

    public var body: some Scene {
        WindowGroup {
            Group {
                switch screenshotType {
                case .appStore:
                    AppStoreScreenshotView()
                case .keyboardOnly:
                    KeyboardShowcaseView()
                case .none:
                    ContentView()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                // The keyboard extension writes the language selection while
                // the app is backgrounded (globe-key cycling). Refresh the
                // shared singleton on foreground so the settings UI never acts
                // on stale state.
                if newPhase == .active {
                    LanguageSettings.shared.reloadFromStore()
                }
            }
        }
        #if os(macOS)
        // Tall enough for the phone-sized keyboard under the Test tab.
        .defaultSize(width: 520, height: 920)
        #endif
    }
}
