//
//  Device.swift
//  WurstfingerSnapshots
//
//  The screens the tool renders for. A device sets the simulated screen the
//  keyboard's layout code reads (`UIScreen.main.bounds`, the device idiom), so
//  the same width rules that apply on a phone or an iPad apply here.
//

import CoreGraphics
import Foundation
@testable import WurstfingerKit

struct Device {
    var name: String
    /// Screen size in points, in the orientation being rendered.
    var size: CGSize
    var isPad: Bool

    var width: CGFloat { size.width }

    /// Makes the keyboard's layout code see this screen. Call before building
    /// a view model: both the width wish default and the width cap are read
    /// when it is created.
    @MainActor
    func activate() {
        #if os(macOS)
        UIScreen.simulatedBounds = CGRect(origin: .zero, size: size)
        UIDevice.simulatedIdiom = isPad ? .pad : .phone
        #endif
    }

    static let iPhoneSE = Device(name: "iphone-se-320", size: CGSize(width: 320, height: 568), isPad: false)
    static let iPhone375 = Device(name: "iphone-375", size: CGSize(width: 375, height: 667), isPad: false)
    static let iPhone15 = Device(name: "iphone-393", size: CGSize(width: 393, height: 852), isPad: false)
    static let iPhoneProMax = Device(name: "iphone-pro-max-430", size: CGSize(width: 430, height: 932), isPad: false)
    static let iPhoneLandscape = Device(name: "iphone-landscape-852", size: CGSize(width: 852, height: 393), isPad: false)
    static let iPadMini = Device(name: "ipad-744", size: CGSize(width: 744, height: 1133), isPad: true)
    static let iPadAir = Device(name: "ipad-820", size: CGSize(width: 820, height: 1180), isPad: true)
    static let iPadPro = Device(name: "ipad-1024", size: CGSize(width: 1024, height: 1366), isPad: true)
    static let iPadLandscape = Device(name: "ipad-landscape-1366", size: CGSize(width: 1366, height: 1024), isPad: true)

    /// App Store screenshot sizes. 6.9" is 1320 x 2868 px, 6.5" is 1242 x 2688 px, both at 3x.
    static let appStore69 = Device(name: "6.9in", size: CGSize(width: 440, height: 956), isPad: false)
    static let appStore65 = Device(name: "6.5in", size: CGSize(width: 414, height: 896), isPad: false)

    static let widthSeries: [Device] = [
        .iPhoneSE, .iPhone375, .iPhone15, .iPhoneProMax, .iPhoneLandscape,
        .iPadMini, .iPadAir, .iPadPro, .iPadLandscape,
    ]
}
