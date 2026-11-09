import SwiftUI
import AppKit

@main
struct ButlerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = Model.shared
    @StateObject private var sync = AppleSync.shared
    @AppStorage("showIsland") private var showIsland = true
    @AppStorage("lowSpaceWarnings") private var lowSpaceWarnings = true
    @AppStorage("weeklyTidy") private var weeklyTidy = true
    @AppStorage("showNowPlaying") private var showNowPlaying = true
    @AppStorage("hogAlerts") private var hogAlerts = true
    @AppStorage("devMode") private var devMode = false

    init() {
        if CommandLine.arguments.contains("--dump") { Dump.run(); exit(0) }
    }

    var body: some Scene {
        WindowGroup("Butler") {
            ContentView(model: model)
                .background(WindowAccessor { AppDelegate.shared?.attach($0) })
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 760, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Toggle("Show Island", isOn: $showIsland)
                Toggle("Open at Login", isOn: Binding(get: { LoginItem.enabled }, set: { LoginItem.set($0) }))
                Divider()
                Toggle("Low Space Warnings", isOn: $lowSpaceWarnings)
                Toggle("Weekly Tidy", isOn: $weeklyTidy)
                Button("Tidy Now") { Watchman.shared.tidyIfDue(force: true) }
                Toggle("Show Now Playing", isOn: $showNowPlaying)
                Toggle("Warn When Mac Is Struggling", isOn: $hogAlerts)
                Toggle("Developer Mode", isOn: $devMode)
                Divider()
                Toggle("Sync Tasks With Reminders", isOn: Binding(get: { sync.reminders }, set: { sync.setReminders($0) }))
                Toggle("Show Calendar in Tasks", isOn: Binding(get: { sync.calendar }, set: { sync.setCalendar($0) }))
                Divider()
                Button("Call Butler") { AppDelegate.shared?.summon() }
                    .keyboardShortcut("b", modifiers: [.option, .command])
            }
        }
    }
}

/// Hands the SwiftUI window to the app delegate so closing it can dock Butler into the island instead of quitting.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    nonisolated(unsafe) static weak var shared: AppDelegate?
    private var island: IslandController?
    private weak var mainWindow: NSWindow?

    override init() { super.init(); AppDelegate.shared = self }

    func applicationDidFinishLaunching(_ notification: Notification) {
        island = MainActor.assumeIsolated { IslandController(model: .shared, open: { AppDelegate.shared?.showMain() }) }
        MainActor.assumeIsolated {
            Tasks.shared.start()
            AppleSync.shared.start()
            Watchman.shared.start()
            NowPlaying.shared.start()
            Monitor.shared.start()
            _ = Shelf.shared
        }
        Hotkey.register { AppDelegate.shared?.summon() }
        apply()
        if Debug.dock {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                if let w = self?.mainWindow { _ = self?.windowShouldClose(w) }
            }
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.apply()
        }
    }

    private func apply() {
        let on = UserDefaults.standard.object(forKey: "showIsland") as? Bool ?? true
        MainActor.assumeIsolated { island?.setVisible(on) }
    }

    func attach(_ window: NSWindow) {
        guard mainWindow == nil else { return }
        mainWindow = window
        window.delegate = self
    }

    /// The red button docks Butler into the island. Quit with Command Q.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    /// Option + Command + B: drop the island open at the notch, or put it away again.
    func summon() { MainActor.assumeIsolated { island?.summon() } }

    func showMain() {
        NSApp.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMain(); return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
