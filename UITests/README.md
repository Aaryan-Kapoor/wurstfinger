# UI tests

These are XCUITest sources, kept for when the project is built with Xcode. They
are **not** a SwiftPM target: XCUITest needs Xcode and a simulator or device, so
`swift test` does not build or run them.

The unit tests live in `Tests/WurstfingerKitTests` and run with `swift test`.
