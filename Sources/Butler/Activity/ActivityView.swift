import SwiftUI
import AppKit

/// The Activity tab: what the Mac is busy with, which apps are behind it, and a way to quit them.
/// With developer mode on, also the servers running on localhost.
struct ActivityView: View {
    @ObservedObject var monitor: Monitor
    @AppStorage("hogAlerts") private var hogAlerts = true
    @AppStorage("devMode") private var devMode = false
    @State private var sort: Sort = .cpu
    @State private var showAll = false

    /// How many apps show before "Show all". `Debug.rows` overrides it.
    static let rows = Debug.rows ?? 12

    enum Sort: String, CaseIterable { case cpu = "CPU", memory = "Memory", gpu = "GPU", energy = "Energy" }

    private var sorted: [AppUsage] {
        switch sort {
        case .cpu: monitor.apps.sorted { $0.cpu > $1.cpu }
        case .memory: monitor.apps.sorted { $0.memory > $1.memory }
        case .gpu: monitor.apps.sorted { ($0.gpu, $0.cpu) > ($1.gpu, $1.cpu) }
        case .energy: monitor.apps.sorted { $0.energy > $1.energy }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            gauges
                .padding(.horizontal, 36).padding(.top, 52).padding(.bottom, 22)

            Divider().opacity(0.5)
            columns.padding(.horizontal, 40).padding(.top, 14).padding(.bottom, 4)

            if !monitor.loaded {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        appsSection
                        if devMode { ServersSection(monitor: monitor) }
                    }
                    .padding(.horizontal, 36).padding(.top, 4).padding(.bottom, 22)
                }
            }

            Divider().opacity(0.5)
            footer.padding(.horizontal, 36).padding(.vertical, 14)
        }
        .onAppear { monitor.watch(true) }
        .onDisappear { monitor.watch(false) }
        .onChange(of: devMode) { _, on in if on { monitor.refreshServers() } }
    }

    // MARK: Gauges

    private var gauges: some View {
        HStack(spacing: 14) {
            Gauge(title: "CPU", value: "\(Int(monitor.cpu.rounded()))%",
                  detail: "\(monitor.cores) cores", history: monitor.history.cpu, ceiling: 100, tint: .blue)
            Gauge(title: "Memory", value: memory(monitor.memoryUsed),
                  detail: "of \(memory(monitor.memoryTotal)) · \(pressureText)",
                  history: monitor.history.memory, ceiling: 100, tint: pressureTint)
            Gauge(title: "GPU", value: "\(Int(monitor.gpu.rounded()))%",
                  detail: gpuDetail, history: monitor.history.gpu, ceiling: 100, tint: .purple)
            if let b = monitor.battery {
                Gauge(title: "Battery", value: "\(b.level)%", detail: batteryText(b),
                      history: monitor.history.energy, ceiling: nil, tint: b.onBattery && b.level <= 20 ? .red : .green)
            } else {
                Gauge(title: "Energy", value: "\(Int(monitor.history.energy.last ?? 0))", detail: "all apps",
                      history: monitor.history.energy, ceiling: nil, tint: .green)
            }
        }
    }

    private var pressureText: String {
        switch monitor.pressure { case 4: "pressure high"; case 2: "pressure rising"; default: "no pressure" }
    }
    private var pressureTint: Color {
        switch monitor.pressure { case 4: .red; case 2: .orange; default: .teal }
    }
    private var gpuDetail: String {
        guard let top = monitor.apps.max(by: { $0.gpu < $1.gpu }), top.gpu >= 1 else { return "idle" }
        return "mostly \(top.name)"
    }
    private func batteryText(_ b: Monitor.Battery) -> String {
        if b.charging { return "charging" }
        if !b.onBattery { return "on power" }
        if let m = b.minutesLeft { return "\(m / 60):" + String(format: "%02d", m % 60) + " left" }
        return "on battery"
    }

    // MARK: Apps

    /// Column titles stay put above the list. Click one to sort by it.
    private var columns: some View {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("Apps").font(.system(size: 15, weight: .semibold))
                    .help("Helper processes are counted with their app. Quit asks the app to close, so it can save your work.")
                Text("  \(monitor.apps.count) running").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                ForEach(Sort.allCases, id: \.self) { s in
                    Button { withAnimation(.easeOut(duration: 0.2)) { sort = s } } label: {
                        HStack(spacing: 3) {
                            Text(s.rawValue)
                            if sort == s { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
                        }
                        .font(.system(size: 12, weight: sort == s ? .semibold : .regular))
                        .foregroundStyle(sort == s ? Color.primary : Color.secondary)
                        .frame(width: Column.width, alignment: .trailing)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Color.clear.frame(width: Column.action, height: 1)
            }
    }

    private var appsSection: some View {
        let list = sorted
        let shown = showAll ? list : Array(list.prefix(Self.rows))
        return VStack(alignment: .leading, spacing: 4) {
            VStack(spacing: 0) {
                ForEach(shown) { a in
                    AppRow(monitor: monitor, app: a, sort: sort)
                    if a.id != shown.last?.id { Divider().padding(.leading, 38).opacity(0.5) }
                }
            }
            if list.count > Self.rows {
                Button(showAll ? "Show fewer" : "Show all \(list.count)") { withAnimation { showAll.toggle() } }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
                    .padding(.top, 8).padding(.horizontal, 4)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 20) {
            Toggle("Warn when the Mac is struggling", isOn: $hogAlerts)
                .toggleStyle(.switch).controlSize(.small)
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Toggle("Developer mode", isOn: $devMode)
                .toggleStyle(.switch).controlSize(.small)
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text("Updates every 2 seconds").font(.system(size: 12)).foregroundStyle(.tertiary)
        }
    }
}

enum Column {
    static let width: CGFloat = 70
    static let action: CGFloat = 92
}

// MARK: Gauge

private struct Gauge: View {
    var title: String
    var value: String
    var detail: String
    var history: [Double]
    var ceiling: Double?
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.3), value: value)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Sparkline(values: history, ceiling: ceiling, tint: tint)
                .frame(height: 26)
                .padding(.top, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
    }
}

