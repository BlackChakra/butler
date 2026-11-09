import AppKit
import Darwin
import IOKit
import IOKit.ps

/// Reads every process's counters and turns two readings into rates. Lives on the monitor's own queue.
final class Sampler: @unchecked Sendable {
    struct Result {
        var apps: [AppUsage]
        var cpu: Double
        var memoryUsed: Int64
        var pressure: Int
        var gpu: Double
        var battery: Monitor.Battery?
    }

    private struct Prev { var cpu: UInt64; var wake: UInt64; var start: UInt64 }
    private struct Info { var path: String; var group: String; var name: String; var iconPath: String; var bundle: String?; var owner: String? }

    /// Every background process of macOS shares one row, so your own apps are not buried under dozens of daemons.
    static let macOS = "macos"
    /// Programs that run Podman or Docker's virtual machine. Quitting them would pull the machine out from under
    /// its containers, so they are shown under their owner and stopped from there.
    static let owners: [String: String] = [
        "vfkit": "Podman", "krunkit": "Podman", "gvproxy": "Podman", "podman": "Podman", "qemu-system-aarch64": "Podman",
        "com.docker.backend": "Docker", "com.docker.vpnkit": "Docker", "com.docker.virtualization": "Docker",
        "limactl": "Lima", "colima": "Colima",
    ]

