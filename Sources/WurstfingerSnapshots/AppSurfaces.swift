//
//  AppSurfaces.swift
//  WurstfingerSnapshots
//
//  The app's own screens: the App Store screenshot view, the keyboard
//  showcase, and the settings list.
//

import SwiftUI
@testable import WurstfingerKit

@MainActor
enum AppSurfaces {
    static func appStore(device: Device, scheme: ColorScheme) -> Shot {
        ScenarioEnvironment.reset()
        device.activate()
        return Shot(
            size: device.size, scheme: scheme,
            content: AnyView(AppStoreScreenshotView().frame(width: device.width, height: device.size.height)),
            hosted: true
        )
    }

    static func showcase(device: Device, scheme: ColorScheme) -> Shot {
        ScenarioEnvironment.reset()
        device.activate()
        return Shot(
            size: device.size, scheme: scheme,
            content: AnyView(KeyboardShowcaseView().frame(width: device.width, height: device.size.height)),
            hosted: true
        )
    }

    static func settings(scheme: ColorScheme, longPress: LongPressType = .off) -> Shot {
        ScenarioEnvironment.reset()
        let device = Device.iPhone15
        device.activate()
        SharedDefaults.store.set(longPress.rawValue, forKey: SettingsKey.longPressBehaviour.rawValue)
        return Shot(
            size: device.size, scheme: scheme,
            content: AnyView(SettingsView().formStyle(.grouped).frame(width: device.width, height: device.size.height)),
            hosted: true
        )
    }

    /// The text-replacement list, filled with a few shortcuts (or empty).
    static func textReplacement(scheme: ColorScheme, isEmpty: Bool = false) -> Shot {
        ScenarioEnvironment.reset()
        let device = Device.iPhone15
        device.activate()
        if !isEmpty {
            SharedDefaults.store.set(
                TextReplacementTable.encode([
                    TextReplacementEntry(shortcut: "omw", phrase: "On my way!"),
                    TextReplacementEntry(shortcut: "gm", phrase: "Good morning"),
                    TextReplacementEntry(shortcut: "addr", phrase: "Musterstraße 1, 10115 Berlin"),
                    TextReplacementEntry(shortcut: "sig", phrase: "Best regards,\nRobert"),
                    TextReplacementEntry(shortcut: "brb", phrase: "Be right back"),
                ]),
                forKey: SettingsKey.textReplacements.rawValue
            )
        }
        return Shot(
            size: device.size, scheme: scheme,
            content: AnyView(
                NavigationStack { TextReplacementView() }
                    .formStyle(.grouped).frame(width: device.width, height: device.size.height)
            ),
            hosted: true
        )
    }

    /// The haptics screen (Full Access synced as granted), with the
    /// Detailed Haptics switch.
    static func haptics(scheme: ColorScheme) -> Shot {
        ScenarioEnvironment.reset()
        let device = Device.iPhone15
        device.activate()
        SharedDefaults.store.set(true, forKey: SettingsKey.keyboardFullAccess.rawValue)
        return Shot(
            size: device.size, scheme: scheme,
            content: AnyView(
                NavigationStack { HapticSettingsView() }
                    .frame(width: device.width, height: device.size.height)
            ),
            hosted: true
        )
    }

    /// The style screen, with the Key Animations switch.
    static func style(scheme: ColorScheme) -> Shot {
        ScenarioEnvironment.reset()
        let device = Device.iPhone15
        device.activate()
        return Shot(
            size: device.size, scheme: scheme,
            content: AnyView(
                NavigationStack { StyleSettingsView() }
                    .frame(width: device.width, height: device.size.height)
            ),
            hosted: true
        )
    }

    /// The circle behaviours (Expert): clockwise a capital, counter-clockwise a digit.
    static func circles(scheme: ColorScheme) -> Shot {
        ScenarioEnvironment.reset()
        let device = Device.iPhone15
        device.activate()
        SharedDefaults.store.set(true, forKey: SettingsKey.expertModeEnabled.rawValue)
        SharedDefaults.store.set(CircleType.uppercase.rawValue, forKey: SettingsKey.clockwiseCircleBehaviour.rawValue)
        SharedDefaults.store.set(CircleType.digit.rawValue, forKey: SettingsKey.counterclockwiseCircleBehaviour.rawValue)
        return Shot(
            size: device.size, scheme: scheme,
            content: AnyView(
                NavigationStack { CircleSettingsView() }
                    .formStyle(.grouped).frame(width: device.width, height: device.size.height)
            ),
            hosted: true
        )
    }

    /// The long-swipe settings with the feature switched on.
    static func longSwipes(scheme: ColorScheme) -> Shot {
        ScenarioEnvironment.reset()
        let device = Device.iPhone15
        device.activate()
        SharedDefaults.store.set(true, forKey: SettingsKey.expertModeEnabled.rawValue)
        SharedDefaults.store.set(true, forKey: SettingsKey.isLongSwipeEnabled.rawValue)
        return Shot(
            size: device.size, scheme: scheme,
            content: AnyView(
                NavigationStack { LongSwipeSettingsView() }
                    .formStyle(.grouped).frame(width: device.width, height: device.size.height)
            ),
            hosted: true
        )
    }
}
