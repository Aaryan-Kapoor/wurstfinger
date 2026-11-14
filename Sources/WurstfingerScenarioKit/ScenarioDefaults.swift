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

/// In-memory `UserDefaults`: the kit's `EphemeralDefaults`, which never
/// consults the standard domain it is nominally backed by.
typealias ScenarioDefaults = EphemeralDefaults
