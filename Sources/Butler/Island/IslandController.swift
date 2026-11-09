import SwiftUI
import AppKit
import Combine

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// Let the panel sit flush against the top edge, over the menu bar and the notch.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Holds the island's SwiftUI view at a fixed size, centred and touching the top, whatever size the window is.
/// Placed by hand on every resize: AppKit's automatic margins lose the centre once both margins reach zero, which
/// pushed the island to one side and cut its corners off against the window edge.
final class TopCenterView: NSView {
    weak var pinned: NSView?
    var pinnedSize = NSSize.zero

    override func resizeSubviews(withOldSize oldSize: NSSize) { place() }

    func place() {
        guard let v = pinned, pinnedSize.width > 0 else { return }
        v.frame = NSRect(x: (bounds.width - pinnedSize.width) / 2, y: bounds.height - pinnedSize.height,
                         width: pinnedSize.width, height: pinnedSize.height)
    }
}

@MainActor
final class IslandController {
    let state = IslandState()
    private let panel: IslandPanel
    private var host: NSHostingView<IslandView>!
    private let model: Model
    private var pollTimer: Timer?
    private var wasDown = false
    private var dragBaseline = NSPasteboard(name: .drag).changeCount
    private var dragging = false
    private var openedByDrag = false
    private var dragFromInside = false
    private var bag = Set<AnyCancellable>()
    private var readyTimer: DispatchWorkItem?
    private var shrink: DispatchWorkItem?

