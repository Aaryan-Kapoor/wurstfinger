// swift-tools-version:6.0

import Foundation
import PackageDescription

// SwiftUI's `#Preview` macro is implemented by a compiler plugin that ships
// with Xcode only. Builds with the Command Line Tools alone (no Xcode) cannot
// expand it, so the sources wrap each preview in `#if !WURSTFINGER_NO_PREVIEWS`
// and this flag switches them off there. Set WURSTFINGER_NO_PREVIEWS=1 / =0 in
// the environment to force the choice.
let developerDirectory: String = {
  let environment = ProcessInfo.processInfo.environment
  if let path = environment["DEVELOPER_DIR"] { return path }
  let link = "/var/db/xcode_select_link"
  return (try? FileManager.default.destinationOfSymbolicLink(atPath: link))
    ?? "/Library/Developer/CommandLineTools"
}()

let previewsUnavailable: Bool = {
  switch ProcessInfo.processInfo.environment["WURSTFINGER_NO_PREVIEWS"] {
  case "1": return true
  case "0": return false
  default: return !developerDirectory.contains(".app/Contents/Developer")
  }
}()

let sharedSwiftSettings: [SwiftSetting] =
  previewsUnavailable ? [.define("WURSTFINGER_NO_PREVIEWS")] : []

// The headless snapshot tool and the typing-scenario harness reach the
// kit's internals through `@testable import`, which needs a module compiled
// for testing. SwiftPM only does that for debug builds; this keeps it on for
// release builds too, on macOS only, so `swift run -c release
// WurstfingerSnapshots` works while the iOS app and extension builds are
// untouched.
let testableOnMac: [SwiftSetting] = [
  .unsafeFlags(["-enable-testing"], .when(platforms: [.macOS]))
]

let package = Package(
  name: "Wurstfinger",
  defaultLocalization: "en",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(name: "WurstfingerKit", targets: ["WurstfingerKit"]),
    .executable(name: "Wurstfinger", targets: ["Wurstfinger"]),
    .executable(name: "WurstfingerKeyboard", targets: ["WurstfingerKeyboard"]),
    .executable(name: "WurstfingerSnapshots", targets: ["WurstfingerSnapshots"]),
  ],
  targets: [
    // All app and keyboard code lives in one module so internal access keeps
    // working across the former app/extension split.
    .target(
      name: "WurstfingerKit",
      path: "Sources/WurstfingerKit",
      swiftSettings: sharedSwiftSettings + testableOnMac
    ),
    // Typing-by-gesture harness shared by the tests and the snapshot
    // tool: it synthesizes touch paths and drives the real recognition and
    // pipeline code of the kit.
    .target(
      name: "WurstfingerScenarioKit",
      dependencies: ["WurstfingerKit"],
      path: "Sources/WurstfingerScenarioKit",
      swiftSettings: testableOnMac
    ),
    // macOS command-line tool that renders the real keyboard and app views
    // to PNG through ImageRenderer (see Sources/WurstfingerSnapshots).
    .executableTarget(
      name: "WurstfingerSnapshots",
      dependencies: ["WurstfingerKit", "WurstfingerScenarioKit"],
      path: "Sources/WurstfingerSnapshots"
    ),
    .executableTarget(
      name: "Wurstfinger",
      dependencies: ["WurstfingerKit"],
      path: "Sources/Wurstfinger",
      resources: [.process("Resources")]
    ),
    .executableTarget(
      name: "WurstfingerKeyboard",
      dependencies: ["WurstfingerKit"],
      path: "Sources/WurstfingerKeyboard",
      resources: [.process("Resources")],
      linkerSettings: [
        // An app extension's entry point is _NSExtensionMain, not main().
        .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"], .when(platforms: [.iOS]))
      ]
    ),
    // Micro-benchmarks for the input path (see docs/performance.md). Reaches
    // module-internal code through `@testable` (hence `testableOnMac` on the
    // kit); macOS-only and never shipped.
    .executableTarget(
      name: "WurstfingerBench",
      dependencies: ["WurstfingerKit"],
      path: "Sources/WurstfingerBench"
    ),
    .testTarget(
      name: "WurstfingerKitTests",
      dependencies: ["WurstfingerKit", "WurstfingerScenarioKit"],
      path: "Tests/WurstfingerKitTests"
    ),
  ],
  swiftLanguageModes: [.v6]
)
