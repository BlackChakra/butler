import SwiftUI
import AppKit

/// A reminder that came due. Answer it right at the notch.
struct ReminderCard: View {
    var item: TodoItem
    var more: Int
    var notchHeight: CGFloat
    var open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.orange)
                Image(systemName: "bell.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(more > 0 ? "Reminder · \(more) more waiting" : "Reminder")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 8)
            IslandButton(title: "Snooze", primary: false) { Tasks.shared.snooze(item.id, minutes: 10) }
            IslandButton(title: "Done", primary: true) { Tasks.shared.complete(item.id) }
        }
        .foregroundStyle(.white)
        .padding(.top, notchHeight + 2)
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
    }
}

struct TasksPage: View {
    @ObservedObject var tasks: Tasks
    @ObservedObject var sync = AppleSync.shared
    var open: () -> Void

    var body: some View {
        let next = sync.nextEvent
        let list = Array(tasks.open.prefix(next == nil ? 3 : 2))
        VStack(alignment: .leading, spacing: 10) {
            if list.isEmpty && next == nil {
                VStack(alignment: .leading, spacing: 1) {
                    Text("All clear").font(.system(size: 32, weight: .semibold))
                    Text("Nothing on your list").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
            } else {
                VStack(spacing: 2) {
                    if let e = next {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 1.5).fill(e.color).frame(width: 3, height: 14)
                                .frame(width: 15)
                            Text(e.title).font(.system(size: 13)).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(e.now ? "Now" : e.start.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.white.opacity(0.45))
                        }
                        .frame(height: 24)
                    }
                    ForEach(list) { t in
                        let late = (t.due ?? .distantFuture) < Date()
                        HStack(spacing: 10) {
                            Button { withAnimation { tasks.complete(t.id) } } label: {
                                Image(systemName: "circle").font(.system(size: 15)).foregroundStyle(.white.opacity(0.4))
                            }
                            .buttonStyle(.plain)
                            Text(t.title).font(.system(size: 13)).lineLimit(1)
                            Spacer(minLength: 8)
                            if let d = t.due {
                                Text(Remind.label(d, allDay: t.allDay == true)).font(.system(size: 11)).monospacedDigit()
                                    .foregroundStyle(late ? Color.red : Color.white.opacity(0.45))
                            }
                        }
                        .frame(height: 24)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                IslandButton(title: "Open Butler", primary: false) { Model.shared.tab = .tasks; open() }
                Spacer()
                IslandButton(title: "Add task", primary: true) { Model.shared.tab = .tasks; open() }
            }
        }
    }
}

// MARK: Running hot page

/// Opens from the hot-app alert: who is busy, for how long, and a Quit button for each.
struct HotPage: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        content
            .onAppear { monitor.hogCard(open: true) }
            .onDisappear { monitor.hogCard(open: false) }
    }

    @ViewBuilder private var content: some View {
        if let h = monitor.hog {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(h.reason == .memory ? Color.red : Color.orange)
                        Image(systemName: h.reason == .memory ? "memorychip.fill" : "flame.fill")
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                    }
                    .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(h)).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(subtitle(h)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    IslandButton(title: "Ignore", primary: false) { monitor.ignoreHog() }
                }
                VStack(spacing: 2) {
                    ForEach(monitor.offenders(for: h)) { a in row(a, memory: h.reason == .memory) }
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white.opacity(0.3))
                Text("Everything is calm").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.45))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ a: AppUsage, memory: Bool) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: monitor.icon(a)).resizable().frame(width: 18, height: 18)
            Text(a.name).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 8)
            Text(memory ? Butler.memory(a.memory) : percent(a.cpu) + " CPU")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.white.opacity(0.5))
            Group {
                if monitor.stubborn(a.id) {
                    SmallIslandButton(title: "Force Quit", tint: .red) { monitor.forceQuit(a) }
                } else if monitor.quitting[a.id] != nil {
                    Text("Quitting…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                } else {
                    SmallIslandButton(title: "Quit", tint: nil) { monitor.quit(a) }
                }
            }
            .frame(width: 74, alignment: .trailing)
        }
        .frame(height: 26)
    }

    private func title(_ h: Hog) -> String {
        switch h.reason {
        case .cpu: "\(h.app.name) is slowing your Mac"
        case .battery: "\(h.app.name) is draining your battery"
        case .memory: "Memory is critically low"
        }
    }

    private func subtitle(_ h: Hog) -> String {
        let mins = max(1, Int(Date().timeIntervalSince(h.since) / 60))
        switch h.reason {
        case .cpu: return "\(percent(h.app.cpu)) CPU for \(mins) min, Mac at its limit"
        case .battery: return "Draining a low battery for \(mins) min"
        case .memory: return "Quitting an app frees some up"
        }
    }
}