    init(model: Model, open: @escaping () -> Void) {
        self.model = model
        panel = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // The SwiftUI view never changes size. It is as big as the largest look and pinned to the top of the window;
        // the window only grows and shrinks around it, like a frame around a picture. If the view itself were resized,
        // SwiftUI would see the island's position change (it measures from the bottom) and animate that too, so on
        // opening the island would start below the menu bar and slide up instead of growing out of the notch.
        host = NSHostingView(rootView: IslandView(model: model, state: state, open: open))
        host.sizingOptions = []
        let root = TopCenterView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        root.addSubview(host)
        root.pinned = host
        panel.contentView = root
        pinHost()
        resize(to: targetSize())

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.state.notch = .current()
                self.pinHost()
                self.resize(to: self.targetSize())
            }
        }
        // Read the pointer directly instead of using event monitors, which can miss clicks over the menu bar.
        // Only the moment of a click is used; hovering does nothing.
        let poll = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll

        if Debug.expand { change { $0.expanded = true } }
        switch Debug.page {
        case "tasks": state.page = .tasks
        case "music": state.page = .music
        case "shelf": state.page = .shelf
        case "hot": state.page = .hot
        default: break
        }
        if Debug.cycle {
            let order: [IslandPage] = [.storage, .tasks, .music, .shelf]
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let i = order.firstIndex(of: self.state.page) else { return }
                    self.state.page = order[(i + 1) % order.count]
                }
            }
        }
        if Debug.demo {
            Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.change { $0.expanded.toggle() } }
            }
        }
        model.$phase.receive(on: RunLoop.main).sink { [weak self] phase in self?.follow(phase) }.store(in: &bag)

        // Left wing: low space, fast drops and the weekly tidy.
        Watchman.shared.$alert.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] a in
            self?.change { $0.alert = a }
        }.store(in: &bag)
        // Left wing: an app that has been running hot for a while, or memory running out.
        Monitor.shared.$hog.removeDuplicates { $0?.app.id == $1?.app.id && $0?.reason == $1?.reason }
            .receive(on: RunLoop.main).sink { [weak self] h in
                self?.change {
                    $0.hog = h
                    if h == nil && $0.page == .hot { $0.page = .storage }
                    if h != nil && Debug.page == "hot" { $0.page = .hot }
                }
            }.store(in: &bag)
        // Right wing: something playing, and files on the shelf.
        NowPlaying.shared.$track.map { $0?.playing ?? false }.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] p in
            self?.change { $0.playing = p }
        }.store(in: &bag)
        Shelf.shared.$items.map(\.count).removeDuplicates().receive(on: RunLoop.main).sink { [weak self] c in
            self?.change { $0.shelfCount = c }
        }.store(in: &bag)

        // Reminders that come due drop down at the notch.
        Tasks.shared.$ringing.receive(on: RunLoop.main).sink { [weak self] r in
            self?.change {
                $0.reminder = r.first
                $0.more = max(r.count - 1, 0)
                if !r.isEmpty { $0.page = .tasks }
            }
        }.store(in: &bag)
    }

    func setVisible(_ on: Bool) {
        guard on else { panel.orderOut(nil); return }
        panel.orderFrontRegardless()
        // Its own top layer: the island stays on the notch while Spaces slide underneath, so no second notch appears.
        IslandLayer.attach(panel)
    }

    /// Option + Command + B. Open the island for a few seconds, or put it away if it is already open.
    func summon() {
        if state.expanded && !Debug.expand && !Debug.demo {
            change { $0.expanded = false }
        } else {
            change { $0.expanded = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.2) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.state.expanded, !self.zone().contains(NSEvent.mouseLocation) else { return }
                    self.change { $0.expanded = false }
                }
            }
        }
    }

    // MARK: Changing what the island shows

    /// Every change goes through here, in this order:
    /// 1. grow the window to fit both the old and the new look, so no frame of the animation is ever clipped;
    /// 2. change the state, so SwiftUI animates inside a window that is already big enough;
    /// 3. shrink the window to the new look once the animation has finished.
    /// Resizing during the change (not before it) makes SwiftUI draw the old state and skip the new one.
    private func change(_ mutate: (IslandState) -> Void) {
        let before = targetSize()
        mutate(state)
        let after = targetSize()
        let union = NSSize(width: max(before.width, after.width, panel.frame.width),
                           height: max(before.height, after.height, panel.frame.height))
        // The window must be big before SwiftUI's next draw. setFrame here is safe: the change above is complete.
        resize(to: union)
        panel.ignoresMouseEvents = !(state.expanded || state.reminder != nil)
        shrink?.cancel()
        if union != after {
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { guard let self else { return }; self.resize(to: self.targetSize()) }
            }
            shrink = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: item)
        }
    }

    /// Sizes the SwiftUI view for the largest look and pins it to the top centre of the window.
    private func pinHost() {
        guard let root = panel.contentView as? TopCenterView else { return }
        let n = state.notch
        root.pinnedSize = NSSize(width: IslandSize.expandedBody.width + 2 * IslandSize.shoulder + 80, height: n.height + IslandSize.expandedBody.height + 40)
        root.place()
    }

    /// The window size the current look needs, with room for the shadow.
    private func targetSize() -> NSSize {
        let n = state.notch
        let margin: CGFloat = 40
        var w: CGFloat, h: CGFloat
        if state.expanded {
            w = IslandSize.expandedBody.width + 2 * IslandSize.shoulder; h = n.height + IslandSize.expandedBody.height
        } else if state.reminder != nil {
            w = IslandSize.reminderBody.width + 2 * IslandSize.shoulder; h = n.height + IslandSize.reminderBody.height
        } else {
            w = n.width + 2 * IslandSize.shoulder + (state.wings ? 2 * IslandSize.wing : 0); h = n.height
        }
        return NSSize(width: w + 2 * margin, height: h + margin)
    }

    /// Flush with the top of the screen, centred on the notch.
    private func resize(to size: NSSize) {
        guard let s = NSScreen.island else { return }
        let frame = NSRect(x: s.frame.midX - size.width / 2, y: s.frame.maxY - size.height, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
    }

    // Live activity follows what the app is doing.
    private func follow(_ phase: Model.Phase) {
        readyTimer?.cancel()
        let next: Activity
        switch phase {
        case .idle: next = .none
        case .scanning: next = .scanning
        case .cleaning: next = .cleaning
        case .done(let freed, _): next = .done(freed)
        case .ready:
            next = .ready
            let t = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { if self?.state.activity == .ready { self?.change { $0.activity = .none } } }
            }
            readyTimer = t
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: t)
        }
        if state.activity != next { change { $0.activity = next } }
    }

    // MARK: Clicks

    // Click only. Passing the pointer over the notch does nothing, so it never drops down while you work.
    private func zone() -> NSRect {
        guard let s = NSScreen.island else { return .zero }
        let n = state.notch
        let wings: CGFloat = state.wings ? 2 * IslandSize.wing : 0
        let w = state.expanded ? IslandSize.expandedBody.width + 16 : n.width + 20 + wings
        let h = state.expanded ? n.height + IslandSize.expandedBody.height : n.height + 2
        // Extend above the screen edge: a pointer pushed into the top row sits exactly on maxY, which a plain rect excludes.
        return NSRect(x: s.frame.midX - w / 2, y: s.frame.maxY - h, width: w, height: h + 6)
    }

    private func notchRect() -> NSRect {
        guard let s = NSScreen.island else { return .zero }
        let n = state.notch
        return NSRect(x: s.frame.midX - n.width / 2, y: s.frame.maxY - n.height, width: n.width, height: n.height + 6)
    }

    /// Where a dragged file opens the shelf: the notch and a generous area around it.
    private func dropZone() -> NSRect {
        guard let s = NSScreen.island else { return .zero }
        let n = state.notch
        let w = n.width + 2 * IslandSize.wing + 80, h = n.height + 50
        return NSRect(x: s.frame.midX - w / 2, y: s.frame.maxY - h, width: w, height: h + 6)
    }

    private func poll() {
        if Debug.expand || Debug.demo { return }
        let down = NSEvent.pressedMouseButtons & 1 != 0
        let loc = NSEvent.mouseLocation
        defer { wasDown = down }

        // A drag is under way when the drag pasteboard changed while the button is held.
        let pb = NSPasteboard(name: .drag).changeCount
        if !down { dragBaseline = pb }
        let nowDragging = down && pb != dragBaseline
        if nowDragging && !dragging { dragging = true; dragFromInside = state.expanded && zone().contains(loc) }
        if dragging {
            // A file brought from elsewhere onto the open island: show the shelf it will land on.
            if state.expanded && !dragFromInside && zone().contains(loc) && state.page != .shelf {
                change { $0.page = .shelf }
            }
            // Bring a file to the notch and the shelf opens to take it.
            if !state.expanded && dropZone().contains(loc) {
                openedByDrag = true
                change { $0.expanded = true; $0.page = .shelf }
            }
            if !down {
                dragging = false
                // The drag ended. If the island opened for it, or the file was dragged out of it, tuck it away again.
                if state.expanded && (openedByDrag || !zone().contains(loc)) {
                    openedByDrag = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, self.state.expanded, !self.zone().contains(NSEvent.mouseLocation) else { return }
                            self.change { $0.expanded = false }
                        }
                    }
                }
            }
            return
        }

        guard down && !wasDown else { return }   // only the moment of a click matters
        if !state.expanded {
            guard zone().contains(loc), let scr = NSScreen.island else { return }
            // Click the right side of the notch for music and the shelf; the left side or the notch for Butler's pages.
            let rightSide = loc.x > scr.frame.midX + state.notch.width / 2
            change {
                if rightSide { $0.page = $0.playing || NowPlaying.shared.track != nil && $0.shelfCount == 0 ? .music : .shelf }
                else if $0.page == .music || $0.page == .shelf || $0.page == .hot { $0.page = .storage }
                if !rightSide {
                    // The left side opens whatever its wing is showing: a nearly full disk, a hot app, then other news.
                    if case .critical? = $0.alert { $0.page = .storage }
                    else if $0.hog != nil { $0.page = .hot }
                    else if $0.alert != nil { $0.page = .storage }
                }
                $0.expanded = true
            }
        } else if !zone().contains(loc) || notchRect().contains(loc) {
            change { $0.expanded = false }                                                  // click away, or the notch again: close
        }
    }
}
