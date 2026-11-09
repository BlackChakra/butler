import Foundation
import AppKit

enum Disk {
    /// Real free space, the same number `df` reports.
    static func volume() -> (free: Int64, total: Int64) {
        let v = try? URL(fileURLWithPath: "/System/Volumes/Data")
            .resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
        return (Int64(v?.volumeAvailableCapacity ?? 0), Int64(v?.volumeTotalCapacity ?? 0))
    }

    static var hasFullDiskAccess: Bool {
        let probe = Catalog.lib("Safari")
        return (try? FileManager.default.contentsOfDirectory(atPath: probe.path)) != nil
    }
}

enum Scanner {
    struct Measure { var onDisk: Int64 = 0; var frees: Int64 = 0; var sizes: [Int64] = [] }

    /// Measures a spot two ways, strictly:
    /// - on disk: blocks allocated, each file counted once (a hard-linked file has several names but one set of blocks);
    /// - frees: what deleting the spot actually gives back. Blocks shared with an APFS clone outside the spot stay on
    ///   disk, and a hard-linked file is only freed when every one of its names goes. Both are left out.
    /// When unsure, it counts less, never more: Butler must not promise space that will not come back.
    static func measure(_ spot: Spot, keepSizes: Bool = false) -> Measure {
        let cutoff: Date? = {
            if case .permanentOlderThan(let d) = spot.policy {
                return Calendar.current.date(byAdding: .day, value: -d, to: Date())
            }
            return nil
        }()
        var m = Measure()
        var seen: [UInt64: (count: Int, links: Int, priv: Int64)] = [:]

        func visit(_ path: String, _ st: stat) {
            guard (st.st_mode & S_IFMT) == S_IFREG else { return }
            if let filter = spot.filter, !filter(URL(fileURLWithPath: path)) { return }
            if let cutoff {
                let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                if mtime > cutoff { return }
            }
            let ino = UInt64(st.st_ino)
            if var e = seen[ino] { e.count += 1; seen[ino] = e; return }
            m.onDisk += Int64(st.st_blocks) * 512
            if keepSizes { m.sizes.append(Int64(st.st_size)) }
            seen[ino] = (1, Int(st.st_nlink), privateSize(path))
        }

        for root in spot.paths {
            var st = stat()
            guard lstat(root.path, &st) == 0 else { continue }
            if (st.st_mode & S_IFMT) != S_IFDIR { visit(root.path, st); continue }
            guard let en = FileManager.default.enumerator(atPath: root.path) else { continue }
            while let rel = en.nextObject() as? String {
                let path = root.path + "/" + rel
                guard lstat(path, &st) == 0 else { continue }
                visit(path, st)
            }
        }
        for e in seen.values where e.count >= e.links { m.frees += e.priv }
        return m
    }

    static func size(of spot: Spot) -> Int64 { measure(spot).frees }

    /// The part of a file that is its own on disk. APFS clones share their blocks with the original, so deleting a
    /// clone frees only what was changed after cloning. Finder still shows the full size, which is how 45 Chrome copies
    /// can read as 68 GB while holding 16 MB.
    static func privateSize(_ path: String) -> Int64 {
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        attrs.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        var buf = [UInt8](repeating: 0, count: 64)
        guard getattrlist(path, &attrs, &buf, buf.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)) == 0 else { return 0 }
        // Layout: total length (4 bytes), the returned-attributes set (5 × 4 bytes), then the private size.
        return buf.withUnsafeBytes { $0.load(fromByteOffset: 24, as: Int64.self) }
    }
}