struct SmallIslandButton: View {
    var title: String
    var tint: Color?
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .foregroundStyle(.white)
                .background(Capsule().fill(tint ?? Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: Now Playing page

struct MusicPage: View {
    @ObservedObject var music: NowPlaying

    var body: some View {
        if let t = music.track {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Artwork(image: music.artwork, size: 60, corner: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        if !t.artist.isEmpty {
                            Text(t.artist).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        }
                        Text(t.source.name).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.35))
                    }
                    Spacer(minLength: 0)
                }
                if let d = t.duration, d > 0 {
                    TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                        let pos = t.position(at: ctx.date) ?? 0
                        HStack(spacing: 8) {
                            Text(clock(pos)).frame(width: 34, alignment: .leading)
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.15))
                                    Capsule().fill(Color.white.opacity(0.85)).frame(width: g.size.width * min(max(pos / d, 0), 1))
                                }
                            }
                            .frame(height: 4)
                            Text(clock(d)).frame(width: 34, alignment: .trailing)
                        }
                        .font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.45))
                    }
                    .frame(height: 12)
                }
                if t.controllable {
                    HStack(spacing: 34) {
                        Spacer()
                        control("backward.fill", 15) { music.send(.previous) }
                        control(t.playing ? "pause.fill" : "play.fill", 22) { music.send(.playPause) }
                        control("forward.fill", 15) { music.send(.next) }
                        Spacer()
                    }
                } else {
                    // The browser only shares the tab title until it allows scripts from Apple Events.
                    Text(t.source.browserHint).font(.system(size: 10)).foregroundStyle(.white.opacity(0.35)).lineLimit(1)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "music.note").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white.opacity(0.3))
                Text("Nothing playing").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.45))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func control(_ symbol: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .frame(width: 34, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func clock(_ s: Double) -> String {
        let t = Int(s.rounded(.down))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: Shelf page

struct ShelfPage: View {
    @ObservedObject var shelf: Shelf
    var targeted: Bool

    var body: some View {
        if shelf.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down").font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white.opacity(targeted ? 0.95 : 0.5))
                Text(targeted ? "Let go to hold it here" : "Drop files here")
                    .font(.system(size: 14, weight: .semibold))
                Text("Drag them out again into any app or folder.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(targeted ? 0.6 : 0.18), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(shelf.items) { ShelfTile(shelf: shelf, item: $0) }
                    }
                    .padding(.top, 8).padding(.trailing, 8)   // room for each tile's small buttons
                }
                .frame(height: 92)
                HStack {
                    Text(targeted ? "Let go to add" : "\(shelf.items.count) on the shelf · drag out to copy")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(targeted ? 0.9 : 0.45))
                    Spacer()
                    IslandButton(title: "Clear", primary: false) { withAnimation { shelf.clear() } }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(targeted ? 0.5 : 0), lineWidth: 1.5).padding(-6))
        }
    }
}

struct ShelfTile: View {
    @ObservedObject var shelf: Shelf
    var item: ShelfItem

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = shelf.thumbs[item.id] {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Color.white.opacity(0.1)
                    }
                }
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                // Drag from here into any app. Double-click opens the file.
                .overlay(DragOut(item: item, image: shelf.thumbs[item.id]))

                // Always shown: the island never becomes the active window, so hover is not reliable there.
                HStack(spacing: 3) {
                    mini("doc.on.doc") { shelf.copy(item) }
                    mini("xmark") { withAnimation { shelf.remove(item.id) } }
                }
                .offset(x: 6, y: -6)
            }
            Text(item.name).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.white.opacity(0.75)).frame(width: 70)
        }
        .help(item.path)
    }

    private func mini(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(.black)
                .frame(width: 18, height: 18).background(Circle().fill(Color.white))
        }
        .buttonStyle(.plain)
    }
}
