import CoreGraphics
import Foundation

/// Locks the screen and confirms the lock actually engaged.
///
/// Primary mechanism: the private `SACLockScreenImmediate` from login.framework —
/// locks immediately regardless of the "require password after sleep" setting.
/// Fallback: `pmset displaysleepnow`, which only results in a lock if the system is
/// configured to require a password immediately after the display sleeps.
struct ScreenLocker: ScreenLocking {
    let settings: Settings

    private typealias LockFunction = @convention(c) () -> Int32

    private static let sacLockScreenImmediate: LockFunction? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login",
            RTLD_LAZY
        ) else {
            Log.lock.warning("could not dlopen login.framework; private lock API unavailable")
            return nil
        }
        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            Log.lock.warning("SACLockScreenImmediate not found; private lock API unavailable")
            return nil
        }
        return unsafeBitCast(symbol, to: LockFunction.self)
    }()

    func lock() async -> Bool {
        let method = settings.lockMethod

        if method != .pmset {
            if let lockFunction = Self.sacLockScreenImmediate {
                Log.lock.notice("locking screen via SACLockScreenImmediate")
                let status = lockFunction()
                if status != 0 {
                    Log.lock.warning("SACLockScreenImmediate returned \(status)")
                }
                if await Self.confirmLocked(within: 3) {
                    return true
                }
                Log.lock.warning("private API lock did not confirm within 3s")
            }
            if method == .privateAPI {
                return false
            }
        }

        Log.lock.notice("locking screen via pmset displaysleepnow")
        runPmsetDisplaySleep()
        return await Self.confirmLocked(within: 5)
    }

    static func isScreenLocked() -> Bool {
        guard let sessionInfo = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        if let locked = sessionInfo["CGSSessionScreenIsLocked"] as? Bool {
            return locked
        }
        if let locked = sessionInfo["CGSSessionScreenIsLocked"] as? Int {
            return locked != 0
        }
        return false
    }

    private static func confirmLocked(within seconds: Double) async -> Bool {
        let steps = Int(seconds / 0.25)
        for _ in 0..<steps {
            if isScreenLocked() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return isScreenLocked()
    }

    private func runPmsetDisplaySleep() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Log.lock.error("failed to run pmset: \(String(describing: error), privacy: .public)")
        }
    }
}
