//
//  main.swift
//  WurstfingerBench
//
//  Micro-benchmarks for the keyboard's input path. Run in release mode with
//  testability on, because the code under measurement is module-internal:
//
//      swift run -c release WurstfingerBench
//
//  (`--timers` runs only the timer section; `--bodies` additionally needs a debug build, where the KeyView body
//  counter exists: `swift run WurstfingerBench --bodies`. `--alloc`, `--memory` and `--switch` run
//  only the allocation, memory and mode-switch sections.)
//
//  Every section prints p50 / p99 / max in nanoseconds per operation, so the
//  numbers before and after the Swift 6 port are directly comparable.
//

#if os(macOS)
import CoreGraphics
import Dispatch
import Foundation
import AppKit
import SwiftUI
@testable import WurstfingerKit

// MARK: - Sections

func benchClassification(_ corpus: [SyntheticGesture]) -> [Stats] {
    let config = GesturePreprocessorConfiguration.default
    let thresholds = GestureClassificationThresholds.default
    var results = [Stats]()
    results.append(measure("1. classify(positions:aspectRatio:) [legacy: defaults reads]", inputs: corpus) {
        KeyGestureRecognizer.classify(positions: $0.positions, aspectRatio: 1.2).isReturn ? 1 : 0
    })
    results.append(measure("2. classify(config:thresholds:) [explicit snapshot]", inputs: corpus) {
        KeyGestureRecognizer.classify(
            positions: $0.positions, config: config.with(aspectRatio: 1.2), thresholds: thresholds
        ).isReturn ? 1 : 0
    })
    let tuning = GestureTuning.default
    results.append(measure("2b. classify(positions:aspectRatio:tuning:) [production]", inputs: corpus) {
        KeyGestureRecognizer.classify(positions: $0.positions, aspectRatio: 1.2, tuning: tuning).isReturn ? 1 : 0
    })
    return results
}

@MainActor
func benchDispatch(iterations: Int) -> [Stats] {
    let defaults = UserDefaults(suiteName: "de.akator.wurstfinger.bench")!
    defaults.removePersistentDomain(forName: "de.akator.wurstfinger.bench")
    let viewModel = KeyboardViewModel(userDefaults: defaults, shouldPersistSettings: false)
    let target = BenchTextTarget()
    viewModel.bindTextInputTarget(target)
    viewModel.loadDefinition(for: "de_DE")

    let ticks = Array(0 ..< iterations)
    let tap = measure("3a. handleGesture tap -> pipeline -> target", inputs: ticks) { _ in
        viewModel.handleGesture(.tap, keyId: GridSlot.topLeft, isReturn: false) ? 1 : 0
    }
    // Compose: a letter, then a compose trigger that combines with it.
    let compose = measure("3b. compose sequence (tap a + swipe ^) -> target", inputs: ticks) { _ in
        _ = viewModel.handleGesture(.tap, keyId: GridSlot.topLeft, isReturn: false)
        return viewModel.handleGesture(.swipeUp, keyId: GridSlot.topCenter, isReturn: false) ? 1 : 0
    }
    let inserted = target.inserted
    sink.withLock { $0 &+= inserted }
    return [tap, compose]
}

/// What the globe key costs: the definition build the switch may have to do
/// itself (cold cache) against the same switch after the background prewarm.
@MainActor
func benchLanguageSwitch() async -> [Stats] {
    let ids = ["de_DE", "en_US", "fr_FR", "es_ES", "it_IT", "ru_RU", "pl_PL", "sv_SE"]
    let defaults = UserDefaults(suiteName: "de.akator.wurstfinger.bench")!
    defaults.removePersistentDomain(forName: "de.akator.wurstfinger.bench")
    LanguageSettings.saveEnabledLanguageIds(ids, to: defaults)
    defaults.set(ids[0], forKey: SettingsKey.selectedLanguageId.rawValue)
    let viewModel = KeyboardViewModel(userDefaults: defaults, shouldPersistSettings: false)
    viewModel.bindTextInputTarget(BenchTextTarget())
    viewModel.loadDefinition(for: ids[0])

    var cold = [UInt64]()
    var warm = [UInt64]()
    var consumed = 0
    for _ in 0 ..< 12 {
        KeyboardRegistry.evictAll()
        viewModel.loadDefinition(for: ids[0])
        for _ in 1 ..< ids.count {
            let start = nanos()
            viewModel.switchToNextLanguage()
            cold.append(nanos() &- start)
            consumed &+= viewModel.currentDefinition?.modes.count ?? 0
        }
    }
    await KeyboardRegistry.prewarm(ids)
    for _ in 0 ..< 12 {
        viewModel.loadDefinition(for: ids[0])
        for _ in 1 ..< ids.count {
            let start = nanos()
            viewModel.switchToNextLanguage()
            warm.append(nanos() &- start)
            consumed &+= viewModel.currentDefinition?.modes.count ?? 0
        }
    }
    let consumedTotal = consumed
    sink.withLock { $0 &+= consumedTotal }
    return [
        Stats(name: "4c. globe-key language switch, cache cold (no prewarm)", samples: cold),
        Stats(name: "4d. globe-key language switch, after prewarm", samples: warm),
    ]
}

