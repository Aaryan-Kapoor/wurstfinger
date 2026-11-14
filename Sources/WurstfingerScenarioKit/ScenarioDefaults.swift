//
//  ScenarioDefaults.swift
//  WurstfingerScenarioKit
//
//  A `UserDefaults` that lives in memory only. The scenario harness and the
//  snapshot tool hand one to every view model they build, so a scenario can
//  flip any setting without ever touching a plist on disk or the shared
//  app-group store the real keyboard reads.
//

import Foundation
@testable import WurstfingerKit

/// In-memory `UserDefaults`. Every accessor the keyboard code uses is
/// overridden, so the standard domain this object is nominally backed by is
/// never consulted.
final class ScenarioDefaults: UserDefaults {
    private var storage: [String: Any] = [:]
    private let lock = NSLock()

    convenience init() {
        self.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return storage[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.lock(); defer { lock.unlock() }
        storage[defaultName] = value
    }

    // The typed setters would otherwise resolve to the non-overridden
    // implementations and write to the real standard domain.
    override func set(_ value: Double, forKey defaultName: String) { set(value as NSNumber, forKey: defaultName) }
    override func set(_ value: Float, forKey defaultName: String) { set(value as NSNumber, forKey: defaultName) }
    override func set(_ value: Int, forKey defaultName: String) { set(value as NSNumber, forKey: defaultName) }
    override func set(_ value: Bool, forKey defaultName: String) { set(value as NSNumber, forKey: defaultName) }

    override func removeObject(forKey defaultName: String) {
        lock.lock(); defer { lock.unlock() }
        storage[defaultName] = nil
    }

    override func string(forKey defaultName: String) -> String? { object(forKey: defaultName) as? String }
    override func bool(forKey defaultName: String) -> Bool { (object(forKey: defaultName) as? NSNumber)?.boolValue ?? false }
    override func integer(forKey defaultName: String) -> Int { (object(forKey: defaultName) as? NSNumber)?.intValue ?? 0 }
    override func double(forKey defaultName: String) -> Double { (object(forKey: defaultName) as? NSNumber)?.doubleValue ?? 0 }
    override func stringArray(forKey defaultName: String) -> [String]? { object(forKey: defaultName) as? [String] }
    override func array(forKey defaultName: String) -> [Any]? { object(forKey: defaultName) as? [Any] }
    override func dictionary(forKey defaultName: String) -> [String: Any]? { object(forKey: defaultName) as? [String: Any] }
    override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
    override func float(forKey defaultName: String) -> Float { (object(forKey: defaultName) as? NSNumber)?.floatValue ?? 0 }
}
