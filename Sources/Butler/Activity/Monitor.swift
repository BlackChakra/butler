import AppKit
import Darwin
import IOKit
import IOKit.ps

/// One app (with all its helper processes) or one stand-alone process, and what it is using right now.
struct AppUsage: Identifiable, Equatable {
    var id: String            // the app bundle path, or "pid:N" for a process that is not part of an app
    var name: String
    var pid: pid_t            // the process to quit
    var iconPath: String
    var processes = 1
    var cpu: Double = 0       // percent of one core, like Activity Monitor (two busy cores = 200%)
    var memory: Int64 = 0
    var gpu: Double = 0       // percent of the GPU's time
    var wakeups: Double = 0   // per second
    var isApp = false         // a real app from the Dock or menu bar
    var system = false        // part of macOS: shown, never offered for quitting
    var owner: String?        // run by Podman or Docker: stop it from there, not here

    /// A rough energy score in the spirit of Activity Monitor's Energy Impact: processor and graphics work, plus a little
    /// for waking the Mac up often, which keeps it from resting.
    var energy: Double { cpu + gpu + min(wakeups / 100, 10) }
}

/// A server listening on a port, started from a terminal or a dev tool.
struct DevServer: Identifiable, Equatable {
    enum Kind: Equatable {
        case process                // stop it like any program
        case service(String)        // kept alive by launchd (a Homebrew service): stopping it unloads it until next login
        case container(String)      // Podman or Docker's port forwarder: stop it from Podman or Docker instead
    }
    var id: String { "\(pid):\(port)" }
    var pid: pid_t
    var port: Int
    var network: Bool               // listening on every address, so other devices on the network can reach it
    var tool: String
    var folder: String
    var started: Date?
    var kind: Kind
    var project: String {
        if case .container(let owner) = kind { return "\(owner) container" }
        return folder == "/" || folder.isEmpty ? tool : (folder as NSString).lastPathComponent
    }
}

/// Something that has kept the Mac busy long enough to mention at the notch.
struct Hog: Equatable {
    enum Reason: Equatable { case cpu, battery, memory }
    var reason: Reason
    var app: AppUsage
    var since: Date
}

/// Watches what every app is using. Quietly in the background (every ten seconds, only to notice an app that runs hot),
/// and live every two seconds while the Activity tab is on screen.
@MainActor
final class Monitor: ObservableObject {
    static let shared = Monitor()

    @Published private(set) var apps: [AppUsage] = []
    @Published private(set) var cpu: Double = 0                 // whole Mac, 0 to 100
    @Published private(set) var memoryUsed: Int64 = 0
    @Published private(set) var pressure = 1                    // 1 normal, 2 warning, 4 critical
    @Published private(set) var gpu: Double = 0                 // 0 to 100
    @Published private(set) var battery: Battery?
    @Published private(set) var history = History()
    @Published private(set) var servers: [DevServer] = []
    @Published private(set) var hog: Hog?
    /// Apps asked to quit, and when. After a few seconds without quitting, the button becomes Force Quit.
    @Published private(set) var quitting: [String: Date] = [:]
    @Published private(set) var stopping: [String: Date] = [:]
    @Published private(set) var loaded = false

    let memoryTotal = Int64(ProcessInfo.processInfo.physicalMemory)
    let cores = ProcessInfo.processInfo.activeProcessorCount

    struct Battery: Equatable {
        var level: Int
        var onBattery: Bool
        var charging: Bool
        var minutesLeft: Int?
    }

    struct History: Equatable {
        var cpu: [Double] = []
        var memory: [Double] = []
        var gpu: [Double] = []
        var energy: [Double] = []
        mutating func add(cpu c: Double, memory m: Double, gpu g: Double, energy e: Double) {
            func push(_ a: inout [Double], _ v: Double) { a.append(v); if a.count > 60 { a.removeFirst(a.count - 60) } }
            push(&cpu, c); push(&memory, m); push(&gpu, g); push(&energy, e)
        }
    }

    static var hogAlertsOn: Bool { UserDefaults.standard.object(forKey: "hogAlerts") as? Bool ?? true }
    static var devMode: Bool { UserDefaults.standard.bool(forKey: "devMode") }

    private let sampler = Sampler()
    private let queue = DispatchQueue(label: "butler.monitor", qos: .utility)
    private var timer: Timer?
    private var watchers = 0
    private var busy = false
    private var lastSample = Date.distantPast
    private var lastServers = Date.distantPast
    private var icons: [String: NSImage] = [:]

