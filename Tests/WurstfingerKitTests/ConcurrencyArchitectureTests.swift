//
//  ConcurrencyArchitectureTests.swift
//  WurstfingerTests
//
//  The pieces of the concurrency architecture that are not a cache or a log:
//  the settings snapshot, the debounced cross-process reload, task-handle
//  lifetime, and the language prewarm started by the view model.
//

import Foundation
import Testing
@testable import WurstfingerKit

// MARK: - Settings snapshot

@MainActor
@Suite(.serialized)
struct GestureTuningSnapshotTests {
    /// A 24 pt stroke along the x axis: a swipe under the stock 20 pt minimum,
    /// a tap once the minimum is raised to 60 pt.
    private static let shortStroke: [CGPoint] = [
        .zero, CGPoint(x: 8, y: 0), CGPoint(x: 16, y: 0), CGPoint(x: 24, y: 0),
    ]

    private func makeViewModel(_ defaults: UserDefaults) -> KeyboardViewModel {
        KeyboardViewModel(userDefaults: defaults, shouldPersistSettings: false)
    }

    private func classify(_ vm: KeyboardViewModel) -> GestureType {
        KeyGestureRecognizer.classify(positions: Self.shortStroke, aspectRatio: 1, tuning: vm.gestureTuning).gesture
    }

    private func raiseMinimumSwipeLength(in defaults: UserDefaults) {
        defaults.set(true, forKey: SettingsKey.expertModeEnabled.rawValue)
        defaults.set(60.0, forKey: GestureClassificationThresholds.minSwipeLengthKey)
    }

    @Test func stockSettingsClassifyTheShortStrokeAsASwipe() {
        let vm = makeViewModel(InMemoryUserDefaults())
        #expect(classify(vm) == .swipeRight)
    }

    @Test func changingTheStoreWithoutAReloadLeavesClassificationUnchanged() {
        let defaults = InMemoryUserDefaults()
        let vm = makeViewModel(defaults)

        raiseMinimumSwipeLength(in: defaults)

        // The snapshot is what the touch path reads; the store is not
        // consulted per keystroke, so a write alone changes nothing.
        #expect(classify(vm) == .swipeRight)
    }

    @Test func reloadingPicksUpTheChangedThresholds() {
        let defaults = InMemoryUserDefaults()
        let vm = makeViewModel(defaults)
        raiseMinimumSwipeLength(in: defaults)

        vm.reloadSettings()

        #expect(classify(vm) == .tap)
    }

    @Test func aReloadThatChangedNothingKeepsTheSnapshotEqual() {
        let defaults = InMemoryUserDefaults()
        raiseMinimumSwipeLength(in: defaults)
        let vm = makeViewModel(defaults)
        let before = vm.gestureTuning

        vm.reloadSettings()

        #expect(vm.gestureTuning == before)
    }

    @Test func theSnapshotClassifiesLikeTheLegacyDefaultsEntryPoint() {
        let defaults = InMemoryUserDefaults()
        raiseMinimumSwipeLength(in: defaults)
        let tuning = GestureTuning.load(from: defaults)

        let viaSnapshot = KeyGestureRecognizer.classify(positions: Self.shortStroke, aspectRatio: 1, tuning: tuning)
        let viaStore = KeyGestureRecognizer.classify(
            positions: Self.shortStroke,
            config: GesturePreprocessorConfiguration.fromUserDefaults(store: defaults).with(aspectRatio: 1),
            thresholds: GestureClassificationThresholds.fromUserDefaults(store: defaults)
        )
        #expect(viaSnapshot.gesture == viaStore.gesture)
        #expect(viaSnapshot.isReturn == viaStore.isReturn)
    }

    /// The typing toggles ride the same snapshot: a store write is invisible
    /// to the pipeline until the settings signal reloads it.
    @Test func typingTogglesFollowTheSameSnapshotRule() {
        let defaults = InMemoryUserDefaults()
        let vm = makeViewModel(defaults)
        #expect(!vm.typingBehavior.doubleSpacePeriodEnabled)

        defaults.set(true, forKey: SettingsKey.doubleSpacePeriodEnabled.rawValue)
        #expect(!vm.typingBehavior.doubleSpacePeriodEnabled)

        vm.reloadSettings()
        #expect(vm.typingBehavior.doubleSpacePeriodEnabled)
    }

