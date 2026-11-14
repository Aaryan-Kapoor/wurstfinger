//
//  HermeticTestHostTests.swift
//  WurstfingerKitTests
//
//  Pins that `swift test` cannot reach the developer's real settings plist or
//  clipboard (see `UnitTestHost`).
//

import Foundation
import os
import Testing
@testable import WurstfingerKit

@MainActor
struct HermeticTestHostTests {
    @Test func thisProcessIsRecognisedAsTheTestRunner() {
        #expect(UnitTestHost.isActive)
        #expect(UnitTestHost.isTestRunner(processName: "swiftpm-testing-helper"))
        #expect(UnitTestHost.isTestRunner(processName: "xctest"))
        #expect(!UnitTestHost.isTestRunner(processName: "Wurstfinger"))
        #expect(!UnitTestHost.isTestRunner(processName: "WurstfingerKeyboard"))
    }

    @Test func sharedStoresAreInMemory() {
        #expect(SharedDefaults.store is EphemeralDefaults)
        #expect(OnboardingProgress.store is EphemeralDefaults)
        #expect(ClipboardStore.shared is MemoryClipboard)
    }

    @Test func aViewModelWithoutAnInjectedClipboardUsesTheProcessDefault() {
        let vm = KeyboardViewModel(userDefaults: InMemoryUserDefaults(), shouldPersistSettings: false)
        #expect(vm.clipboard === ClipboardStore.shared)
    }
}

struct EphemeralDefaultsTests {
    @Test func typedSettersStayInMemory() {
        let defaults = EphemeralDefaults()
        let key = "ephemeral.test.\(UUID().uuidString)"
        defaults.set(true, forKey: key + ".bool")
        defaults.set(2, forKey: key + ".int")
        defaults.set(0.5, forKey: key + ".double")
        defaults.set(["a"], forKey: key + ".list")

        #expect(defaults.bool(forKey: key + ".bool"))
        #expect(defaults.integer(forKey: key + ".int") == 2)
        #expect(defaults.double(forKey: key + ".double") == 0.5)
        #expect(defaults.stringArray(forKey: key + ".list") == ["a"])
        #expect(UserDefaults.standard.object(forKey: key + ".bool") == nil)
        #expect(UserDefaults.standard.object(forKey: key + ".int") == nil)

        defaults.removeObject(forKey: key + ".bool")
        #expect(defaults.object(forKey: key + ".bool") == nil)
    }

    @Test func instancesDoNotShareState() {
        let first = EphemeralDefaults()
        let second = EphemeralDefaults()
        first.set("x", forKey: "k")
        #expect(second.string(forKey: "k") == nil)
    }

    @Test func registeredDefaultsYieldToWrittenValues() {
        let defaults = EphemeralDefaults()
        defaults.set(false, forKey: "written")
        defaults.register(defaults: ["written": true, "registered": true])
        #expect(!defaults.bool(forKey: "written"))
        #expect(defaults.bool(forKey: "registered"))
    }

    /// Like a real store, a write announces itself, which is what the view
    /// model's in-process settings observer listens for.
    @Test func writesPostTheChangeNotification() {
        let defaults = EphemeralDefaults()
        let posts = OSAllocatedUnfairLock(initialState: 0)
        let token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { _ in posts.withLock { $0 += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }

        defaults.set(1, forKey: "a")
        defaults.removeObject(forKey: "a")

        #expect(posts.withLock { $0 } == 2)
    }
}