func benchDefinitionBuilds() -> [Stats] {
    var results = [Stats]()
    var consumed = 0
    var perLanguage = [(String, UInt64)]()
    var all = [UInt64]()
    for round in 0 ..< 5 {
        for metadata in KeyboardRegistry.available {
            guard let descriptor = LanguageDefinitions.all.first(where: { $0.id == metadata.id }) else { continue }
            let start = nanos()
            let definition = descriptor.makeDefinition()
            let elapsed = nanos() &- start
            consumed &+= definition.modes.count
            if round == 0 { perLanguage.append((metadata.id, elapsed)) }
            all.append(elapsed)
        }
    }
    let consumedTotal = consumed
    sink.withLock { $0 &+= consumedTotal }
    let first = perLanguage.map(\.1)
    results.append(Stats(name: "4a. cold KeyboardDefinition build, one language", samples: all))
    let total = first.reduce(0, +)
    results.append(Stats(name: "4b. cold build, all \(first.count) languages (single run total)", samples: [total]))
    print("    per language (first run, ns):")
    for (id, ns) in perLanguage.sorted(by: { $0.1 > $1.1 }).prefix(5) {
        print("      \(id.padding(toLength: 10, withPad: " ", startingAt: 0)) \(ns)")
    }
    return results
}

@MainActor
func benchRender(iterations: Int) -> [Stats] {
    let defaults = UserDefaults(suiteName: "de.akator.wurstfinger.bench")!
    let viewModel = KeyboardViewModel(userDefaults: defaults, shouldPersistSettings: false)
    viewModel.bindTextInputTarget(BenchTextTarget())
    viewModel.loadDefinition(for: "de_DE")
    let height = viewModel.layoutMetrics(forContainerWidth: 390).totalHeight

    var samples = [UInt64]()
    var first: UInt64 = 0
    var consumed = 0
    for index in 0 ..< iterations {
        // A fresh view per render: measures building and laying out the whole
        // key graph (~40 keys), the cost a mode switch pays.
        let content = DataDrivenKeyboardRootView(viewModel: viewModel, overrideWidth: 390)
            .frame(width: 390, height: height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let start = nanos()
        consumed &+= renderer.cgImage?.width ?? 0
        let elapsed = nanos() &- start
        if index == 0 { first = elapsed } else { samples.append(elapsed) }
    }
    let consumedTotal = consumed
    sink.withLock { $0 &+= consumedTotal }
    print("    first (cold) render: \(first) ns")
    return [Stats(name: "5. DataDrivenKeyboardRootView ImageRenderer render", samples: samples)]
}

// MARK: - Timers

/// Collects fire lateness on the main actor, so neither timer mechanism needs
/// a mutable capture that crosses isolation.
@MainActor
final class LatenessCollector {
    var samples = [UInt64]()
    var remaining: Int
    var done: CheckedContinuation<Void, Never>?

    init(expected: Int) { remaining = expected }

    func record(deadline: UInt64) {
        samples.append(nanos() &- deadline)
        remaining -= 1
        if remaining == 0 { done?.resume(); done = nil }
    }
}

/// Fire-lateness of the two timer mechanisms the long-press scheduler and the
/// trail fade can use. Lateness = actual fire time - requested deadline.
@MainActor
func benchTimers(count: Int) async -> [Stats] {
    let delayNanos: UInt64 = 20_000_000

    // GCD: DispatchQueue.main.asyncAfter with a DispatchWorkItem (the old path).
    let gcd = LatenessCollector(expected: count)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        gcd.done = continuation
        for index in 0 ..< count {
            let deadline = nanos() + delayNanos + UInt64(index % 50) * 1_000_000
            let item = DispatchWorkItem {
                MainActor.assumeIsolated { gcd.record(deadline: deadline) }
            }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .nanoseconds(Int(deadline - nanos())), execute: item
            )
        }
    }

    // Main-actor Task + Task.sleep (the new path).
    let tasks = LatenessCollector(expected: count)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        tasks.done = continuation
        for index in 0 ..< count {
            let deadline = nanos() + delayNanos + UInt64(index % 50) * 1_000_000
            Task { @MainActor in
                try? await Task.sleep(for: .nanoseconds(Int(deadline - nanos())))
                tasks.record(deadline: deadline)
            }
        }
    }

    // Same, with the sleep's timer leeway forced to zero.
    let precise = LatenessCollector(expected: count)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        precise.done = continuation
        for index in 0 ..< count {
            let deadline = nanos() + delayNanos + UInt64(index % 50) * 1_000_000
            Task { @MainActor in
                let wake = ContinuousClock.now.advanced(by: .nanoseconds(Int(deadline - nanos())))
                try? await Task.sleep(until: wake, tolerance: .zero, clock: .continuous)
                precise.record(deadline: deadline)
            }
        }
    }

    return [
        Stats(name: "6a. timer lateness, DispatchWorkItem + main asyncAfter", samples: gcd.samples),
        Stats(name: "6b. timer lateness, @MainActor Task + Task.sleep", samples: tasks.samples),
        Stats(name: "6c. timer lateness, Task.sleep(until:tolerance: .zero)", samples: precise.samples),
    ]
}

