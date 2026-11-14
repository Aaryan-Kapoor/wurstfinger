//
//  LayoutOptionSettingsTests.swift
//  WurstfingerTests
//
//  The three layout settings of this package — key spacing, the numpad column
//  and the split — as `LayoutSettings` stores, clamps, persists and reloads
//  them, and that they reach the metrics.
//

import CoreGraphics
import Foundation
import Testing
@testable import WurstfingerKit

@MainActor
struct LayoutOptionSettingsTests {
    private func settings(_ defaults: UserDefaults = InMemoryUserDefaults(), persist: Bool = true) -> LayoutSettings {
        LayoutSettings(defaults: defaults, shouldPersist: persist)
    }

    @Test func defaultsPreserveTodaysBehaviour() {
        let layout = settings()
        #expect(layout.keySpacing == Double(KeyboardConstants.Layout.defaultKeySpacing))
        #expect(layout.numpadColumn == .off)
        #expect(layout.isSplitLayoutEnabled == false)
    }

    @Test func storedValuesLoad() {
        let defaults = InMemoryUserDefaults()
        defaults.set(9.0, forKey: SettingsKey.keySpacing.rawValue)
        defaults.set("leading", forKey: SettingsKey.numpadColumn.rawValue)
        defaults.set(true, forKey: SettingsKey.isSplitLayoutEnabled.rawValue)
        let layout = settings(defaults)
        #expect(layout.keySpacing == 9)
        #expect(layout.numpadColumn == .leading)
        #expect(layout.isSplitLayoutEnabled)
    }

    @Test func spacingIsClampedOnLoadAndOnSet() {
        let defaults = InMemoryUserDefaults()
        defaults.set(99.0, forKey: SettingsKey.keySpacing.rawValue)
        let layout = settings(defaults)
        #expect(layout.keySpacing == 12)
        layout.keySpacing = -4
        #expect(layout.keySpacing == 0)
        #expect(defaults.double(forKey: SettingsKey.keySpacing.rawValue) == 0)
        layout.keySpacing = 7.5
        #expect(layout.keySpacing == 7.5)
    }

    @Test func aBogusStoredNumpadColumnIsOff() {
        let defaults = InMemoryUserDefaults()
        defaults.set("middle", forKey: SettingsKey.numpadColumn.rawValue)
        #expect(settings(defaults).numpadColumn == .off)
    }

    @Test func changesPersistWhenPersistenceIsOn() {
        let defaults = InMemoryUserDefaults()
        let layout = settings(defaults)
        layout.keySpacing = 3
        layout.numpadColumn = .trailing
        layout.isSplitLayoutEnabled = true
        #expect(defaults.double(forKey: SettingsKey.keySpacing.rawValue) == 3)
        #expect(defaults.string(forKey: SettingsKey.numpadColumn.rawValue) == "trailing")
        #expect(defaults.bool(forKey: SettingsKey.isSplitLayoutEnabled.rawValue))
    }

    @Test func nothingPersistsWhenPersistenceIsOff() {
        let defaults = InMemoryUserDefaults()
        let layout = settings(defaults, persist: false)
        layout.keySpacing = 3
        layout.numpadColumn = .leading
        layout.isSplitLayoutEnabled = true
        #expect(defaults.object(forKey: SettingsKey.keySpacing.rawValue) == nil)
        #expect(defaults.object(forKey: SettingsKey.numpadColumn.rawValue) == nil)
        #expect(defaults.object(forKey: SettingsKey.isSplitLayoutEnabled.rawValue) == nil)
    }

    @Test func reloadFollowsTheStore() {
        let defaults = InMemoryUserDefaults()
        let layout = settings(defaults, persist: false)
        defaults.set(11.0, forKey: SettingsKey.keySpacing.rawValue)
        defaults.set("trailing", forKey: SettingsKey.numpadColumn.rawValue)
        defaults.set(true, forKey: SettingsKey.isSplitLayoutEnabled.rawValue)
        layout.reload()
        #expect(layout.keySpacing == 11)
        #expect(layout.numpadColumn == .trailing)
        #expect(layout.isSplitLayoutEnabled)
        defaults.removeObject(forKey: SettingsKey.keySpacing.rawValue)
        layout.reload()
        #expect(layout.keySpacing == Double(KeyboardConstants.Layout.defaultKeySpacing))
    }

    @Test func spacingReachesTheResolvedMetrics() {
        let layout = settings(persist: false)
        layout.keySpacing = 12
        let metrics = layout.resolveMetrics(columns: 4, availableWidth: 1000, screenHeight: 0)
        #expect(metrics.keySpacing == 12)
        let wider = layout.resolveMetrics(columns: 5, wishColumns: 4, availableWidth: 1000, screenHeight: 0)
        #expect(wider.cellWidth == metrics.cellWidth)
    }

    @Test func theStoredKeysAreStable() {
        // These strings are persisted: a rename would reset the setting.
        #expect(SettingsKey.numpadColumn.rawValue == "numpadColumn")
        #expect(SettingsKey.keySpacing.rawValue == "keySpacing")
        #expect(SettingsKey.isSplitLayoutEnabled.rawValue == "splitLayoutEnabled")
        #expect(NumpadColumnPlacement.allCases.map(\.rawValue) == ["off", "leading", "trailing"])
    }

    @Test func theViewModelDelegatesToTheSettings() {
        let viewModel = KeyboardViewModel(userDefaults: InMemoryUserDefaults(), shouldPersistSettings: false)
        viewModel.keySpacing = 2
        viewModel.numpadColumn = .leading
        viewModel.isSplitLayoutEnabled = true
        #expect(viewModel.layoutSettings.keySpacing == 2)
        #expect(viewModel.layoutSettings.numpadColumn == .leading)
        #expect(viewModel.layoutSettings.isSplitLayoutEnabled)
    }
}