/// The last two minutes, as a soft line with a fill underneath.
private struct Sparkline: View {
    var values: [Double]
    var ceiling: Double?
    var tint: Color

    var body: some View {
        GeometryReader { g in
            let top = max(ceiling ?? (values.max() ?? 1) * 1.2, 1)
            let recent = Array(values.suffix(60))
            let step = g.size.width / CGFloat(max(recent.count - 1, 1))
            let pts: [CGPoint] = recent.enumerated().map { i, v in
                CGPoint(x: CGFloat(i) * step, y: g.size.height * (1 - CGFloat(min(v / top, 1))))
            }
            if pts.count > 1 {
                Path { p in
                    p.move(to: CGPoint(x: pts[0].x, y: g.size.height))
                    pts.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: pts.last!.x, y: g.size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    p.move(to: pts[0])
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

// MARK: App row

private struct AppRow: View {
    @ObservedObject var monitor: Monitor
    var app: AppUsage
    var sort: ActivityView.Sort
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: monitor.icon(app)).resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.system(size: 14)).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            metric(percent(app.cpu), .cpu, hot: app.cpu >= 80)
            metric(memory(app.memory), .memory, hot: false)
            metric(app.gpu >= 0.5 ? percent(app.gpu) : "–", .gpu, hot: false)
            metric(String(format: "%.1f", app.energy), .energy, hot: app.energy >= 80)
            action.frame(width: Column.action, alignment: .trailing)
        }
        .padding(.vertical, 8).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hover ? 0.04 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    private var subtitle: String {
        if monitor.quitting[app.id] != nil { return monitor.stubborn(app.id) ? "Not responding" : "Quitting…" }
        if app.id == Sampler.macOS { return "\(app.processes) background processes" }
        if let o = app.owner { return "Virtual machine · stop it from \(o)" }
        if app.system { return "Part of macOS" }
        if app.processes > 1 { return "\(app.processes) processes" }
        return app.isApp ? "App" : "Process \(app.pid)"
    }

    private func metric(_ text: String, _ column: ActivityView.Sort, hot: Bool) -> some View {
        Text(text)
            .font(.system(size: 13, weight: sort == column ? .medium : .regular)).monospacedDigit()
            .foregroundStyle(hot ? Color.orange : (sort == column ? Color.primary : Color.secondary))
            .frame(width: Column.width, alignment: .trailing)
    }

    @ViewBuilder private var action: some View {
        if !monitor.canQuit(app) {
            Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(.quaternary)
                .help(app.owner.map { "Run by \($0). Stop it from \($0) so your containers shut down cleanly." }
                      ?? (app.system ? "Part of macOS. Butler leaves it alone." : "macOS needs this running."))
        } else if monitor.stubborn(app.id) {
            Pill(title: "Force Quit", tint: .red) { monitor.forceQuit(app) }
        } else if monitor.quitting[app.id] != nil {
            ProgressView().controlSize(.small)
        } else {
            Pill(title: "Quit", tint: nil) { monitor.quit(app) }
                .opacity(hover ? 1 : 0)
        }
    }
}

private struct Pill: View {
    var title: String
    var tint: Color?
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint == nil ? Color.primary : Color.white)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(tint ?? Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: Localhost

private struct ServersSection: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "terminal").foregroundStyle(.indigo).font(.system(size: 13, weight: .semibold))
                Text("Localhost").font(.system(size: 15, weight: .semibold))
                if !monitor.servers.isEmpty {
                    Text("\(Set(monitor.servers.map(\.pid)).count) running").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            Text("Servers you started. Click a port to open it in your browser.")
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 6)

            if monitor.servers.isEmpty {
                Text("Nothing is running on localhost")
                    .font(.system(size: 13)).foregroundStyle(.tertiary).padding(.vertical, 10).padding(.horizontal, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(monitor.servers) { s in
                        ServerRow(monitor: monitor, server: s)
                        if s.id != monitor.servers.last?.id { Divider().padding(.leading, 76).opacity(0.5) }
                    }
                }
            }
        }
    }
}