    // Hog tracking
    private var hotSince: [String: Date] = [:]
    private var pressureSince: Date?
    private var muted: [String: Date] = [:]       // app id → quiet until
    private var hogClear: DispatchWorkItem?
    private var hogViewed = false
    private var hideWhenClosed = false

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if Debug.ports {
            queue.async { for p in Ports.scan() { FileHandle.standardError.write("port \(p.port) \(p.tool) \(p.folder) \(p.kind) \(p.network)\n".data(using: .utf8)!) } }
        }
        if Debug.hog {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, let a = self.apps.first(where: { !$0.system }) else { return }
                var app = a; app.cpu = max(app.cpu, 142)
                self.hog = Hog(reason: .cpu, app: app, since: Date().addingTimeInterval(-200))
            }
        }
    }

    /// The Activity tab calls this while it is on screen, for live numbers.
    func watch(_ on: Bool) {
        watchers = max(0, watchers + (on ? 1 : -1))
        if on { lastSample = .distantPast; lastServers = .distantPast; tick() }
    }

    private var live: Bool {
        guard watchers > 0 else { return false }
        // Only while the Butler window is actually visible, not when it has been docked into the island.
        return NSApp.windows.contains { !($0 is NSPanel) && $0.isVisible && $0.occlusionState.contains(.visible) }
    }

    private func tick() {
        let live = self.live
        let interval: TimeInterval = live ? 2 : 10
        guard live || Self.hogAlertsOn || hog != nil else { return }
        guard !busy, Date().timeIntervalSince(lastSample) >= interval - 0.05 else { return }
        busy = true
        lastSample = Date()
        let wantServers = live && Self.devMode && Date().timeIntervalSince(lastServers) >= 3
        if wantServers { lastServers = Date() }
        let sampler = self.sampler
        queue.async {
            let s = sampler.sample()
            let servers = wantServers ? Ports.scan() : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let m = Monitor.shared
                    m.busy = false
                    m.apply(s)
                    if let servers { m.servers = servers }
                    if !Monitor.devMode && !m.servers.isEmpty { m.servers = [] }
                }
            }
        }
    }

    private func apply(_ s: Sampler.Result) {
        cpu = s.cpu
        memoryUsed = s.memoryUsed
        pressure = s.pressure
        gpu = s.gpu
        battery = s.battery
        apps = s.apps
        let total = s.apps.reduce(0) { $0 + $1.energy }
        history.add(cpu: s.cpu, memory: Double(s.memoryUsed) / Double(max(memoryTotal, 1)) * 100, gpu: s.gpu, energy: total)
        loaded = true
        // Forget quit requests for apps that are gone.
        let ids = Set(s.apps.map(\.id))
        for id in quitting.keys where !ids.contains(id) { quitting[id] = nil }
        let live = Set(servers.map(\.id))
        for id in stopping.keys where !live.contains(id) { stopping[id] = nil }
        watchForHogs(s)
    }

    func icon(_ a: AppUsage) -> NSImage {
        if let i = icons[a.iconPath] { return i }
        if a.id == Sampler.macOS {
            let i = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: "macOS") ?? NSImage()
            icons[a.iconPath] = i
            return i
        }
        let i = NSWorkspace.shared.icon(forFile: a.iconPath)
        icons[a.iconPath] = i
        return i
    }

    // MARK: Running hot

    /// Speaks up only when the Mac is genuinely struggling, never for ordinary heavy use like streaming a film:
    /// - CPU: one app holds at least 30% of all cores (3 of 10 here) for five minutes, while the whole Mac is above 75%;
    /// - battery: unplugged, at 20% or less, and one app burns more than a core and a half for three minutes;
    /// - memory: macOS itself reports critical memory pressure for a full minute ("rising" is normal and ignored).
    /// The alert shows for 20 seconds, then steps aside and stays quiet about that app for two hours.
    private func watchForHogs(_ s: Sampler.Result) {
        let now = Date()
        let b = s.battery
        let lowBattery = (b?.onBattery ?? false) && !(b?.charging ?? false) && (b?.level ?? 100) <= 20
        let line = lowBattery ? 150 : max(300, Double(cores) * 30)
        let strained = lowBattery || s.cpu >= 75
        let me = ProcessInfo.processInfo.processIdentifier
        let candidates = s.apps.filter { !$0.system && $0.owner == nil && $0.pid != me && !Quit.protected($0) }

        for a in candidates {
            if a.energy >= line && strained { hotSince[a.id] = hotSince[a.id] ?? now }
            else if a.energy < line * 0.7 || !strained { hotSince[a.id] = nil }
        }
        let present = Set(candidates.map(\.id))
        for id in hotSince.keys where !present.contains(id) { hotSince[id] = nil }
        if s.pressure >= 4 { pressureSince = pressureSince ?? now } else { pressureSince = nil }

        guard Self.hogAlertsOn else { hog = nil; return }

        // While an alert is up, keep its numbers live. It leaves on its own timer (see show), or when things calm.
        if let h = hog {
            switch h.reason {
            case .memory: if pressureSince == nil { hog = nil }
            case .cpu, .battery:
                if let a = candidates.first(where: { $0.id == h.app.id }), hotSince[a.id] != nil { hog?.app = a } else { hog = nil }
            }
            return
        }

        if let since = pressureSince, now.timeIntervalSince(since) >= 60,
           let top = candidates.max(by: { $0.memory < $1.memory }), (muted["memory"] ?? .distantPast) < now {
            show(Hog(reason: .memory, app: top, since: since), key: "memory")
            return
        }
        let needed: TimeInterval = lowBattery ? 180 : 300
        let hot = candidates
            .filter { a in
                guard let since = hotSince[a.id] else { return false }
                return now.timeIntervalSince(since) >= needed && (muted[a.id] ?? .distantPast) < now
            }
            .max(by: { $0.energy < $1.energy })
        if let a = hot, let since = hotSince[a.id] {
            show(Hog(reason: lowBattery ? .battery : .cpu, app: a, since: since), key: a.id)
        }
    }

    /// Puts an alert up for 20 seconds. If the card is open when the time is up, it waits until the card closes.
    private func show(_ h: Hog, key: String) {
        hog = h
        muted[key] = Date().addingTimeInterval(2 * 3600)
        hogClear?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.hogViewed { self.hideWhenClosed = true } else { self.hog = nil }
            }
        }
        hogClear = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: item)
    }

    /// The island's card reports when it is open, so the alert never vanishes while you are reading it.
    func hogCard(open: Bool) {
        hogViewed = open
        if !open && hideWhenClosed { hideWhenClosed = false; hog = nil }
    }

    /// Ignore: say nothing more about this app for the rest of the working day (eight hours).
    func ignoreHog() {
        guard let h = hog else { return }
        muted[h.reason == .memory ? "memory" : h.app.id] = Date().addingTimeInterval(8 * 3600)
        hogClear?.cancel()
        hideWhenClosed = false
        hog = nil
    }

    /// The heaviest apps for the alert card, the hot one first.
    func offenders(for h: Hog, limit: Int = 3) -> [AppUsage] {
        let me = ProcessInfo.processInfo.processIdentifier
        let pool = apps.filter { !$0.system && $0.owner == nil && $0.pid != me && !Quit.protected($0) }
        let sorted = h.reason == .memory ? pool.sorted { $0.memory > $1.memory } : pool.sorted { $0.energy > $1.energy }
        var out = [apps.first(where: { $0.id == h.app.id }) ?? h.app]
        for a in sorted where a.id != h.app.id && out.count < limit { out.append(a) }
        return out
    }

    // MARK: Quitting

    func canQuit(_ a: AppUsage) -> Bool {
        !a.system && a.owner == nil && a.pid > 1 && a.pid != ProcessInfo.processInfo.processIdentifier && !Quit.protected(a)
    }

    /// Asks the app to quit, the same as choosing Quit from its menu, so it can save your work first.
    func quit(_ a: AppUsage) {
        guard canQuit(a) else { return }
        quitting[a.id] = Date()
        Quit.politely(a)
        objectWillChange.send()
        // Refresh soon so the row disappears promptly, and again when Force Quit becomes available.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.lastSample = .distantPast; self?.tick() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Quit.patience + 0.1) { [weak self] in self?.objectWillChange.send() }
    }

    func forceQuit(_ a: AppUsage) {
        guard canQuit(a) else { return }
        Quit.force(a)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.lastSample = .distantPast; self?.tick() }
    }

    /// True once the app has had a few seconds to quit and is still running.
    func stubborn(_ id: String) -> Bool {
        guard let t = quitting[id] else { return false }
        return Date().timeIntervalSince(t) >= Quit.patience
    }

    // MARK: Servers

    func stop(_ s: DevServer) {
        stopping[s.id] = Date()
        Ports.stop(s, force: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.refreshServers() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Quit.patience + 0.1) { [weak self] in self?.objectWillChange.send() }
    }

    func forceStop(_ s: DevServer) {
        Ports.stop(s, force: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refreshServers() }
    }

    func stubbornServer(_ id: String) -> Bool {
        guard let t = stopping[id] else { return false }
        return Date().timeIntervalSince(t) >= Quit.patience
    }

    func refreshServers() {
        guard Self.devMode else { servers = []; return }
        lastServers = Date()
        queue.async {
            let found = Ports.scan()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let m = Monitor.shared
                    m.servers = found
                    let live = Set(found.map(\.id))
                    for id in m.stopping.keys where !live.contains(id) { m.stopping[id] = nil }
                }
            }
        }
    }
}
