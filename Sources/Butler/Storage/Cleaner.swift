import Foundation
import AppKit

struct CleanReport {
    var deleted: Int64 = 0
    var trashed: Int64 = 0
    var failures: [String] = []
}

enum Cleaner {
    static func run(_ spots: [Spot], useTrash: Bool, progress: (Double, String) -> Void) -> CleanReport {
        var report = CleanReport()
        let fm = FileManager.default
        for (i, spot) in spots.enumerated() {
            progress(Double(i) / Double(max(spots.count, 1)), spot.name)
            guard spot.canClean else { continue }
            if let id = spot.quitBundleID { quit(id) }

            switch spot.policy {
            case .explain: continue
            case .trash:
                for p in spot.paths where fm.fileExists(atPath: p.path) {
                    do {
                        if useTrash { try fm.trashItem(at: p, resultingItemURL: nil) }
                        else { try fm.removeItem(at: p) }
                    } catch { report.failures.append("\(spot.name): \(error.localizedDescription)") }
                }
                if useTrash { report.trashed += spot.frees } else { report.deleted += spot.frees }
            case .permanent:
                for p in spot.paths where fm.fileExists(atPath: p.path) {
                    do { try fm.removeItem(at: p) }
                    catch { report.failures.append("\(spot.name): \(error.localizedDescription)") }
                }
                report.deleted += spot.frees
            case .permanentOlderThan(let days):
                guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { continue }
                for root in spot.paths {
                    guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]) else { continue }
                    for case let url as URL in en {
                        guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                              v.isRegularFile == true, let m = v.contentModificationDate, m < cutoff else { continue }
                        if let filter = spot.filter, !filter(url) { continue }
                        try? fm.removeItem(at: url)
                    }
                }
                report.deleted += spot.frees
            }
        }
        progress(1, "")
        return report
    }

    private static func quit(_ bundleID: String) {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        apps.forEach { $0.terminate() }
        for _ in 0..<20 where apps.contains(where: { !$0.isTerminated }) { Thread.sleep(forTimeInterval: 0.25) }
    }
}

/// Remembers sizes from the last scan so the app can say what grew.
enum History {
    private static var file: URL {
        let fm = FileManager.default
        let dir = Catalog.lib("Application Support/Butler")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("history.json")
        let old = Catalog.lib("Application Support/Tidy/history.json")   // earlier name of the app
        if !fm.fileExists(atPath: dest.path), fm.fileExists(atPath: old.path) { try? fm.copyItem(at: old, to: dest) }
        return dest
    }
    struct Snapshot: Codable { var date: Date; var sizes: [String: Int64]; var names: [String: String] }

    static func load() -> Snapshot? {
        guard let d = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: d)
    }
    static func save(_ spots: [Spot]) {
        let snap = Snapshot(date: Date(),
                            sizes: Dictionary(spots.map { ($0.id, $0.size) }, uniquingKeysWith: { a, _ in a }),
                            names: Dictionary(spots.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
        if let d = try? JSONEncoder().encode(snap) { try? d.write(to: file) }
    }
}

enum Running {
    /// Folders that a running process of yours is working in, so a live dev server is never cleaned from under itself.
    static func workingDirectories() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-d", "cwd", "-Fn", "-u", NSUserName()]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").filter { $0.hasPrefix("n/") }.map { String($0.dropFirst()) }
    }
}