private struct ServerRow: View {
    @ObservedObject var monitor: Monitor
    var server: DevServer
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if let u = URL(string: "http://localhost:\(server.port)") { NSWorkspace.shared.open(u) }
            } label: {
                Text(":\(String(server.port))")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 64, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open http://localhost:\(server.port)")

            VStack(alignment: .leading, spacing: 1) {
                Text(server.project).font(.system(size: 14)).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .help(server.folder)
            Spacer(minLength: 12)
            if server.network {
                Text("Network").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.12)))
                    .help("Listening on every address, so other devices on your network can reach it.")
            }
            action.frame(width: Column.action, alignment: .trailing)
        }
        .padding(.vertical, 8).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hover ? 0.04 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    private var subtitle: String {
        if case .container = server.kind {
            return "forwarded port" + (server.started.map { " · up " + uptime($0) } ?? "")
        }
        var parts = [server.tool]
        if let s = server.started { parts.append("up " + uptime(s)) }
        if case .service = server.kind { parts.append("background service") }
        if monitor.stopping[server.id] != nil { parts.append(monitor.stubbornServer(server.id) ? "not responding" : "stopping…") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var action: some View {
        switch server.kind {
        case .container(let owner):
            Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(.quaternary)
                .help("A container's port. Stop the container from \(owner), so the rest keep running.")
        case .service:
            Pill(title: "Stop", tint: nil) { monitor.stop(server) }
                .help("Kept running by macOS. Stopping it unloads it until you next log in.")
                .opacity(hover ? 1 : 0)
        case .process:
            if monitor.stubbornServer(server.id) {
                Pill(title: "Force Stop", tint: .red) { monitor.forceStop(server) }
            } else if monitor.stopping[server.id] != nil {
                ProgressView().controlSize(.small)
            } else {
                Pill(title: "Stop", tint: nil) { monitor.stop(server) }.opacity(hover ? 1 : 0)
            }
        }
    }

    private func uptime(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h \(s / 60 % 60)m" }
        return "\(s / 86_400)d"
    }
}
