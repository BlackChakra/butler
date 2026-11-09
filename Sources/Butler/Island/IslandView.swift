import SwiftUI
import AppKit

/// Black body that hangs from the top edge. The top corners flare outward into the screen edge,
/// the bottom corners are rounded, so it reads as one piece with the notch.
struct IslandShape: Shape {
    var shoulder: CGFloat
    var corner: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, corner) }
        set { shoulder = newValue.first; corner = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let s = min(shoulder, r.height / 2)
        let c = max(0, min(corner, (r.width - 2 * s) / 2, r.height - s))
        let k: CGFloat = 0.5523
        let xl = r.minX + s, xr = r.maxX - s
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: xr, y: r.minY + s), control: CGPoint(x: xr, y: r.minY))
        p.addLine(to: CGPoint(x: xr, y: r.maxY - c))
        p.addCurve(to: CGPoint(x: xr - c, y: r.maxY),
                   control1: CGPoint(x: xr, y: r.maxY - c + k * c), control2: CGPoint(x: xr - c + k * c, y: r.maxY))
        p.addLine(to: CGPoint(x: xl + c, y: r.maxY))
        p.addCurve(to: CGPoint(x: xl, y: r.maxY - c),
                   control1: CGPoint(x: xl + c - k * c, y: r.maxY), control2: CGPoint(x: xl, y: r.maxY - c + k * c))
        p.addLine(to: CGPoint(x: xl, y: r.minY + s))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY), control: CGPoint(x: xl, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: View

/// The island's fixed measurements. The notch itself comes from `NotchGeometry`.
enum IslandSize {
    /// How far the top corners flare out into the screen edge.
    static let shoulder: CGFloat = 8
    /// Width of each status area beside the notch.
    static let wing: CGFloat = 80
    /// The open island, below the notch.
    static let expandedBody = CGSize(width: 390, height: 156)
    /// A reminder card, below the notch.
    static let reminderBody = CGSize(width: 390, height: 58)
}

struct IslandView: View {
    @ObservedObject var model: Model
    @ObservedObject var state: IslandState
    var open: () -> Void
    @Namespace private var tabs

    private var card: Bool { state.expanded || state.reminder != nil }

    private var size: CGSize {
        let n = state.notch
        if state.expanded {
            return CGSize(width: IslandSize.expandedBody.width + 2 * IslandSize.shoulder, height: n.height + IslandSize.expandedBody.height)
        }
        if state.reminder != nil {
            return CGSize(width: IslandSize.reminderBody.width + 2 * IslandSize.shoulder, height: n.height + IslandSize.reminderBody.height)
        }
        let body = state.wings ? n.width + 2 * IslandSize.wing : n.width
        return CGSize(width: body + 2 * IslandSize.shoulder, height: n.height)
    }

    private var corner: CGFloat { state.expanded ? 30 : (card ? 26 : 11) }

    // Content appears late and leaves early, so the shape always leads and the text never outlives it.
    private var reveal: AnyTransition {
        .asymmetric(
            insertion: AnyTransition.scale(scale: 0.9, anchor: .top).animation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.06))
                .combined(with: AnyTransition.opacity.animation(.easeOut(duration: 0.22).delay(0.1))),
            removal: AnyTransition.opacity.animation(.easeIn(duration: 0.07)))
    }

    var body: some View {
        let n = state.notch
        let shape = IslandShape(shoulder: IslandSize.shoulder, corner: corner)
        // The island grows with a little life and settles back without overshoot.
        let spring: Animation = state.expanded || state.reminder != nil
            ? .spring(response: 0.5, dampingFraction: 0.8)
            : .spring(response: 0.36, dampingFraction: 0.92)

        ZStack(alignment: .top) {
            // Content is laid out at its final size and revealed by the growing shape, never squeezed into it.
            if state.expanded {
                Expanded(model: model, page: state.page, dropTarget: state.dropTarget, notchHeight: n.height, open: open)
                    .padding(.horizontal, IslandSize.shoulder)
                    .overlay(alignment: .topLeading) {
                        PageSwitch(page: $state.page, tabs: [("internaldrive", .storage), ("checklist", .tasks)], ns: tabs)
                            .padding(.leading, IslandSize.shoulder + 26)
                            .frame(height: n.height)
                    }
                    .overlay(alignment: .topTrailing) {
                        PageSwitch(page: $state.page, tabs: [("music.note", .music), ("tray", .shelf)], ns: tabs)
                            .padding(.trailing, IslandSize.shoulder + 26)
                            .frame(height: n.height)
                    }
                    .frame(width: IslandSize.expandedBody.width + 2 * IslandSize.shoulder, height: n.height + IslandSize.expandedBody.height, alignment: .top)
                    // Anything dropped on the open island goes on the shelf.
                    .onDrop(of: [.fileURL, .image], isTargeted: $state.dropTarget) { Shelf.shared.accept($0) }
                    .transition(reveal)
            } else if let r = state.reminder {
                ReminderCard(item: r, more: state.more, notchHeight: n.height, open: open)
                    .padding(.horizontal, IslandSize.shoulder)
                    .frame(width: IslandSize.reminderBody.width + 2 * IslandSize.shoulder, height: n.height + IslandSize.reminderBody.height, alignment: .top)
                    .transition(reveal)
            } else if state.wings {
                Wings(model: model, state: state, notchWidth: n.width)
                    .padding(.horizontal, IslandSize.shoulder)
                    .frame(width: n.width + 2 * IslandSize.wing + 2 * IslandSize.shoulder, height: n.height)
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.12)),
                                            removal: .opacity.animation(.easeIn(duration: 0.07))))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .background(shape.fill(Color.black).shadow(color: .black.opacity(card ? 0.5 : 0), radius: 22, y: 12))
        .animation(spring, value: state.expanded)
        .animation(spring, value: state.activity)
        .animation(spring, value: state.alert)
        .animation(spring, value: state.hog?.app.id)
        .animation(spring, value: state.playing)
        .animation(spring, value: state.shelfCount)
        .animation(spring, value: state.reminder?.id)
        .animation(.spring(response: 0.45, dampingFraction: 0.9), value: state.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// How one page gives way to the next: a soft blur and fade, with a slight change of scale from the top.
struct PageFX: ViewModifier {
    var opacity: Double
    var blur: CGFloat
    var scale: CGFloat
    func body(content: Content) -> some View {
        content.opacity(opacity).blur(radius: blur).scaleEffect(scale, anchor: .top)
    }
}

extension AnyTransition {
    static var pageSwap: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: PageFX(opacity: 0, blur: 8, scale: 0.96), identity: PageFX(opacity: 1, blur: 0, scale: 1)),
            removal: .modifier(active: PageFX(opacity: 0, blur: 8, scale: 1.03), identity: PageFX(opacity: 1, blur: 0, scale: 1)))
    }
}

