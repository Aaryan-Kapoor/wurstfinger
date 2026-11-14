//
//  UnitTestHost.swift
//  Wurstfinger
//
//  Keeps `swift test` away from state the developer's own machine shares:
//  the app-group settings plist and the system pasteboard.
//

import Foundation

/// Whether this process is SwiftPM's unit-test runner.
///
/// The kit reaches two process-external stores through statics: the shared
/// settings suite (`SharedDefaults.store`) and the system pasteboard
/// (`ClipboardStore.shared`). Under `swift test` both are real on a Mac — the
/// suite is the same plist the Mac build of the app writes, and the pasteboard
/// is the developer's clipboard — so a test that reached either one would leak
/// state into the next run, race a second test process (another worktree, a
/// watch loop), and clobber what the developer last copied. Under the test
/// runner both statics resolve to in-memory stand-ins instead, so the whole
/// suite is hermetic without every test having to remember to inject.
///
/// macOS only: that is where `swift test` runs. On iOS the check is
/// compiled out and always false, so no shipped binary changes behaviour
/// based on its process name.
enum UnitTestHost {
    /// Decided once, at first use.
    static let isActive: Bool = isTestRunner(processName: ProcessInfo.processInfo.processName)

    /// `swiftpm-testing-helper` hosts Swift Testing; `xctest` hosts XCTest
    /// bundles (with Xcode installed).
    static func isTestRunner(processName: String) -> Bool {
        #if os(macOS)
            processName == "swiftpm-testing-helper" || processName == "xctest"
        #else
            false
        #endif
    }
}

/// A `UserDefaults` that lives in memory only and is private to its instance.
///
/// Every accessor the kit uses is overridden, so the standard domain this
/// object is nominally backed by is never read or written. Writes post
/// `UserDefaults.didChangeNotification` like a real store does, so code that
/// observes its store (the view model) behaves as it would in the app.
///
/// `@unchecked Sendable` like `UserDefaults` itself is documented to be:
/// `storage` is only touched under `lock`.
final class EphemeralDefaults: UserDefaults, @unchecked Sendable {
    private var storage: [String: Any] = [:]
    private let lock = NSLock()

    convenience init() {
        // A nil suite name backs `super` with the standard domain, which the
        // overrides below never consult.
        self.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? {
        lock.withLock { storage[defaultName] }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock { storage[defaultName] = value }
        // Outside the lock: observers read the store back.
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
    }

    // The typed setters would otherwise resolve to the non-overridden
    // implementations and write to the real standard domain.
    override func set(_ value: Double, forKey defaultName: String) { set(value as NSNumber, forKey: defaultName) }
    override func set(_ value: Float, forKey defaultName: String) { set(value as NSNumber, forKey: defaultName) }
    override func set(_ value: Int, forKey defaultName: String) { set(value as NSNumber, forKey: defaultName) }
    override func set(_ value: Bool, forKey defaultName: String) { set(value as NSNumber, forKey: defaultName) }
    override func set(_ url: URL?, forKey defaultName: String) { set(url?.absoluteString, forKey: defaultName) }

    override func removeObject(forKey defaultName: String) {
        set(nil as Any?, forKey: defaultName)
    }

    override func removePersistentDomain(forName domainName: String) {
        lock.withLock { storage.removeAll() }
    }

    override func register(defaults registrationDictionary: [String: Any]) {
        lock.withLock {
            for (key, value) in registrationDictionary where storage[key] == nil {
                storage[key] = value
            }
        }
    }

    override func dictionaryRepresentation() -> [String: Any] {
        lock.withLock { storage }
    }

    override func string(forKey defaultName: String) -> String? { object(forKey: defaultName) as? String }
    override func bool(forKey defaultName: String) -> Bool { (object(forKey: defaultName) as? NSNumber)?.boolValue ?? false }
    override func integer(forKey defaultName: String) -> Int { (object(forKey: defaultName) as? NSNumber)?.intValue ?? 0 }
    override func double(forKey defaultName: String) -> Double { (object(forKey: defaultName) as? NSNumber)?.doubleValue ?? 0 }
    override func float(forKey defaultName: String) -> Float { (object(forKey: defaultName) as? NSNumber)?.floatValue ?? 0 }
    override func stringArray(forKey defaultName: String) -> [String]? { object(forKey: defaultName) as? [String] }
    override func array(forKey defaultName: String) -> [Any]? { object(forKey: defaultName) as? [Any] }
    override func dictionary(forKey defaultName: String) -> [String: Any]? { object(forKey: defaultName) as? [String: Any] }
    override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
    override func url(forKey defaultName: String) -> URL? { string(forKey: defaultName).flatMap(URL.init(string:)) }
}
