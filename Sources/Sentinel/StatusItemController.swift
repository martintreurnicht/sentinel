import AppKit
import Sparkle

/// The menu bar icon and dropdown. The menu is rebuilt lazily each time it opens
/// (NSMenuDelegate), so settings checkmarks and the camera list are always current;
/// only the icon updates eagerly as monitor snapshots arrive.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let monitor: PresenceMonitor
    private let settings: Settings
    private let updater: SPUStandardUpdaterController
    private var snapshot = MonitorSnapshot(state: .initializing, lastCheckAt: nil)
    private var pendingUpdateVersion: String?

    init(monitor: PresenceMonitor, settings: Settings, updater: SPUStandardUpdaterController) {
        self.monitor = monitor
        self.settings = settings
        self.updater = updater
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
    }

    func update(with snapshot: MonitorSnapshot) {
        self.snapshot = snapshot
        updateIcon()
    }

    /// A staged update waiting to install (nil once none). The menu is rebuilt
    /// on every open, so the new state shows the next time the user looks.
    func setPendingUpdate(version: String?) {
        pendingUpdateVersion = version
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    // MARK: - Building

    private func updateIcon() {
        let symbolName: String = switch snapshot.state {
        case .initializing: "eye"
        case .present: "eye.fill"
        case .graceAbsence: "eye.slash"
        case .absent: "moon.zzz"
        case .locked: "lock.fill"
        case .paused: "pause.circle"
        case .error: "exclamationmark.triangle"
        }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Sentinel")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Sentinel — \(statusLine())"
    }

    private func statusLine() -> String {
        let time = snapshot.lastCheckAt.map { $0.formatted(date: .omitted, time: .standard) }
        switch snapshot.state {
        case .initializing:
            return "Checking…"
        case .present:
            return "Present" + (time.map { " — last check \($0)" } ?? "")
        case .graceAbsence:
            return settings.locksOnAbsence
                ? "No one seen — locking soon unless you return"
                : "No one seen — display may sleep soon unless you return"
        case .absent:
            return "Away — display may sleep" + (time.map { " — last check \($0)" } ?? "")
        case .locked:
            return "Screen locked"
        case .paused(let until):
            if let until {
                return "Paused until \(until.formatted(date: .omitted, time: .shortened))"
            }
            return "Paused"
        case .error(let reason):
            return "Problem: \(reason.displayText)"
        }
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        if case .paused = snapshot.state {
            menu.addItem(makeItem("Resume Monitoring", action: #selector(resumeMonitoring)))
        } else {
            menu.addItem(makeItem("Check Now", action: #selector(checkNow)))
            let pauseMenu = NSMenu()
            let pauseOptions: [(String, TimeInterval)] = [("For 15 Minutes", 15 * 60), ("For 1 Hour", 60 * 60)]
            for (title, seconds) in pauseOptions {
                pauseMenu.addItem(makeItem(title, action: #selector(pauseSelected(_:)), represented: seconds))
            }
            pauseMenu.addItem(makeItem("Until Resumed", action: #selector(pauseSelected(_:))))
            menu.addItem(submenu("Pause", pauseMenu))
        }
        menu.addItem(.separator())

        let intervalMenu = NSMenu()
        let intervalOptions: [(String, TimeInterval)] = [
            ("10 seconds", 10), ("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300),
        ]
        for (title, seconds) in intervalOptions {
            let item = makeItem(title, action: #selector(intervalSelected(_:)), represented: seconds)
            item.state = settings.pollIntervalSeconds == seconds ? .on : .off
            intervalMenu.addItem(item)
        }
        menu.addItem(submenu("Check Every", intervalMenu))

        let graceMenu = NSMenu()
        let graceOptions: [(String, TimeInterval)] = [
            ("Immediately", 0), ("After 15 seconds", 15), ("After 30 seconds", 30),
            ("After 1 minute", 60), ("After 2 minutes", 120),
        ]
        for (title, seconds) in graceOptions {
            let item = makeItem(title, action: #selector(graceSelected(_:)), represented: seconds)
            item.state = settings.locksOnAbsence && settings.absenceGraceSeconds == seconds ? .on : .off
            graceMenu.addItem(item)
        }
        graceMenu.addItem(.separator())
        let never = makeItem("Never (don't lock)", action: #selector(neverLockSelected))
        never.state = settings.locksOnAbsence ? .off : .on
        graceMenu.addItem(never)
        menu.addItem(submenu("Lock After Absence", graceMenu))

        let detectionMenu = NSMenu()
        let person = makeItem("Anyone in View", action: #selector(detectionModeSelected(_:)), represented: DetectionMode.person.rawValue)
        person.state = settings.detectionMode == .person ? .on : .off
        detectionMenu.addItem(person)
        let faceOnly = makeItem("Face Only (stricter)", action: #selector(detectionModeSelected(_:)), represented: DetectionMode.face.rawValue)
        faceOnly.state = settings.detectionMode == .face ? .on : .off
        detectionMenu.addItem(faceOnly)
        menu.addItem(submenu("Presence Detection", detectionMenu))

        let cameraMenu = NSMenu()
        let automatic = makeItem("Automatic", action: #selector(cameraSelected(_:)), represented: "")
        automatic.state = settings.cameraUniqueID.isEmpty ? .on : .off
        cameraMenu.addItem(automatic)
        for camera in CameraService.availableCameras() {
            let item = makeItem(camera.name, action: #selector(cameraSelected(_:)), represented: camera.uniqueID)
            item.state = settings.cameraUniqueID == camera.uniqueID ? .on : .off
            cameraMenu.addItem(item)
        }
        menu.addItem(submenu("Camera", cameraMenu))

        let loginTitle = LaunchAtLogin.requiresApproval ? "Launch at Login (approval needed)" : "Launch at Login"
        let loginItem = makeItem(loginTitle, action: #selector(toggleLaunchAtLogin))
        loginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let version = NSMenuItem(title: "Sentinel \(Self.appVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        if let pending = pendingUpdateVersion {
            // Resumes the staged update via Sparkle (Install and Relaunch);
            // otherwise it applies silently on the next quit/restart.
            menu.addItem(makeItem("Update Ready (\(pending)) — Install Now…", action: #selector(installUpdate)))
        } else {
            let checkItem = NSMenuItem(
                title: "Check for Updates…",
                action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                keyEquivalent: ""
            )
            checkItem.target = updater
            menu.addItem(checkItem)
        }
        let autoUpdateItem = makeItem("Update Automatically", action: #selector(toggleAutomaticUpdates))
        autoUpdateItem.state = updater.updater.automaticallyChecksForUpdates ? .on : .off
        menu.addItem(autoUpdateItem)

        if case .error(.cameraPermissionDenied) = snapshot.state {
            menu.addItem(.separator())
            menu.addItem(makeItem("Open Camera Privacy Settings…", action: #selector(openPrivacySettings)))
        }

        menu.addItem(.separator())
        menu.addItem(makeItem("Quit Sentinel", action: #selector(quit)))
    }

    private func makeItem(_ title: String, action: Selector, represented: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = represented
        return item
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static let appVersion: String = {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "v\(short ?? "?")"
    }()

    // MARK: - Actions

    @objc private func checkNow() {
        Task { await monitor.checkNow() }
    }

    @objc private func pauseSelected(_ sender: NSMenuItem) {
        let seconds = sender.representedObject as? TimeInterval
        Task { await monitor.pause(for: seconds) }
    }

    @objc private func resumeMonitoring() {
        Task { await monitor.resume() }
    }

    @objc private func intervalSelected(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        settings.pollIntervalSeconds = seconds
        Task { await monitor.settingsChanged() }
    }

    @objc private func graceSelected(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        settings.locksOnAbsence = true
        settings.absenceGraceSeconds = seconds
    }

    @objc private func neverLockSelected() {
        settings.locksOnAbsence = false
    }

    @objc private func detectionModeSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = DetectionMode(rawValue: raw) else { return }
        settings.detectionMode = mode
    }

    @objc private func cameraSelected(_ sender: NSMenuItem) {
        guard let uniqueID = sender.representedObject as? String else { return }
        settings.cameraUniqueID = uniqueID
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLogin.toggle()
    }

    @objc private func installUpdate() {
        updater.checkForUpdates(nil)
    }

    @objc private func toggleAutomaticUpdates() {
        // Sparkle persists both in this app's defaults, overriding the
        // Info.plist defaults (on for fresh installs). Off means no checks
        // and no downloads on Sentinel's own — manual checks still work.
        let enabled = !updater.updater.automaticallyChecksForUpdates
        updater.updater.automaticallyChecksForUpdates = enabled
        updater.updater.automaticallyDownloadsUpdates = enabled
    }

    @objc private func openPrivacySettings() {
        let cameraPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        guard let url = URL(string: cameraPane) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