// MARK: - Body evaluations

#if DEBUG
@MainActor
func benchBodies() {
    let defaults = UserDefaults(suiteName: "de.akator.wurstfinger.bench")!
    defaults.removePersistentDomain(forName: "de.akator.wurstfinger.bench")
    let viewModel = KeyboardViewModel(userDefaults: defaults, shouldPersistSettings: false)
    let target = BenchTextTarget()
    viewModel.bindTextInputTarget(target)
    viewModel.loadDefinition(for: "de_DE")
    let height = viewModel.layoutMetrics(forContainerWidth: 390).totalHeight
    // A live hosting view in an off-screen window: unlike `ImageRenderer`, it
    // re-evaluates the view graph when observed state changes, which is what
    // this section counts.
    _ = NSApplication.shared
    let content = DataDrivenKeyboardRootView(viewModel: viewModel, overrideWidth: 390)
        .frame(width: 390, height: height)
    let host = NSHostingView(rootView: content)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 390, height: height),
        styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.contentView = host
    window.orderBack(nil)

    /// Lets SwiftUI process pending invalidations and re-render.
    func settle() {
        for _ in 0 ..< 4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
    }
    settle() // initial render

    /// Runs `change`, lets the graph settle, and returns how many key bodies ran.
    func bodies(after change: () -> Void) -> Int {
        let before = KeyViewBodyCounter.count
        change()
        settle()
        return KeyViewBodyCounter.count - before
    }

    print("7. KeyView.body evaluations per event (keys on screen: \(KeyViewBodyCounter.count)):")
    let tap = bodies {
        viewModel.feedbackTap()
        viewModel.handleGesture(.tap, keyId: GridSlot.topLeft, isReturn: false)
    }
    print("    tap keystroke (no mode change)            \(tap)")
    let reload = bodies { viewModel.reloadSettings() }
    print("    reloadSettings(), nothing changed         \(reload)")
    var intensity: CGFloat = 0.3
    let haptic = bodies {
        intensity = intensity == 0.3 ? 0.5 : 0.3
        viewModel.hapticIntensityTap = intensity
    }
    print("    haptic intensity slider moved             \(haptic)")
    let mode = bodies { viewModel.handleGesture(.tap, keyId: UtilitySlot.symbols, isReturn: false) }
    print("    mode switch (letters -> numeric)          \(mode)")
}
#endif

// MARK: - Entry

let arguments = CommandLine.arguments
let onlyBodies = arguments.contains("--bodies")
let onlyTimers = arguments.contains("--timers")
let onlyAlloc = arguments.contains("--alloc")
let onlyMemory = arguments.contains("--memory")
let onlySwitch = arguments.contains("--switch")

/// Sections 8-10 (the prewarm in each is awaited before it counts anything).
func runAllocationSection() async { await benchAllocations() }

func runMemorySection() async {
    await MainActor.run { _ = NSApplication.shared }
    await MainActor.run { benchDefinitionMemory() }
    await benchCacheMemory()
    await benchViewGraphMemory()
    await MainActor.run { benchEngineMemory() }
}

func runSwitchSection() async {
    for stats in await benchModeSwitch() { stats.report() }
}

#if DEBUG
if onlyBodies {
    await MainActor.run { benchBodies() }
    exit(0)
}
#endif

if arguments.contains("--render") {
    for stats in await MainActor.run(body: { benchRender(iterations: 60) }) { stats.report() }
    exit(0)
}

if onlyTimers {
    for stats in await benchTimers(count: 1000) { stats.report() }
    exit(0)
}

if onlyAlloc || onlyMemory || onlySwitch {
    if onlyAlloc { await runAllocationSection() }
    if onlyMemory { await runMemorySection() }
    if onlySwitch { await runSwitchSection() }
    exit(0)
}

print("Wurstfinger bench -- \(ProcessInfo.processInfo.operatingSystemVersionString), "
    + "\(ProcessInfo.processInfo.activeProcessorCount) cores")
print(String(repeating: "-", count: 118))

let corpus = makeCorpus(count: 10_000)
for stats in benchClassification(corpus) { stats.report() }
for stats in await MainActor.run(body: { benchDispatch(iterations: 20_000) }) { stats.report() }
for stats in benchDefinitionBuilds() { stats.report() }
for stats in await benchLanguageSwitch() { stats.report() }
for stats in await MainActor.run(body: { benchRender(iterations: 60) }) { stats.report() }
for stats in await benchTimers(count: 1000) { stats.report() }
await runAllocationSection()
await runMemorySection()
await runSwitchSection()
exit(0)

#else
print("WurstfingerBench is macOS-only.")
#endif
