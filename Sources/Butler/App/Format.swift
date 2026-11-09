import Foundation

func bytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

/// RAM in the units macOS uses for it: 16 GB of memory, not 17.18.
func memory(_ n: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .memory
    return f.string(fromByteCount: n)
}

func percent(_ v: Double) -> String { v >= 10 ? "\(Int(v.rounded()))%" : String(format: "%.1f%%", v) }
