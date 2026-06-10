import Foundation
import ServiceManagement

/// Thin wrapper around SMAppService for the "launch at login" toggle.
/// Most reliable when the app runs from /Applications (`make install`).
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func toggle() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                Log.app.notice("launch at login disabled")
            } else {
                try service.register()
                Log.app.notice("launch at login enabled")
            }
        } catch {
            Log.app.error("launch at login toggle failed: \(String(describing: error), privacy: .public)")
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
