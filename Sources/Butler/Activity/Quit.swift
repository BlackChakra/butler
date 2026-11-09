import AppKit

enum Quit {
    static let patience: TimeInterval = 4

    /// Never quit these from Butler: macOS needs them, and quitting them only makes the screen flash and restart them.
    static let protectedBundles: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver",
        "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.WindowManager",
        "com.apple.Spotlight", "com.apple.TextInputMenuAgent",
    ]

    static func protected(_ a: AppUsage) -> Bool {
        guard a.isApp, let app = NSRunningApplication(processIdentifier: a.pid), let id = app.bundleIdentifier else { return false }
        return protectedBundles.contains(id) || id == Bundle.main.bundleIdentifier
    }

    static func politely(_ a: AppUsage) {
        if let app = NSRunningApplication(processIdentifier: a.pid), app.bundleURL != nil {
            if !app.terminate() { kill(a.pid, SIGTERM) }
        } else {
            kill(a.pid, SIGTERM)
        }
    }

    static func force(_ a: AppUsage) {
        if let app = NSRunningApplication(processIdentifier: a.pid), app.bundleURL != nil, app.forceTerminate() { return }
        kill(a.pid, SIGKILL)
    }
}
