import Foundation

/// `Butler --dump` runs the same scan without a window and prints what it found. Used for testing.
enum Dump {
    static func run() {
        var spots = Catalog.known() + Catalog.devFolders()
        for i in spots.indices { let m = Scanner.measure(spots[i]); spots[i].size = m.onDisk; spots[i].frees = m.frees }
        spots += Catalog.bigFiles()
        Protect.apply(&spots)
        let v = Disk.volume()
        print("free \(bytes(v.free)) of \(bytes(v.total)) · full disk access: \(Disk.hasFullDiskAccess)")
        for s in spots.filter({ $0.size > 20_000_000 || $0.id == "chrome-clones" }).sorted(by: { $0.frees > $1.frees }) {
            let state = s.lockedReason.map { "locked: \($0)" } ?? (s.canClean ? (s.permanentByNature ? "delete" : "trash") : "explain")
            print(String(format: "%-11@ frees %10@  on disk %10@  %@  [%@]", s.bucket.title as NSString, bytes(s.frees) as NSString,
                         bytes(s.size) as NSString, s.name as NSString, state as NSString))
            if let n = s.note { print("            note: \(n)") }
        }
    }
}
