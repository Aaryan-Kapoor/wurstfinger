//
//  Memory.swift
//  WurstfingerBench
//
//  Section 9: what the keyboard keeps in memory. A keyboard extension runs
//  under a hard memory ceiling (the system kills it past ~60 MB), so the
//  interesting numbers are not speed but resident cost: a language definition,
//  the caches around them, one live view graph, a mode switch's leftovers,
//  and a warmed-up input engine.
//
//  Two meters, because neither alone tells the story:
//  - `heap` is libmalloc's `size_in_use` summed over every zone: exact, but
//    blind to anything that is not malloc (images, layers, mapped files).
//  - `footprint` is the kernel's `phys_footprint`, the number the system's
//    memory-pressure killer reads: complete, but it moves in whole pages
//    (16 KB) and only when pages are touched or returned.
//

#if os(macOS)
import AppKit
import CoreGraphics
import Darwin
import Foundation
import SwiftUI
@testable import WurstfingerKit

// MARK: - Meters

struct MemoryReading {
    /// libmalloc `size_in_use`, all zones, bytes.
    var heap: Int
    /// The kernel's `phys_footprint`, bytes.
    var footprint: Int

    static func - (lhs: MemoryReading, rhs: MemoryReading) -> MemoryReading {
        MemoryReading(heap: lhs.heap - rhs.heap, footprint: lhs.footprint - rhs.footprint)
    }
}

func readMemory() -> MemoryReading {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(nil, &stats)

    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    let footprint = status == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    return MemoryReading(heap: Int(stats.size_in_use), footprint: footprint)
}

/// "1,234,567 B  (1205.6 KB)" -- both units, because the small rows are
/// bytes and the big ones are megabytes.
func bytesText(_ bytes: Int) -> String {
    let grouped = NumberFormatter.localizedString(from: NSNumber(value: bytes), number: .decimal)
    return "\(grouped) B".leftPad(14) + "  (\(format(Double(bytes) / 1024, 1)) KB)"
}

func reportBytes(_ name: String, _ bytes: Int) {
    let line = name.padding(toLength: 62, withPad: " ", startingAt: 0)
    print("\(line) \(bytesText(bytes))")
}

func reportReading(_ name: String, _ reading: MemoryReading) {
    reportBytes("\(name) [heap]", reading.heap)
    reportBytes("\(name) [footprint]", reading.footprint)
}

// MARK: - A live keyboard view graph

/// One keyboard view graph in an off-screen window: a real `NSHostingView`
/// (unlike `ImageRenderer`, it keeps the graph alive and re-evaluates it when
/// observed state changes), which is what a mode switch and the memory rows
/// need. Release-safe: it uses no DEBUG-only hook.
@MainActor
final class HostedKeyboard {
    let window: NSWindow
    let host: NSView

    init(viewModel: KeyboardViewModel, width: CGFloat = 390) {
        _ = NSApplication.shared
        let height = viewModel.layoutMetrics(forContainerWidth: width).totalHeight
        let content = DataDrivenKeyboardRootView(viewModel: viewModel, overrideWidth: width)
            .frame(width: width, height: height)
        let hosting = NSHostingView(rootView: content)
        host = hosting
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        // The window is owned by this object; AppKit's default of releasing a
        // closed window once more would over-release it under ARC.
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
    }

