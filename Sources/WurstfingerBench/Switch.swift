//
//  Switch.swift
//  WurstfingerBench
//
//  Section 10: how long a mode switch takes from the tap to a settled view
//  graph. A switch swaps every key of the grid (the same 15 `KeyView`s, other
//  bindings), so it is the biggest single re-render the keyboard does while
//  typing.
//

#if os(macOS)
import AppKit
import Foundation
@testable import WurstfingerKit

/// The (key, gesture) in the active mode whose binding switches to `mode`.
///
/// Looked up rather than hard-coded because the switch lives on different
/// keys in different modes (and the way back is a swipe in some layouts): taps
/// are checked first, then the eight swipes, keys in id order so the answer is
/// deterministic.
@MainActor
func switchGesture(to mode: String, in viewModel: KeyboardViewModel) -> (keyId: String, gesture: GestureType)? {
    guard let active = viewModel.activeModeFromDefinition else { return nil }
    let gestures = [GestureType.tap] + GestureType.allCases.filter(\.isSwipe)
    let keys = active.keys.values.sorted { $0.id < $1.id }
    for gesture in gestures {
        for key in keys where key.bindings[gesture]?.action == .switchMode(mode) {
            return (key.id, gesture)
        }
    }
    return nil
}

/// Switches the active mode back to the letters, as the numeric mode's own
/// key does.
@MainActor
func switchBack(_ viewModel: KeyboardViewModel) {
    guard let (keyId, gesture) = switchGesture(to: ModeNames.main, in: viewModel) else { return }
    viewModel.handleGesture(gesture, keyId: keyId, isReturn: false)
}

@MainActor
func benchModeSwitch() async -> [Stats] {
    let rig = BenchRig()
    let viewModel = rig.viewModel
    await KeyboardRegistry.prewarm(["de_DE"])
    let graph = autoreleasepool { HostedKeyboard(viewModel: viewModel) }
    graph.settle()

    // Both directions are resolved once up front: the lookup is not what is
    // being timed, and the numeric mode's keys are only reachable after the
    // first switch.
    guard let forward = switchGesture(to: ModeNames.numeric, in: viewModel) else {
        print("10. no key switches to numeric in the main mode; skipped")
        return []
    }
    viewModel.handleGesture(forward.gesture, keyId: forward.keyId, isReturn: false)
    guard let backward = switchGesture(to: ModeNames.main, in: viewModel) else {
        print("10. no key switches back to main in the numeric mode; skipped")
        return []
    }
    viewModel.handleGesture(backward.gesture, keyId: backward.keyId, isReturn: false)
    graph.settle()
    graph.settle()

    /// Timed pieces of one switch, in ns: the dispatch call, then through a
    /// layout and display pass, then through the fixed settle loop.
    func timed(_ step: (keyId: String, gesture: GestureType)) -> (call: UInt64, laidOut: UInt64, settled: UInt64) {
        let start = nanos()
        viewModel.handleGesture(step.gesture, keyId: step.keyId, isReturn: false)
        let called = nanos()
        graph.host.layoutSubtreeIfNeeded()
        graph.host.displayIfNeeded()
        let laidOut = nanos()
        // The settle bound: 4 run-loop turns of up to 5 ms each, so the
        // settled figure can never read below ~20 ms even for a free switch.
        for _ in 0 ..< 4 { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        let settled = nanos()
        return (called &- start, laidOut &- start, settled &- start)
    }

    var toNumeric = (call: [UInt64](), laidOut: [UInt64](), settled: [UInt64]())
    var toMain = (call: [UInt64](), laidOut: [UInt64](), settled: [UInt64]())
    #if DEBUG
    var bodiesToNumeric = 0
    var bodiesToMain = 0
    #endif
    for round in 0 ..< 45 {
        #if DEBUG
        let counterBefore = KeyViewBodyCounter.count
        #endif
        let forwardTime = timed(forward)
        #if DEBUG
        let counterMiddle = KeyViewBodyCounter.count
        #endif
        let backwardTime = timed(backward)
        // The first rounds warm SwiftUI's caches for both modes.
        guard round >= 5 else { continue }
        toNumeric.call.append(forwardTime.call)
        toNumeric.laidOut.append(forwardTime.laidOut)
        toNumeric.settled.append(forwardTime.settled)
        toMain.call.append(backwardTime.call)
        toMain.laidOut.append(backwardTime.laidOut)
        toMain.settled.append(backwardTime.settled)
        #if DEBUG
        bodiesToNumeric += counterMiddle - counterBefore
        bodiesToMain += KeyViewBodyCounter.count - counterMiddle
        #endif
    }

    // Where the switch's own time goes, without a hosting view observing it:
    // the mode change alone, and the feel cue a switch plays.
    do {
        let bare = BenchRig()
        let modes = [ModeNames.numeric, ModeNames.main]
        var index = 0
        let plain = measure("10g. switchToMode alone (no hosting view)", inputs: Array(0 ..< 2000)) { _ in
            bare.viewModel.switchToMode(modes[index % 2])
            index += 1
            return bare.viewModel.activeModeName.utf8.count
        }
        let cue = measure("10h. feel(.modeSwitch) alone", inputs: Array(0 ..< 2000)) { _ in
            bare.viewModel.feel(.modeSwitch)
            return 1
        }
        plain.report()
        cue.report()
        // The same two calls with the hosting graph observing the view model:
        // what SwiftUI's observation hooks add synchronously.
        var hostedIndex = 0
        let hostedPlain = measure("10i. switchToMode alone, hosting view observing", inputs: Array(0 ..< 200)) { _ in
            viewModel.switchToMode(modes[hostedIndex % 2])
            hostedIndex += 1
            return viewModel.activeModeName.utf8.count
        }
        let hostedCue = measure("10j. feel(.modeSwitch) alone, hosting view observing", inputs: Array(0 ..< 200)) { _ in
            viewModel.feel(.modeSwitch)
            return 1
        }
        hostedPlain.report()
        hostedCue.report()
        graph.settle()
    }
    print("10. mode switch latency, 40 alternating switches each way (the settle is 4 x 5 ms run-loop turns, so 'settled' is bounded below by ~20 ms):")
    let results = [
        Stats(name: "10a. main -> numeric: handleGesture only", samples: toNumeric.call),
        Stats(name: "10b. main -> numeric: + layout + display pass", samples: toNumeric.laidOut),
        Stats(name: "10c. main -> numeric: until settled (loop-bounded)", samples: toNumeric.settled),
        Stats(name: "10d. numeric -> main: handleGesture only", samples: toMain.call),
        Stats(name: "10e. numeric -> main: + layout + display pass", samples: toMain.laidOut),
        Stats(name: "10f. numeric -> main: until settled (loop-bounded)", samples: toMain.settled),
    ]
    #if DEBUG
    let switches = Double(toNumeric.call.count)
    print("    KeyView.body evaluations per switch: main -> numeric \(format(Double(bodiesToNumeric) / switches, 1)), "
        + "numeric -> main \(format(Double(bodiesToMain) / switches, 1))")
    #endif
    graph.tearDown()
    spinRunLoop(turns: 2)
    return results
}

#endif
