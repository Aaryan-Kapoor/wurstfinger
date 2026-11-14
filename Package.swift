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
  ],
  targets: [
    // All app and keyboard code lives in one module so internal access keeps
    // working across the former app/extension split.
    .target(
      name: "WurstfingerKit",
      path: "Sources/WurstfingerKit",
      swiftSettings: sharedSwiftSettings
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
    // module-internal code through `@testable`, so it must be built with
    // `-Xswiftc -enable-testing`; it is macOS-only and never shipped.
    .executableTarget(
      name: "WurstfingerBench",
      dependencies: ["WurstfingerKit"],
      path: "Sources/WurstfingerBench"
    ),
    .testTarget(
      name: "WurstfingerKitTests",
      dependencies: ["WurstfingerKit"],
      path: "Tests/WurstfingerKitTests"
    ),
  ],
  swiftLanguageModes: [.v6]
)