    @Test func theTrailSettingTravelsInTheSnapshot() {
        let defaults = InMemoryUserDefaults()
        #expect(!GestureTuning.load(from: defaults).isTrailEnabled)
        defaults.set(true, forKey: SettingsKey.gestureTrailEnabled.rawValue)
        #expect(GestureTuning.load(from: defaults).isTrailEnabled)
    }
}

// MARK: - Cross-process settings signal

@MainActor
@Suite(.serialized)
struct ExternalSettingsObservationTests {
    private func makeViewModel(_ defaults: UserDefaults, timers: ManualTimerSource? = nil) -> KeyboardViewModel {
        // Non-persisting would only follow haptics; the keyboard extension
        // persists, and that is the configuration the signal exists for.
        KeyboardViewModel(userDefaults: defaults, shouldPersistSettings: true, timers: timers)
    }

    /// Lets the observation task consume what was yielded into its stream:
    /// yields the main actor until `condition` holds. Bounded by a number of
    /// yields, never by time, so a busy machine can only make it slower.
    private func settle(until condition: () -> Bool) async {
        for _ in 0 ..< 20_000 where !condition() {
            await Task.yield()
        }
    }

    /// Waits (on the main actor, so the observation task can run) until
    /// `condition` holds or the deadline passes. Only the end-to-end Darwin
    /// test uses it: that one crosses a real system notification and has no
    /// clock to turn.
    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: timeout)
        while !condition(), clock.now < end {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aSignalReloadsTheSettingsAfterTheDebounceWindow() async {
        let timers = ManualTimerSource()
        let defaults = InMemoryUserDefaults()
        defaults.set(250.0, forKey: SettingsKey.keyboardWidthPoints.rawValue)
        let vm = makeViewModel(defaults, timers: timers)
        let (signals, trigger) = AsyncStream.makeStream(of: Void.self)
        vm.observeExternalSettingsChanges(signals: signals, debounce: .milliseconds(50))

        defaults.set(320.0, forKey: SettingsKey.keyboardWidthPoints.rawValue)
        trigger.yield()
        await settle { timers.pendingCount == 1 }

        // Not yet: the trailing window has not elapsed.
        #expect(vm.keyboardWidth == 250.0)
        timers.advance(by: 0.049)
        #expect(vm.keyboardWidth == 250.0)
        timers.advance(by: 0.001)
        #expect(vm.keyboardWidth == 320.0)
        #expect(vm.settingsReloadCount == 1)
    }

    @Test func aBurstOfSignalsCollapsesToOneReload() async {
        let timers = ManualTimerSource()
        let vm = makeViewModel(InMemoryUserDefaults(), timers: timers)
        let (signals, trigger) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .unbounded)
        vm.observeExternalSettingsChanges(signals: signals, debounce: .milliseconds(50))
        let before = vm.settingsReloadCount

        // A slider drag in the host app: many posts in quick succession. Each
        // one re-arms the window, so all 40 have been consumed once 40 timers
        // were ever armed.
        for _ in 0 ..< 40 { trigger.yield() }
        await settle { timers.scheduledTotal == 40 }
        #expect(timers.pendingCount == 1, "every signal but the last cancelled its predecessor's window")

        timers.advance(by: 10)
        #expect(vm.settingsReloadCount == before + 1, "a coalesced burst must reload exactly once")
    }

    @Test func noSignalNoReload() async {
        let timers = ManualTimerSource()
        let vm = makeViewModel(InMemoryUserDefaults(), timers: timers)
        let (signals, _) = AsyncStream.makeStream(of: Void.self)
        vm.observeExternalSettingsChanges(signals: signals, debounce: .milliseconds(20))

        timers.advance(by: 10)

        #expect(vm.settingsReloadCount == 0)
        #expect(timers.pendingCount == 0)
    }

    @Test func cancellingTheObservationStopsReloads() async {
        let timers = ManualTimerSource()
        let vm = makeViewModel(InMemoryUserDefaults(), timers: timers)
        let (signals, trigger) = AsyncStream.makeStream(of: Void.self)
        let handle = vm.observeExternalSettingsChanges(signals: signals, debounce: .milliseconds(20))

        handle.cancel()
        trigger.yield()
        // Give the (cancelled) task every chance to run anyway.
        for _ in 0 ..< 100 { await Task.yield() }
        timers.advance(by: 10)

        #expect(vm.settingsReloadCount == 0)
        #expect(timers.scheduledTotal == 0, "a cancelled observation arms no window")
    }

    @Test func aDarwinPostReachesTheViewModelEndToEnd() async {
        let defaults = InMemoryUserDefaults()
        defaults.set(250.0, forKey: SettingsKey.keyboardWidthPoints.rawValue)
        let vm = makeViewModel(defaults)
        let name = "de.akator.wurstfinger.test.\(UUID().uuidString)"
        vm.observeExternalSettingsChanges(
            signals: DarwinNotificationCenter.shared.notifications(named: name),
            debounce: .milliseconds(20)
        )

        defaults.set(330.0, forKey: SettingsKey.keyboardWidthPoints.rawValue)
        DarwinNotificationCenter.shared.post(name)

        await waitUntil(timeout: .seconds(3)) { vm.keyboardWidth == 330.0 }
        #expect(vm.keyboardWidth == 330.0)
    }
}

