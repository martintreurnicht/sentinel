import Foundation
import Testing
@testable import Sentinel

/// A Settings instance backed by a throwaway UserDefaults suite.
struct ScratchSettings {
    let settings: Settings
    private let suiteName: String
    private let defaults: UserDefaults

    init() {
        suiteName = "SentinelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        Settings.registerDefaults(on: defaults)
        settings = Settings(defaults: defaults)
    }

    func set(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@Test func cameraSessionModeDefaultsToOnlyWhileChecking() {
    let scratch = ScratchSettings()
    defer { scratch.cleanUp() }
    #expect(scratch.settings.cameraSessionMode == .onlyWhileChecking)
}

@Test func cameraSessionModeRoundTrips() {
    let scratch = ScratchSettings()
    defer { scratch.cleanUp() }
    for mode: CameraSessionMode in [.always, .onACPower, .onlyWhileChecking] {
        scratch.settings.cameraSessionMode = mode
        #expect(scratch.settings.cameraSessionMode == mode)
    }
}

@Test func cameraSessionModeFallsBackOnUnknownValue() {
    let scratch = ScratchSettings()
    defer { scratch.cleanUp() }
    scratch.set("steady", forKey: Settings.Key.cameraKeepOn)
    #expect(scratch.settings.cameraSessionMode == .onlyWhileChecking)
}
