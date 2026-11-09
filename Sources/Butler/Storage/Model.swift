import SwiftUI

@MainActor
final class Model: ObservableObject {
    static let shared = Model()

    enum Phase: Equatable {
        case idle
        case scanning(String)
        case ready
        case cleaning(String)
        case done(freed: Int64, trashed: Int64)
    }

    enum Tab: Hashable { case storage, tasks, activity }

    @Published var tab: Tab = .storage
    @Published var phase: Phase = .idle
    @Published var spots: [Spot] = []
    @Published var selected: Set<String> = []
    @Published var progress: Double = 0
    @Published var free: Int64 = 0
    @Published var total: Int64 = 0
    @Published var grew: [(name: String, delta: Int64)] = []
    @Published var fullDiskAccess = true
    @Published var useTrash = true
    @Published var failures: [String] = []
    @Published var protectedCount = Protect.paths.count

    init() {
        refreshVolume()
        switch Debug.tab {
        case "tasks": tab = .tasks
        case "activity": tab = .activity
        default: break
        }
    }

    var selectedSpots: [Spot] { spots.filter { selected.contains($0.id) && $0.canClean } }
    // Totals use what cleaning really frees, never the larger on-disk number.
    var selectedBytes: Int64 { selectedSpots.reduce(0) { $0 + $1.frees } }
    var reclaimable: Int64 { spots.filter { $0.canClean }.reduce(0) { $0 + $1.frees } }
    var busy: Bool {
        switch phase { case .scanning, .cleaning: true; default: false }
    }

    func refreshVolume() {
        let v = Disk.volume()
        free = v.free; total = v.total
        fullDiskAccess = Disk.hasFullDiskAccess
    }

    func bucketTotal(_ b: Bucket) -> Int64 { spots.filter { $0.bucket == b }.reduce(0) { $0 + $1.frees } }

    func scan() {
        guard !busy else { return }
        refreshVolume()
        phase = .scanning("Looking around")
        progress = 0
        failures = []
        let previous = History.load()

        Task {
            // Project discovery and big-file discovery are independent, so run them side by side.
            async let projects = Task.detached { Catalog.devFolders() }.value
            async let big = Task.detached { Catalog.bigFiles() }.value
            var found = Catalog.known() + (await projects)
            let bigFiles = await big
            let count = found.count
            var done = 0

            await withTaskGroup(of: (Int, Scanner.Measure).self) { group in
                for (i, spot) in found.enumerated() {
                    group.addTask { (i, Scanner.measure(spot)) }
                }
                for await (i, m) in group {
                    found[i].size = m.onDisk
                    found[i].frees = m.frees
                    if found[i].shared > max(100_000_000, found[i].size / 10) {
                        found[i].note = found[i].id == "telegram"
                            ? "\(bytes(found[i].shared)) of this is shared with files you saved out of Telegram, such as movies in Downloads. Clearing Telegram's cache alone will not free that part while those copies exist."
                            : "\(bytes(found[i].shared)) of this is shared with copies elsewhere on this Mac, so cleaning frees \(bytes(found[i].frees))."
                    }
                    done += 1
                    progress = Double(done) / Double(max(count, 1))
                    phase = .scanning(found[i].name)
                }
            }

            var all = (found + bigFiles).filter { $0.size > 20_000_000 }
            Protect.apply(&all)
            all.sort { $0.frees > $1.frees }
            spots = all

            if let previous {
                grew = all.compactMap { s in
                    let before = previous.sizes[s.id] ?? 0
                    let delta = s.size - before
                    return (previous.sizes[s.id] != nil && delta > 500_000_000) ? (s.name, delta) : nil
                }.sorted { $0.delta > $1.delta }
            }
            History.save(all)

            // Pre-select only things that rebuild and actually free something.
            selected = Set(all.filter { $0.canClean && $0.bucket != .yours && $0.frees > 1_000_000 }.map { $0.id })
            refreshVolume()
            phase = .ready
        }
    }

    func clean() {
        guard !busy else { return }
        let chosen = selectedSpots
        guard !chosen.isEmpty else { return }
        let before = free
        let trash = useTrash
        phase = .cleaning("Starting")
        progress = 0

        Task {
            let report = await Task.detached { [weak self] () -> CleanReport in
                Cleaner.run(chosen, useTrash: trash) { p, name in
                    Task { @MainActor in
                        self?.progress = p
                        self?.phase = .cleaning(name)
                    }
                }
            }.value
            failures = report.failures
            try? await Task.sleep(nanoseconds: 600_000_000)
            refreshVolume()
            let freed = max(free - before, 0)
            phase = .done(freed: freed, trashed: report.trashed)

            try? await Task.sleep(nanoseconds: 4_500_000_000)
            if case .done = phase { scan() }
        }
    }

    func emptyTrash() {
        let script = NSAppleScript(source: "tell application \"Finder\" to empty trash")
        var err: NSDictionary?
        script?.executeAndReturnError(&err)
        refreshVolume()
    }

    /// Locks this spot's folder (or file) now and on every later scan.
    func protect(_ spot: Spot) {
        guard let r = spot.root ?? spot.paths.first else { return }
        Protect.add(r)
        relock()
    }

    func unprotect(_ path: String) {
        Protect.remove(path)
        relock()
    }

    func addProtected(_ url: URL) {
        Protect.add(url)
        relock()
    }

    /// Applies the protected list to the current results without a rescan.
    private func relock() {
        for i in spots.indices {
            if spots[i].lockedReason == "On your protected list" || spots[i].lockedReason == "Holds a protected folder" {
                spots[i].lockedReason = nil
            }
            if let why = Protect.lock(spots[i]) { spots[i].lockedReason = why; selected.remove(spots[i].id) }
        }
        protectedCount = Protect.paths.count
    }

    func toggle(_ spot: Spot) {
        guard spot.canClean else { return }
        if selected.contains(spot.id) { selected.remove(spot.id) } else { selected.insert(spot.id) }
    }
}