/// Small icons beside the notch that move between pages: Butler's on the left, shelf and music on the right.
struct PageSwitch: View {
    @Binding var page: IslandPage
    var tabs: [(String, IslandPage)]
    var ns: Namespace.ID
    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.0) { t in tab(t.0, t.1) }
        }
    }
    private func tab(_ symbol: String, _ p: IslandPage) -> some View {
        Button { page = p } label: {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(page == p ? Color.white : Color.white.opacity(0.35))
                .frame(width: 34, height: 24)
                .background {
                    // One highlight that glides to the chosen icon, across both sides of the notch.
                    if page == p { Capsule().fill(Color.white.opacity(0.14)).matchedGeometryEffect(id: "tab", in: ns) }
                }
                // The whole capsule takes the click, not just the lines of the symbol (the thin music note was hard to hit).
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Live activity beside the notch. Left: Butler's own status. Right: Now Playing and the shelf.
struct Wings: View {
    @ObservedObject var model: Model
    @ObservedObject var state: IslandState
    @ObservedObject var music = NowPlaying.shared
    var notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            left.frame(width: IslandSize.wing, alignment: .center).transition(.opacity)
            Spacer().frame(width: notchWidth)
            right.frame(width: IslandSize.wing, alignment: .center).transition(.opacity)
        }
        .foregroundStyle(.white)
    }

    private func label(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
            Text(text).font(.system(size: 11, weight: .medium)).monospacedDigit().lineLimit(1)
        }
        .fixedSize()
    }

    private var critical: Bool { if case .critical? = state.alert { return true }; return false }
    private var busy: Bool { state.activity == .scanning || state.activity == .cleaning }

    /// Busy work comes first, then warnings (a nearly full disk before a hot app), then results.
    @ViewBuilder private var left: some View {
        if !busy, !critical, let h = state.hog {
            HStack(spacing: 5) {
                Image(systemName: h.reason == .memory ? "memorychip.fill" : "flame.fill")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(h.reason == .memory ? Color.red : Color.orange)
                Text(h.reason == .memory ? "Memory" : h.app.name)
                    .font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 54, alignment: .leading)
            }
            .fixedSize(horizontal: true, vertical: false)
        } else {
            status
        }
    }

    @ViewBuilder private var status: some View {
        switch (state.activity, state.alert) {
        case (.scanning, _), (.cleaning, _):
            HStack(spacing: 6) {
                Ring(progress: model.progress)
                Text(model.progress < 0.01 ? "…" : "\(Int(model.progress * 100))%")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
            }
        case (_, .critical(let free)?): label("exclamationmark.triangle.fill", .red, short(free))
        case (_, .low(let free)?): label("exclamationmark.triangle.fill", .orange, short(free))
        case (_, .drop(let lost)?): label("arrow.down", .orange, "−" + short(lost))
        case (_, .tidied(let freed)?): label("sparkles", .green, short(freed))
        case (.ready, _): label("sparkles", .green, short(model.reclaimable))
        case (.done(let freed), _): label("checkmark", .green, freed > 0 ? short(freed) : "Done")
        default: Color.clear.frame(width: 1, height: 1)
        }
    }

    @ViewBuilder private var right: some View {
        HStack(spacing: 7) {
            if state.playing {
                Artwork(image: music.artwork, size: 20, corner: 5)
                if state.shelfCount == 0 { Bars() }
            }
            if state.shelfCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "tray.full.fill").font(.system(size: 11, weight: .semibold))
                    Text("\(state.shelfCount)").font(.system(size: 11, weight: .medium)).monospacedDigit()
                }
                .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    /// "47 GB" rather than "47.25 GB": the wing is small.
    private func short(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        let gb = Double(n) / 1_000_000_000
        if gb >= 10 { return "\(Int(gb.rounded())) GB" }
        return f.string(fromByteCount: n)
    }
}

