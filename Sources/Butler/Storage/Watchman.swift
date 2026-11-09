import SwiftUI
import AppKit

/// Works in the background: warns at the notch when space runs low or drops fast, and runs the weekly tidy.
/// Everything it shows appears on the left of the notch; the right side belongs to the shelf and Now Playing.
@MainActor
final class Watchman: ObservableObject {
    static let shared = Watchman()

    enum Alert: Equatable {
        case low(Int64)        // free space under the limit
        case critical(Int64)   // under half the limit
        case drop(Int64)       // this much disappeared in the last ten minutes
        case tidied(Int64)     // the weekly tidy freed this much
    }

    @Published private(set) var alert: Alert?
    @Published private(set) var lastTidy: Date?

    /// Only caches that rebuild themselves and cost little to rebuild. The pnpm store and Playwright browsers are left
    /// out on purpose: they re-download hundreds of megabytes, which is not worth doing every week.
    static let tidyIDs: Set<String> = ["notif-attachments", "messages-tmp", "npm", "brew"]

    private var samples: [(date: Date, free: Int64)] = []
    private var lastLowWarning = Date.distantPast
    private var lastLowFree = Int64.max
    private var lastDropWarning = Date.distantPast
    private var clear: DispatchWorkItem?
    private var timers: [Timer] = []
    private var tidying = false

    static var warningsOn: Bool { UserDefaults.standard.object(forKey: "lowSpaceWarnings") as? Bool ?? true }
    static var tidyOn: Bool { UserDefaults.standard.object(forKey: "weeklyTidy") as? Bool ?? true }
    /// Warn below this many gigabytes.
    static var limit: Int64 { Int64(UserDefaults.standard.object(forKey: "lowSpaceGB") as? Int ?? 20) * 1_000_000_000 }

    init() {
        lastTidy = UserDefaults.standard.object(forKey: "lastTidy") as? Date
        if lastTidy == nil {
            // First run: the first tidy happens a day from now rather than straight away.
            let first = Date().addingTimeInterval(-6 * 86_400)
            UserDefaults.standard.set(first, forKey: "lastTidy")
            lastTidy = first
        }
    }

    func start() {
        guard timers.isEmpty else { return }
        timers.append(.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        })
        timers.append(.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tidyIfDue() }
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.check() }
        if Debug.alert == "low" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.show(.low(12_400_000_000), for: 600) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in self?.tidyIfDue() }
    }

    // MARK: Low space

    func check() {
        guard Self.warningsOn else { return }
        let now = Date()
        let free = Disk.volume().free
        guard free > 0 else { return }
        samples.append((now, free))
        samples.removeAll { now.timeIntervalSince($0.date) > 900 }

        // Something is eating space fast: 5 GB or more gone within ten minutes.
        if let first = samples.first(where: { now.timeIntervalSince($0.date) <= 600 }),
           first.free - free >= 5_000_000_000, now.timeIntervalSince(lastDropWarning) > 600 {
            lastDropWarning = now
            show(.drop(first.free - free), for: 10)
            return
        }

        let limit = Self.limit
        if free < limit {
            // Warn when crossing the limit, then again every two hours or after another 5 GB is gone.
            if now.timeIntervalSince(lastLowWarning) > 7200 || free < lastLowFree - 5_000_000_000 {
                lastLowWarning = now
                lastLowFree = free
                show(free < limit / 2 ? .critical(free) : .low(free), for: 12)
            }
        } else if free > limit + 2_000_000_000 {
            lastLowWarning = .distantPast   // recovered: warn straight away next time
            lastLowFree = .max
        }
    }

    private func show(_ a: Alert, for seconds: Double) {
        alert = a
        clear?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.alert = nil } }
        clear = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func dismiss() { clear?.cancel(); alert = nil }

    // MARK: Weekly tidy

    func tidyIfDue(force: Bool = false) {
        guard force || Self.tidyOn, !tidying, !Model.shared.busy else { return }
        if !force, let last = lastTidy, Date().timeIntervalSince(last) < 7 * 86_400 { return }
        tidying = true

        // Never quit an app on its own: anything that needs an app closed is skipped while that app is open.
        let spots = Catalog.known().filter { spot in
            guard Self.tidyIDs.contains(spot.id), spot.canClean else { return false }
            if let id = spot.quitBundleID, !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty { return false }
            return true
        }
        let before = Disk.volume().free
        Task {
            let deleted = await Task.detached { () -> Int64 in
                let sized = spots.compactMap { s -> Spot? in
                    guard Protect.lock(s) == nil else { return nil }   // never tidy inside a protected folder
                    var s = s; let m = Scanner.measure(s); s.size = m.onDisk; s.frees = m.frees; return s
                }
                return Cleaner.run(sized, useTrash: false) { _, _ in }.deleted
            }.value
            try? await Task.sleep(nanoseconds: 500_000_000)
            let measured = max(Disk.volume().free - before, 0)
            let now = Date()
            UserDefaults.standard.set(now, forKey: "lastTidy")
            lastTidy = now
            tidying = false
            Model.shared.refreshVolume()
            // The measured gain is honest; the listed size is the fallback when other activity hides it.
            let freed = measured > 0 ? measured : deleted
            if freed > 10_000_000 { show(.tidied(freed), for: 8) }
        }
    }
}
