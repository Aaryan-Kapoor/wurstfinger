//
//  main.swift
//  WurstfingerSnapshots
//
//  Headless screenshot tool. Renders the real keyboard and app views to PNG
//  with SwiftUI's ImageRenderer — no Xcode, no simulator.
//
//      swift run WurstfingerSnapshots [--out DIR] [--filter TEXT] [--list] [--scale 3]
//

import AppKit
import Foundation
import SwiftUI
@testable import WurstfingerKit
@testable import WurstfingerScenarioKit

/// Re-launches the tool with the isolated-defaults launch argument if it was
/// started without it. `SharedDefaults.store` picks its suite from the process
/// arguments once, so this is the only way to keep the scenarios — which flip
/// settings like the keyboard style — away from the app group's real store.
func relaunchIsolatedIfNeeded() {
    guard !CommandLine.arguments.contains(SharedDefaults.isolatedStoreArgument) else { return }
    let process = Process()
    process.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = Array(CommandLine.arguments.dropFirst()) + [SharedDefaults.isolatedStoreArgument]
    do {
        try process.run()
    } catch {
        FileHandle.standardError.write(Data("cannot relaunch: \(error)\n".utf8))
        exit(EXIT_FAILURE)
    }
    process.waitUntilExit()
    exit(process.terminationStatus)
}