/// Album art, or a music note when there is none.
struct Artwork: View {
    var image: NSImage?
    var size: CGFloat
    var corner: CGFloat
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note").font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// A small moving level meter while music plays.
struct Bars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let h = 4 + 9 * abs(sin(t * (2.1 + Double(i) * 0.7) + Double(i) * 1.3))
                    Capsule().fill(Color.white.opacity(0.85)).frame(width: 2.5, height: h)
                }
            }
            .frame(height: 14)
        }
    }
}

struct Expanded: View {
    @ObservedObject var model: Model
    var page: IslandPage
    var dropTarget: Bool
    var notchHeight: CGFloat
    var open: () -> Void

    private var usedFraction: Double {
        model.total > 0 ? Double(model.total - model.free) / Double(model.total) : 0
    }
    private var tint: Color {
        let f = 1 - usedFraction
        return f > 0.15 ? .green : (f > 0.05 ? .orange : .red)
    }

    var body: some View {
        // The old page blurs and fades out while the new one comes into focus, instead of swapping in one frame.
        ZStack(alignment: .topLeading) {
            Group {
                switch page {
                case .tasks: TasksPage(tasks: .shared, open: open)
                case .music: MusicPage(music: .shared)
                case .shelf: ShelfPage(shelf: .shared, targeted: dropTarget)
                case .storage: storage
                case .hot: HotPage(monitor: .shared)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .id(page)
            .transition(.pageSwap)
        }
        .foregroundStyle(.white)
        .padding(.top, notchHeight + 6)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }

    private var storage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(bytes(model.free))
                        .font(.system(size: 32, weight: .semibold)).monospacedDigit()
                    Text(sub).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                ZStack {
                    Circle().stroke(Color.white.opacity(0.14), lineWidth: 4)
                    Circle().trim(from: 0, to: usedFraction)
                        .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 38, height: 38)
            }
            MiniBar(model: model)
            HStack(spacing: 10) {
                IslandButton(title: "Open Butler", primary: false) { model.tab = .storage; open() }
                Spacer()
                if model.busy {
                    Text(model.phaseLabel).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                } else if model.spots.isEmpty || model.selectedBytes == 0 {
                    IslandButton(title: "Scan", primary: true) { model.scan() }
                } else {
                    IslandButton(title: "Review \(bytes(model.selectedBytes))", primary: true) { model.tab = .storage; open() }
                }
            }
        }
        .foregroundStyle(.white)
    }

    private var sub: String {
        model.reclaimable > 0 ? "free of \(bytes(model.total)) · \(bytes(model.reclaimable)) can go" : "free of \(bytes(model.total))"
    }
}

struct MiniBar: View {
    @ObservedObject var model: Model
    var body: some View {
        let total = Double(max(model.total, 1))
        let used = Double(max(model.total - model.free, 0))
        let parts = Bucket.allCases.map { ($0, Double(model.bucketTotal($0))) }
        let other = max(used - parts.reduce(0) { $0 + $1.1 }, 0)
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(parts, id: \.0.id) { b, v in Rectangle().fill(b.tint).frame(width: geo.size.width * v / total) }
                Rectangle().fill(Color.white.opacity(0.28)).frame(width: geo.size.width * other / total)
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, alignment: .leading)
            .background(Color.white.opacity(0.1))
            .clipShape(Capsule())
        }
        .frame(height: 6)
    }
}

struct IslandButton: View {
    var title: String
    var primary: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .foregroundStyle(primary ? Color.black : Color.white)
                .background(Capsule().fill(primary ? Color.white : Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }
}

struct Ring: View {
    var progress: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.2), lineWidth: 2.5)
            Circle().trim(from: 0, to: max(0.05, progress))
                .stroke(Color.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
    }
}

extension Model {
    var phaseLabel: String {
        switch phase {
        case .scanning(let n): n == "Looking around" ? "Scanning…" : "Scanning \(n)"
        case .cleaning(let n): "Cleaning \(n)"
        default: ""
        }
    }
}
