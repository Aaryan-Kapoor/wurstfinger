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

    static func settings(scheme: ColorScheme) -> Shot {
        ScenarioEnvironment.reset()
        let device = Device.iPhone15
        device.activate()
        return Shot(
            size: device.size, scheme: scheme,
            content: AnyView(SettingsView().formStyle(.grouped).frame(width: device.width, height: device.size.height)),
            hosted: true
        )
    }
}