// MARK: - Task handle

struct TaskHandleTests {
    /// Reports its own cancellation back to the test.
    private actor Probe {
        private(set) var wasCancelled = false
        func mark() { wasCancelled = true }
    }

    @Test func deallocatingTheHandleCancelsItsTask() async throws {
        let probe = Probe()
        var handle: TaskHandle? = TaskHandle(Task {
            do { try await Task.sleep(for: .seconds(30)) } catch { await probe.mark() }
        })
        try await Task.sleep(for: .milliseconds(50))

        handle = nil
        _ = handle

        try await Task.sleep(for: .milliseconds(300))
        #expect(await probe.wasCancelled)
    }

    @Test func cancelStopsTheTaskImmediately() async throws {
        let probe = Probe()
        let handle = TaskHandle(Task {
            do { try await Task.sleep(for: .seconds(30)) } catch { await probe.mark() }
        })
        try await Task.sleep(for: .milliseconds(50))

        handle.cancel()

        try await Task.sleep(for: .milliseconds(300))
        #expect(await probe.wasCancelled)
    }
}

// MARK: - Language prewarm from the view model

@MainActor
@Suite(.serialized)
struct ViewModelPrewarmTests {
    @Test func loadingStartsABackgroundPrewarmOfTheEnabledLanguages() async throws {
        let defaults = InMemoryUserDefaults()
        LanguageSettings.saveEnabledLanguageIds(["de_DE", "es_ES", "sv_SE"], to: defaults)
        defaults.set("de_DE", forKey: SettingsKey.selectedLanguageId.rawValue)
        let vm = KeyboardViewModel(userDefaults: defaults, shouldPersistSettings: false, prewarmsLanguages: true)

        vm.loadDefinition(for: "de_DE")

        let task = try #require(vm.prewarmTask)
        await task.value
        for id in ["de_DE", "es_ES", "sv_SE"] {
            #expect(KeyboardRegistry.isCached(id: id), "\(id) was not prewarmed")
        }
    }

    @Test func aViewModelThatDidNotAskForPrewarmSpawnsNothing() {
        let defaults = InMemoryUserDefaults()
        LanguageSettings.saveEnabledLanguageIds(["de_DE", "fr_FR"], to: defaults)
        let vm = KeyboardViewModel(userDefaults: defaults, shouldPersistSettings: false)

        vm.loadDefinition(for: "de_DE")

        #expect(vm.prewarmTask == nil)
    }

    @Test func aSingleEnabledLanguageHasNothingToPrewarm() {
        let defaults = InMemoryUserDefaults()
        LanguageSettings.saveEnabledLanguageIds(["de_DE"], to: defaults)
        let vm = KeyboardViewModel(userDefaults: defaults, shouldPersistSettings: false, prewarmsLanguages: true)

        vm.loadDefinition(for: "de_DE")

        #expect(vm.prewarmTask == nil)
    }

    @Test func switchingLanguageAfterThePrewarmUsesTheWarmDefinition() async throws {
        let defaults = InMemoryUserDefaults()
        LanguageSettings.saveEnabledLanguageIds(["de_DE", "it_IT"], to: defaults)
        defaults.set("de_DE", forKey: SettingsKey.selectedLanguageId.rawValue)
        let vm = KeyboardViewModel(userDefaults: defaults, shouldPersistSettings: false, prewarmsLanguages: true)
        vm.loadDefinition(for: "de_DE")
        await vm.prewarmTask?.value

        vm.switchToNextLanguage()

        #expect(vm.currentDefinition?.id == "it_IT")
    }
}
