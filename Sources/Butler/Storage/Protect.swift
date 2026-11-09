import Foundation

/// Folders and files the person has protected. Nothing inside them is ever offered for cleaning.
/// Stored per Mac, so every copy of Butler starts with an empty list and each person picks their own.
enum Protect {
    private static let key = "protectedFolders"

    static var paths: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(Array(Set(newValue)).sorted(), forKey: key) }
    }

    static func add(_ url: URL) { paths = paths + [url.standardizedFileURL.resolvingSymlinksInPath().path] }
    static func remove(_ path: String) { paths = paths.filter { $0 != path } }

    /// True when the path is a protected folder or file, or anywhere inside one. Exact locations, not names, so a
    /// project called "web" never locks every folder with "web" in its name.
    static func covers(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        return paths.contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    /// The protected folder that locks this spot, if any. Also catches a spot whose folder holds a protected one.
    static func lock(_ spot: Spot) -> String? {
        let all = spot.paths + (spot.root.map { [$0] } ?? [])
        for u in all where covers(u) { return "On your protected list" }
        if let r = spot.root?.standardizedFileURL.path, paths.contains(where: { $0.hasPrefix(r + "/") }) {
            return "Holds a protected folder"
        }
        return nil
    }

    static func apply(_ spots: inout [Spot]) {
        for i in spots.indices {
            if let why = lock(spots[i]) { spots[i].lockedReason = why }
        }
    }
}
