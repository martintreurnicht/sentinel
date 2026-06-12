import Foundation
import Testing
@testable import Sentinel

final class MockPowerSource: PowerSourceMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var onAC: Bool

    init(onAC: Bool) {
        self.onAC = onAC
    }

    var isOnACPower: Bool {
        lock.withLock { onAC }
    }

    func set(onAC: Bool) {
        lock.withLock { self.onAC = onAC }
    }
}

final class MockContinuousCamera: ContinuousCaptureControlling, @unchecked Sendable {
    struct Call: Equatable {
        let enabled: Bool
        let deviceUniqueID: String?
        let resolution: CaptureResolution?
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    func setContinuousCapture(enabled: Bool, deviceUniqueID: String?, resolution: CaptureResolution?) {
        lock.withLock {
            calls.append(Call(enabled: enabled, deviceUniqueID: deviceUniqueID, resolution: resolution))
        }
    }

    var last: Call? {
        lock.withLock { calls.last }
    }
}

@Test func continuousSessionPolicyTable() {
    #expect(!CameraModeController.wantsContinuousSession(mode: .onlyWhileChecking, isOnACPower: true))
    #expect(!CameraModeController.wantsContinuousSession(mode: .onlyWhileChecking, isOnACPower: false))
    #expect(CameraModeController.wantsContinuousSession(mode: .always, isOnACPower: true))
    #expect(CameraModeController.wantsContinuousSession(mode: .always, isOnACPower: false))
    #expect(CameraModeController.wantsContinuousSession(mode: .onACPower, isOnACPower: true))
    #expect(!CameraModeController.wantsContinuousSession(mode: .onACPower, isOnACPower: false))
}

@Test func alwaysModeFollowsMonitoringActivity() throws {
    let scratch = try ScratchSettings()
    defer { scratch.cleanUp() }
    scratch.settings.cameraSessionMode = .always
    let camera = MockContinuousCamera()
    let controller = CameraModeController(
        camera: camera,
        settings: scratch.settings,
        powerSource: MockPowerSource(onAC: false)
    )

    controller.setMonitoringActive(true)
    #expect(camera.last == .init(enabled: true, deviceUniqueID: nil, resolution: nil))

    controller.setMonitoringActive(false)
    #expect(camera.last == .init(enabled: false, deviceUniqueID: nil, resolution: nil))
}

@Test func acPowerModeFollowsThePowerSource() throws {
    let scratch = try ScratchSettings()
    defer { scratch.cleanUp() }
    scratch.settings.cameraSessionMode = .onACPower
    let camera = MockContinuousCamera()
    let powerSource = MockPowerSource(onAC: false)
    let controller = CameraModeController(camera: camera, settings: scratch.settings, powerSource: powerSource)

    controller.setMonitoringActive(true)
    #expect(camera.last?.enabled == false) // on battery -> per-check captures

    powerSource.set(onAC: true)
    controller.refresh()
    #expect(camera.last?.enabled == true)

    powerSource.set(onAC: false)
    controller.refresh()
    #expect(camera.last?.enabled == false)
}

@Test func onlyWhileCheckingNeverEnablesTheSession() throws {
    let scratch = try ScratchSettings()
    defer { scratch.cleanUp() }
    let camera = MockContinuousCamera()
    let controller = CameraModeController(
        camera: camera,
        settings: scratch.settings,
        powerSource: MockPowerSource(onAC: true)
    )

    controller.setMonitoringActive(true)
    #expect(camera.last == .init(enabled: false, deviceUniqueID: nil, resolution: nil))
}

@Test func configuredDeviceIsForwardedAndEmptyNormalizesToNil() throws {
    let scratch = try ScratchSettings()
    defer { scratch.cleanUp() }
    scratch.settings.cameraSessionMode = .always
    scratch.settings.cameraUniqueID = "cam-42"
    let camera = MockContinuousCamera()
    let controller = CameraModeController(
        camera: camera,
        settings: scratch.settings,
        powerSource: MockPowerSource(onAC: true)
    )

    controller.setMonitoringActive(true)
    #expect(camera.last == .init(enabled: true, deviceUniqueID: "cam-42", resolution: nil))

    scratch.settings.cameraUniqueID = ""
    controller.refresh()
    #expect(camera.last == .init(enabled: true, deviceUniqueID: nil, resolution: nil))

    scratch.settings.cameraResolution = CaptureResolution(width: 1920, height: 1080)
    controller.refresh()
    #expect(camera.last?.resolution == CaptureResolution(width: 1920, height: 1080))
}
