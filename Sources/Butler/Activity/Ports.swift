import AppKit
import Darwin

/// Finds servers listening on ports and works out which project each one belongs to.
enum Ports {
    /// Programs that serve things during development. A listener that is one of these, or that was started from a
    /// project folder, is shown; apps and macOS services listening for their own reasons (AirPlay, Spotify) are not.
    static let runtimes: Set<String> = [
        "node", "bun", "deno", "python", "python3", "ruby", "php", "java", "go", "dotnet", "postgres", "redis-server",
        "mysqld", "mongod", "nginx", "caddy", "httpd", "uvicorn", "gunicorn", "beam.smp", "rails", "puma", "hugo",
        "air", "cargo", "esbuild", "vite", "next-server", "supabase", "kong", "temporal", "minio",
    ]
    static let containers: [String: String] = [
        "gvproxy": "Podman", "podman": "Podman", "krunkit": "Podman", "vfkit": "Podman",
        "com.docker.backend": "Docker", "com.docker.vpnkit": "Docker", "vpnkit-bridge": "Docker", "docker-proxy": "Docker",
        "OrbStack Helper": "OrbStack", "limactl": "Lima", "colima": "Colima",
    ]

    static func scan() -> [DevServer] {
        guard let out = run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"]) else { return [] }
        var ports: [pid_t: [(Int, Bool)]] = [:]
        var pid: pid_t = 0
        for line in out.split(separator: "\n") {
            guard let k = line.first else { continue }
            let v = line.dropFirst()
            if k == "p" { pid = pid_t(v) ?? 0 }
            else if k == "n", pid > 0, let colon = v.lastIndex(of: ":"), let port = Int(v[v.index(after: colon)...]) {
                let host = v[..<colon]
                let network = host == "*" || host == "[::]" || host == "0.0.0.0"
                if let i = ports[pid]?.firstIndex(where: { $0.0 == port }) { ports[pid]![i].1 = ports[pid]![i].1 || network }
                else { ports[pid, default: []].append((port, network)) }
            }
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var labels: [pid_t: String]?
        var found: [DevServer] = []

        for (pid, list) in ports where pid != me {
            guard let path = Sampler.path(pid) else { continue }
            let exe = (path as NSString).lastPathComponent
            let bsd = bsdInfo(pid)
            let folder = cwd(pid) ?? "/"
            let args = arguments(pid)

            var kind = DevServer.Kind.process
            var list = list
            if let c = containers[exe] {
                // The machine itself and its private SSH port are plumbing; only the forwarded container ports matter.
                if exe == "vfkit" || exe == "krunkit" { continue }
                if let i = args.firstIndex(of: "-ssh-port"), i + 1 < args.count, let ssh = Int(args[i + 1]) {
                    list.removeAll { $0.0 == ssh }
                }
                kind = .container(c)
            } else {
                // A dev tool, or anything started from a terminal inside a project folder. Helpers that apps and code
                // editors start in the background have no terminal, so they stay out of the list.
                let fromProject = folder != "/" && !["/Applications", "/System", "/Library", home + "/Library"].contains { folder.hasPrefix($0) }
                let e = exe.lowercased()
                let isRuntime = runtimes.contains(e) || e.hasPrefix("python") || e.hasPrefix("ruby") || e.hasPrefix("node")
                // Apple's own Python runs from inside a Python.app; any other program inside an app belongs to that app.
                guard (fromProject && (bsd?.terminal ?? false)) || isRuntime, isRuntime || !path.contains(".app/") else { continue }
                if bsd?.ppid == 1 {
                    if labels == nil { labels = launchdLabels() }
                    if let l = labels?[pid] { kind = .service(l) }
                }
            }
            let tool = describe(exe: exe.hasPrefix("Python") ? "python3" : exe, args: args)
            for (port, network) in list {
                found.append(DevServer(pid: pid, port: port, network: network, tool: tool, folder: folder, started: bsd?.started, kind: kind))
            }
        }
        // Your own servers first, by port; containers and services after.
        func rank(_ k: DevServer.Kind) -> Int { switch k { case .process: 0; case .service: 1; case .container: 2 } }
        return found.sorted { (rank($0.kind), $0.port) < (rank($1.kind), $1.port) }
    }

    /// "next", "vite", "python manage.py" rather than just "node".
    static func describe(exe: String, args: [String]) -> String {
        let rest = args.dropFirst()
        if exe.hasPrefix("python"), let i = rest.firstIndex(of: "-m"), rest.index(after: i) < rest.endIndex {
            return rest[rest.index(after: i)]
        }
        guard let script = rest.first(where: { !$0.hasPrefix("-") }) else { return exe }
        if let r = script.range(of: "node_modules/", options: .backwards) {
            let parts = script[r.upperBound...].split(separator: "/")
            if let first = parts.first {
                if first.hasPrefix("@"), parts.count > 1 { return "\(first)/\(parts[1])" }
                return first == ".bin" && parts.count > 1 ? String(parts[1]) : String(first)
            }
        }
        let name = (script as NSString).lastPathComponent
        return ["node", "bun", "deno"].contains(exe) || exe.hasPrefix("python") || exe.hasPrefix("ruby") ? "\(exe) \(name)" : exe
    }

    static func stop(_ s: DevServer, force: Bool) {
        switch s.kind {
        case .container: return
        case .service(let label):
            // Killing a kept-alive service only makes launchd start it again. Unloading it stops it until next login.
            _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        case .process:
            guard s.pid > 1, s.pid != ProcessInfo.processInfo.processIdentifier else { return }
            kill(s.pid, force ? SIGKILL : SIGTERM)
        }
    }

    // MARK: Process details

    static func cwd(_ pid: pid_t) -> String? {
        var vpi = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, size) == size else { return nil }
        return withUnsafeBytes(of: &vpi.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    static func bsdInfo(_ pid: pid_t) -> (ppid: pid_t, started: Date, terminal: Bool)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let start = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6)
        let controllingTerminal: UInt32 = 0x2   // PROC_FLAG_CONTROLT
        return (pid_t(info.pbi_ppid), start, info.pbi_flags & controllingTerminal != 0)
    }

    static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = buf.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }   // the program's path
        while i < size && buf[i] == 0 { i += 1 }
        var out: [String] = []
        while out.count < argc && i < size {
            let s = i
            while i < size && buf[i] != 0 { i += 1 }
            out.append(String(decoding: buf[s..<i], as: UTF8.self))
            i += 1
        }
        return out
    }

    static func launchdLabels() -> [pid_t: String] {
        guard let out = run("/bin/launchctl", ["list"]) else { return [:] }
        var map: [pid_t: String] = [:]
        for line in out.split(separator: "\n").dropFirst() {
            let f = line.split(separator: "\t")
            if f.count >= 3, let pid = pid_t(f[0]) { map[pid] = String(f[2]) }
        }
        return map
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
