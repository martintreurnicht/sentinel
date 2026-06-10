import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private var monitor: PresenceMonitor?
    private var sessionObserver: SessionStateObserver?
    private let power = PowerAssertionController()
    private var activityToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Settings.registerDefaults()
        Log.app.notice("Sentinel launched (bundle: \(Bundle.main.bundlePath, privacy: .public))")

        // Defeat App Nap so the 30s poll cadence holds, without preventing idle
        // system sleep — when the user is absent the machine may sleep normally.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Webcam presence polling"
        )

        let settings = Settings()
        let checker = CameraPresenceChecker(camera: CameraService(), detector: FaceDetector(), settings: settings)
        let locker = ScreenLocker(settings: settings)
        let monitor = PresenceMonitor(
            checker: checker,
            locker: locker,
            power: power,
            config: settings,
            isScreenLocked: { ScreenLocker.isScreenLocked() }
        )
        self.monitor = monitor

        let observer = SessionStateObserver { event in
            Task { await monitor.handleSessionEvent(event) }
        }
        observer.start()
        self.sessionObserver = observer

        let statusController = StatusItemController(monitor: monitor, settings: settings)
        self.statusController = statusController

        Task {
            await monitor.setSnapshotHandler { snapshot in
                Task { @MainActor in
                    statusController.update(with: snapshot)
                }
            }
            await monitor.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Assertions die with the process anyway, but release deterministically.
        power.setPresent(false)
        sessionObserver?.stop()
        Log.app.notice("Sentinel terminating")
    }
}