    private var prev: [pid_t: Prev] = [:]
    private var prevGPU: [pid_t: UInt64] = [:]
    private var prevTicks: (busy: UInt64, total: UInt64)?
    private var prevDate: Date?
    private var infos: [pid_t: (start: UInt64, info: Info)] = [:]
    private var bundleApps: [String: (pid: pid_t, isApp: Bool)] = [:]
    private let timebase: Double = {
        var tb = mach_timebase_info(); mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()
    private let me = ProcessInfo.processInfo.processIdentifier

    private typealias RespFn = @convention(c) (pid_t) -> pid_t
    private let responsible: RespFn? = {
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(p, to: RespFn.self)
    }()

    func sample() -> Result {
        let now = Date()
        let dt = prevDate.map { now.timeIntervalSince($0) } ?? 0
        prevDate = now

        let pids = Self.allPids()
        let gpuNow = Self.gpuTimes()
        var groups: [String: AppUsage] = [:]
        var nextPrev: [pid_t: Prev] = [:]
        bundleApps = [:]
        let running = NSWorkspace.shared.runningApplications

        for pid in pids where pid > 0 {
            guard let r = Self.rusage(pid) else { continue }
            let cpuTime = r.ri_user_time + r.ri_system_time
            let wake = r.ri_pkg_idle_wkups + r.ri_interrupt_wkups
            nextPrev[pid] = Prev(cpu: cpuTime, wake: wake, start: r.ri_proc_start_abstime)
            guard let info = info(pid, start: r.ri_proc_start_abstime) else { continue }

            var cpu = 0.0, wakes = 0.0, gpu = 0.0
            if dt > 0, let p = prev[pid], p.start == r.ri_proc_start_abstime {
                cpu = Double(cpuTime &- p.cpu) * timebase / (dt * 1e9) * 100
                wakes = Double(wake &- p.wake) / dt
                if cpuTime < p.cpu { cpu = 0 }
                if wake < p.wake { wakes = 0 }
            }
            if dt > 0, let g = gpuNow[pid], let pg = prevGPU[pid], g >= pg {
                gpu = min(Double(g - pg) / (dt * 1e9) * 100, 100)
            }

            var a = groups[info.group] ?? AppUsage(id: info.group, name: info.name, pid: pid, iconPath: info.iconPath, processes: 0)
            a.owner = a.owner ?? info.owner
            a.processes += 1
            a.cpu += cpu
            a.memory += Int64(r.ri_phys_footprint)
            a.gpu = min(a.gpu + gpu, 100)
            a.wakeups += wakes
            if let b = info.bundle {
                if let found = bundleApps[b] ?? appFor(bundle: b, running) { bundleApps[b] = found; a.pid = found.pid; a.isApp = found.isApp }
                else if info.path.hasPrefix(b + "/Contents/MacOS/") { a.pid = pid }   // its main program
            }
            if !a.isApp { a.system = info.owner == nil && Self.isSystem(info.bundle ?? info.path) }
            if a.system {
                // Fold into the one macOS row.
                var m = groups[Self.macOS] ?? AppUsage(id: Self.macOS, name: "macOS", pid: 0, iconPath: Self.macOS, processes: 0, system: true)
                m.processes += a.processes; m.cpu += a.cpu; m.memory += a.memory; m.gpu = min(m.gpu + a.gpu, 100); m.wakeups += a.wakeups
                groups[Self.macOS] = m
                groups[info.group] = nil
                continue
            }
            groups[info.group] = a
        }
        prev = nextPrev
        prevGPU = gpuNow
        infos = infos.filter { nextPrev[$0.key] != nil }

        let ticks = Self.cpuTicks()
        var cpu = 0.0
        if let p = prevTicks, ticks.total > p.total { cpu = Double(ticks.busy - p.busy) / Double(ticks.total - p.total) * 100 }
        prevTicks = ticks

        let apps = groups.values.filter { $0.memory > 0 || $0.cpu > 0 }.sorted { $0.energy > $1.energy }
        let (used, pressure) = Self.memory()
        return Result(apps: dt > 0 ? apps : apps.map { var a = $0; a.cpu = 0; return a },
                      cpu: cpu, memoryUsed: used, pressure: pressure, gpu: Self.gpuUtilisation() ?? 0, battery: Self.battery())
    }

    // MARK: Who a process belongs to

    private func info(_ pid: pid_t, start: UInt64) -> Info? {
        if let c = infos[pid], c.start == start { return c.info }
        guard let path = Self.path(pid) else { return nil }
        var bundle = Self.outerApp(path)
        var owner = Self.owners[(path as NSString).lastPathComponent]
        var group = "pid:\(pid)", name = (path as NSString).lastPathComponent, iconPath = path
        // An XPC service belongs to whoever started it: Safari's web pages to Safari, Podman's virtual machine to Podman.
        if bundle == nil, path.contains(".xpc/"), let rf = responsible {
            let rp = rf(pid)
            if rp > 0, rp != pid, let rpath = Self.path(rp) {
                bundle = Self.outerApp(rpath)
                if bundle == nil, !Self.isSystem(rpath) {
                    group = "pid:\(rp)"; name = (rpath as NSString).lastPathComponent; iconPath = rpath
                    owner = owner ?? Self.owners[name]
                }
            }
        }
        if let o = owner { group = "owner:\(o)"; name = "\(o) machine" }
        let info: Info
        if let b = bundle, owner == nil {
            let name = (FileManager.default.displayName(atPath: b) as NSString).deletingPathExtension
            info = Info(path: path, group: b, name: name, iconPath: b, bundle: b, owner: nil)
        } else {
            info = Info(path: path, group: group, name: name, iconPath: iconPath, bundle: nil, owner: owner)
        }
        infos[pid] = (start, info)
        return info
    }

    private func appFor(bundle: String, _ running: [NSRunningApplication]) -> (pid: pid_t, isApp: Bool)? {
        guard let app = running.first(where: { $0.bundleURL?.path == bundle }) else { return nil }
        // A Dock app, or a menu bar app you installed. Background pieces of macOS that happen to be bundles are not.
        let isApp = app.activationPolicy == .regular || (app.activationPolicy == .accessory && !Self.isSystem(bundle))
        return (app.processIdentifier, isApp)
    }

    static func outerApp(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    static func isSystem(_ path: String) -> Bool {
        ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/private/var/", "/Library/Developer/CommandLineTools/"]
            .contains { path.hasPrefix($0) }
    }

    // MARK: Low-level readings

    static func allPids() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(got, 0))))
    }

    static func rusage(_ pid: pid_t) -> rusage_info_v6? {
        var r = rusage_info_v6()
        let ok = withUnsafeMutablePointer(to: &r) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        return ok == 0 ? r : nil
    }

    static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    static func cpuTicks() -> (busy: UInt64, total: UInt64) {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return (0, 0) }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        var busy: UInt64 = 0, total: UInt64 = 0
        for c in 0..<Int(count) {
            let base = c * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let sys = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            busy += user + sys + nice
            total += user + sys + nice + idle
        }
        return (busy, total)
    }

    /// Memory used the way Activity Monitor counts it (app memory + wired + compressed), and macOS's pressure level.
    static func memory() -> (Int64, Int) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        var used: Int64 = 0
        if ok == KERN_SUCCESS {
            let page = Int64(vm_kernel_page_size)
            let app = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
            used = (app + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page
        }
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return (used, Int(level))
    }

    /// How busy the GPU is overall, from the graphics driver's own statistics.
    static func gpuUtilisation() -> Double? {
        var best: Double?
        forEachAccelerator { acc in
            if let stats = IORegistryEntryCreateCFProperty(acc, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let u = stats["Device Utilization %"] as? NSNumber {
                best = max(best ?? 0, u.doubleValue)
            }
        }
        return best
    }

    /// Total GPU time each process has used so far, in nanoseconds. The driver keeps this per app; macOS has no public
    /// call for it. On Macs whose driver does not publish it, every app simply shows no GPU use.
    static func gpuTimes() -> [pid_t: UInt64] {
        var out: [pid_t: UInt64] = [:]
        forEachAccelerator { acc in
            var it: io_iterator_t = 0
            guard IORegistryEntryCreateIterator(acc, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &it) == KERN_SUCCESS else { return }
            defer { IOObjectRelease(it) }
            var c = IOIteratorNext(it)
            while c != 0 {
                if let creator = IORegistryEntryCreateCFProperty(c, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String,
                   let usage = IORegistryEntryCreateCFProperty(c, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [[String: Any]],
                   creator.hasPrefix("pid "), let pid = pid_t(creator.dropFirst(4).prefix(while: \.isNumber)) {
                    let t = usage.reduce(UInt64(0)) { $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
                    out[pid, default: 0] += t
                }
                IOObjectRelease(c)
                c = IOIteratorNext(it)
            }
        }
        return out
    }

    private static func forEachAccelerator(_ body: (io_object_t) -> Void) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        var acc = IOIteratorNext(it)
        while acc != 0 {
            body(acc)
            IOObjectRelease(acc)
            acc = IOIteratorNext(it)
        }
    }

    static func battery() -> Monitor.Battery? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let onBattery = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            let left = d[kIOPSTimeToEmptyKey] as? Int
            return .init(level: max > 0 ? cur * 100 / max : cur, onBattery: onBattery,
                         charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                         minutesLeft: onBattery && (left ?? -1) > 0 ? left : nil)
        }
        return nil
    }
}