@MainActor
func runSnapshots() -> Int32 {
    let options: Options
    do {
        options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n\n\(Options.usage)\n".utf8))
        return 2
    }
    if let path = options.soundDemo {
        do {
            let result = try SoundDemo.render(to: URL(fileURLWithPath: path))
            print("\(result.strokes) strokes, \(String(format: "%.1f", result.seconds)) s -> \(path)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("sound demo failed: \(error)\n".utf8))
            return 1
        }
    }
    if options.emojiAudit {
        _ = NSApplication.shared
        let layouts: [(String, CGFloat, Double)] = [
            ("small keys (200 pt keyboard)", 320, 200), ("iPhone SE (320 pt screen)", 320, 270),
            ("iPhone 15", 393, 270), ("iPad (380 pt keyboard)", 1366, 380), ("large (520 pt keyboard)", 1366, 520),
        ]
        for (name, width, wish) in layouts {
            let metrics = KeyboardScenario(
                language: "en_US", containerWidth: width, settings: [.keyboardWidthPoints: wish]
            ).metrics
            let hintFont = min(metrics.cellWidth, metrics.cellHeight) * KeyTypography.emojiHintFraction
            let centerFont = min(metrics.cellWidth, metrics.cellHeight) * KeyTypography.emojiCenterFraction
            print("\(name): cell \(metrics.cellWidth) x \(metrics.cellHeight), emoji hint \(String(format: "%.1f", hintFont)) pt, centre \(String(format: "%.1f", centerFont)) pt")
            let report = EmojiInkAudit.run(metrics: metrics, tones: EmojiSkinTone.allCases, minimumGap: 1.0)
            print("\(name): key \(String(format: "%.1f x %.1f", report.keySize.width, report.keySize.height)) pt, "
                + "\(report.keysChecked) keys, \(report.glyphsMeasured) glyphs measured (\(report.blank) blank), "
                + "smallest gap \(String(format: "%.2f", report.smallestGap)) pt, "
                + "worst overflow \(String(format: "%.2f", report.worstOverflow)) pt, \(report.findings.count) findings")
            for finding in report.findings.sorted(by: { "\($0)" < "\($1)" }) { print("  \(finding)") }
        }
        let phone = KeyboardScenario(language: "en_US", containerWidth: 320).metrics
        let definitions = KeyboardRegistry.available.compactMap { KeyboardRegistry.load(id: $0.id) }
        let letters = EmojiInkAudit.run(layouts: definitions, modes: [ModeNames.main, ModeNames.shifted], metrics: phone)
        print("letter keys of \(definitions.count) layouts (main and shifted), key \(String(format: "%.1f", phone.cellWidth)) pt: "
            + "\(letters.keysChecked) distinct keys, \(letters.glyphsMeasured) glyphs (\(letters.blank) blank), "
            + "smallest gap \(String(format: "%.2f", letters.smallestGap)) pt, worst overflow \(String(format: "%.2f", letters.worstOverflow)) pt, "
            + "\(letters.findings.count) findings")
        print("  blank renders: \(letters.blankGlyphs.sorted().map { $0.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "+") })")
        for finding in letters.findings.sorted(by: { "\($0)" < "\($1)" }) { print("  \(finding)") }
        return 0
    }
    if options.showHelp {
        print(Options.usage)
        return 0
    }

    // `WURSTFINGER_HINT_RENDERING=views` renders the hints as view stacks, for
    // a pixel comparison against the shipped one-`Canvas` hints
    // (`KeyView.hintRendering`).
    switch ProcessInfo.processInfo.environment["WURSTFINGER_HINT_RENDERING"] {
    case "views": MainActor.assumeIsolated { KeyView.hintRendering = .views }
    case "canvas": MainActor.assumeIsolated { KeyView.hintRendering = .canvas }
    default: break
    }

    var scenarios = Catalog.all()
    if let filter = options.filter?.lowercased(), !filter.isEmpty {
        scenarios = scenarios.filter { $0.name.lowercased().contains(filter) }
    }
    if options.listOnly {
        for scenario in scenarios { print(scenario.name) }
        return 0
    }
    guard !scenarios.isEmpty else {
        FileHandle.standardError.write(Data("no scenario matches the filter\n".utf8))
        return 1
    }

    let directory = URL(fileURLWithPath: options.outputDirectory, isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
        FileHandle.standardError.write(Data("cannot create \(directory.path): \(error)\n".utf8))
        return 1
    }

    // A command-line process has no application object; SwiftUI resolves
    // appearance-dependent colours through it.
    _ = NSApplication.shared

    let start = Date()
    var entries: [ContactSheetEntry] = []
    var failures = 0
    for scenario in scenarios {
        let began = Date()
        let shot = scenario.make()
        do {
            let image = try Renderer.writePNG(shot, scale: options.scale, to: directory.appendingPathComponent(scenario.fileName))
            let size = "\(image.pixelWidth)x\(image.pixelHeight) px"
            entries.append(ContactSheetEntry(
                group: scenario.group, name: scenario.name, file: scenario.fileName,
                pixelSize: "\(size), \(Int(shot.size.width))x\(Int(shot.size.height)) pt", failure: nil
            ))
            let kilobytes = image.byteCount / 1024
            let seconds = String(format: "%.2f", Date().timeIntervalSince(began))
            print("ok    \(scenario.name.padding(toLength: 40, withPad: " ", startingAt: 0)) \(size.padding(toLength: 14, withPad: " ", startingAt: 0)) \(kilobytes) KB  \(seconds)s")
        } catch {
            failures += 1
            entries.append(ContactSheetEntry(
                group: scenario.group, name: scenario.name, file: scenario.fileName,
                pixelSize: "", failure: "\(error)"
            ))
            print("FAIL  \(scenario.name): \(error)")
        }
        withExtendedLifetime(shot) {}
    }

    let html = ContactSheet.html(entries: entries, scale: Int(options.scale.rounded()))
    let index = directory.appendingPathComponent("index.html")
    do {
        try html.write(to: index, atomically: true, encoding: .utf8)
    } catch {
        FileHandle.standardError.write(Data("cannot write \(index.path): \(error)\n".utf8))
        return 1
    }

    let seconds = String(format: "%.1f", Date().timeIntervalSince(start))
    print("\n\(entries.count - failures) of \(entries.count) images in \(seconds)s -> \(directory.path)")
    print("contact sheet: \(index.path)")
    return failures == 0 ? 0 : 1
}

relaunchIsolatedIfNeeded()
let status = MainActor.assumeIsolated { runSnapshots() }
exit(status)