    /// Lets SwiftUI process pending invalidations and re-render: four turns of
    /// the main run loop, each followed by a layout and display pass.
    func settle(turn: TimeInterval = 0.02) {
        for _ in 0 ..< 4 {
            RunLoop.main.run(until: Date().addingTimeInterval(turn))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
    }

    func tearDown() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}

/// Spins the run loop so a closed window's deferred teardown can happen.
@MainActor
func spinRunLoop(turns: Int = 4, turn: TimeInterval = 0.02) {
    for _ in 0 ..< turns { RunLoop.main.run(until: Date().addingTimeInterval(turn)) }
}

// MARK: - 9a / 9b: definitions and the caches around them

@MainActor
func benchDefinitionMemory() {
    let ids = KeyboardRegistry.available.map(\.id)
    let descriptors = ids.map { id in LanguageDefinitions.all.first { $0.id == id }! }

    // One throwaway round so lazy statics (tables, locale data) are not
    // charged to whichever language happens to build first.
    _ = descriptors.map { $0.makeDefinition() }

    var kept = [KeyboardDefinition]()
    var perLanguage = [(id: String, bytes: Int)]()
    let before = readMemory()
    for descriptor in descriptors {
        let start = readMemory()
        kept.append(descriptor.makeDefinition())
        perLanguage.append((descriptor.id, readMemory().heap - start.heap))
    }
    let total = readMemory().heap - before.heap

    print("9a. heap bytes per language definition (\(ids.count) languages built and held alive):")
    for entry in perLanguage.sorted(by: { $0.bytes > $1.bytes }).prefix(5) {
        reportBytes("    \(entry.id)", entry.bytes)
    }
    reportBytes("    total, all \(ids.count) languages", total)
    reportBytes("    mean per language", total / Swift.max(ids.count, 1))
    let keptCount = kept.count
    sink.withLock { $0 &+= keptCount }

    print("    value sizes (MemoryLayout, bytes):")
    print("      KeyDefinition  \(MemoryLayout<KeyDefinition>.size)    KeyBinding  \(MemoryLayout<KeyBinding>.size)    "
        + "KeyboardMode  \(MemoryLayout<KeyboardMode>.size)    GestureTuning  \(MemoryLayout<GestureTuning>.size)    "
        + "TouchSample  \(MemoryLayout<TouchSample>.size)")
}

@MainActor
func benchCacheMemory() async {
    let ids = KeyboardRegistry.available.map(\.id)
    KeyboardRegistry.evictAll()
    GridLayoutSolver.evictAll()
    spinRunLoop(turns: 1)

    let empty = readMemory()
    await KeyboardRegistry.prewarm(ids)
    let prewarmed = readMemory()

    var cells = 0
    var arrangements = 0
    var distinct = Set<GridArrangement>()
    for id in ids {
        guard let definition = KeyboardRegistry.load(id: id) else { continue }
        for mode in definition.modes.values {
            for arrangement in mode.arrangements.values {
                cells &+= GridLayoutSolver.solve(arrangement).count
                arrangements += 1
                distinct.insert(arrangement)
            }
        }
    }
    let solved = readMemory()
    let cellTotal = cells
    sink.withLock { $0 &+= cellTotal }

    print("9b. caches (evictAll, then prewarm all \(ids.count) languages, then solve every arrangement):")
    reportReading("    KeyboardRegistry.prewarm(all), delta", prewarmed - empty)
    reportReading("    GridLayoutSolver.solve x \(arrangements) (\(distinct.count) distinct), delta", solved - prewarmed)
}

// MARK: - 9c: one view graph, many, and a mode switch

@MainActor
func benchViewGraphMemory() async {
    let rig = BenchRig()
    await KeyboardRegistry.prewarm(["de_DE"])
    spinRunLoop(turns: 4)

    print("9c. keyboard view graph (390 pt, de_DE, off-screen NSHostingView):")
    let baseline = readMemory()

    var graphs = [HostedKeyboard]()
    graphs.append(autoreleasepool { HostedKeyboard(viewModel: rig.viewModel) })
    graphs[0].settle()
    let afterFirst = readMemory()
    reportReading("    first graph + framework warm-up, delta", afterFirst - baseline)

    for _ in 0 ..< 5 {
        let graph = autoreleasepool { HostedKeyboard(viewModel: rig.viewModel) }
        graph.settle()
        graphs.append(graph)
    }
    let afterMore = readMemory()
    let marginal = afterMore - afterFirst
    reportReading("    5 more graphs, delta", marginal)
    reportReading("    marginal cost per extra graph", MemoryReading(heap: marginal.heap / 5, footprint: marginal.footprint / 5))

    // Dropping the last reference matters as much as closing: a debug build
    // keeps a local alive to the end of its scope, so the graphs live only in
    // this array.
    weak var weakWindow = graphs[0].window
    weak var weakHost = graphs[0].host
    autoreleasepool {
        for graph in graphs { graph.tearDown() }
        graphs.removeAll()
    }
    spinRunLoop(turns: 8)
    print("    after teardown: window \(weakWindow == nil ? "deallocated" : "STILL ALIVE"), "
        + "hosting view \(weakHost == nil ? "deallocated" : "STILL ALIVE")")
    let afterTearDown = readMemory()
    reportReading("    all 6 torn down: returned", afterMore - afterTearDown)
    reportReading("    all 6 torn down: still held vs. before the first", afterTearDown - baseline)

    // A mode switch re-renders the grid with other keys; what stays resident
    // afterwards (the new mode's views, caches) is its memory cost.
    let graph = autoreleasepool { HostedKeyboard(viewModel: rig.viewModel) }
    graph.settle()
    for trip in ["first", "second"] {
        let main = readMemory()
        rig.viewModel.handleGesture(.tap, keyId: UtilitySlot.symbols, isReturn: false)
        graph.settle()
        let numeric = readMemory()
        reportReading("    \(trip) switch kept alive (main -> numeric), delta", numeric - main)
        switchBack(rig.viewModel)
        graph.settle()
        reportReading("    \(trip) switch back (numeric -> main), delta", readMemory() - numeric)
    }
    graph.tearDown()
    spinRunLoop(turns: 4)
    let inserted = rig.target.inserted
    sink.withLock { $0 &+= inserted }
}

// MARK: - 9d: an input engine with every finger slot warmed

@MainActor
func benchEngineMemory() {
    let rig = BenchRig()
    guard let mode = rig.viewModel.activeModeFromDefinition,
          let (geometry, size) = rig.viewModel.gridGeometry(forContainerWidth: 390)
    else { return }

    let before = readMemory()
    let engine = TouchEngine()
    let created = readMemory()
    engine.configure(
        geometry: geometry, keys: mode.keys, tuning: rig.viewModel.gestureTuning,
        isLongPressEnabled: false, actions: TouchEngineActions()
    )
    engine.updateSize(size)
    let configured = readMemory()

    // Ten fingers on ten different keys, then all lifted: every pooled
    // track, trail token and press cell the engine will ever need exists now.
    let frames = engine.hitMap.keys.prefix(TouchEngine.maxPointers).map(\.frame)
    for (index, frame) in frames.enumerated() {
        engine.began(index, at: CGPoint(x: frame.midX, y: frame.midY), time: 0)
    }
    for (index, frame) in frames.enumerated() {
        engine.ended(index, at: CGPoint(x: frame.midX, y: frame.midY), time: 0.05)
    }
    let warmed = readMemory()

    print("9d. TouchEngine with \(frames.count) tracks warmed (\(frames.count) fingers pressed and lifted):")
    reportBytes("    TouchEngine() created, heap", created.heap - before.heap)
    reportBytes("    configured (hit map, key table), heap", configured.heap - created.heap)
    reportBytes("    10 fingers down and up (tracks, trail, press cells), heap", warmed.heap - configured.heap)
    reportBytes("    total engine, heap", warmed.heap - before.heap)
    let pooled = engine.pooledTrackCount
    sink.withLock { $0 &+= pooled }
}

#endif
