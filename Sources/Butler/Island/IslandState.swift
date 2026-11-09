import SwiftUI
import AppKit

/// The hardware notch, or a virtual one on Macs without a notch.
struct NotchGeometry {
    var width: CGFloat
    var height: CGFloat
    var hasNotch: Bool

    static func current() -> NotchGeometry {
        guard let s = NSScreen.island else { return .init(width: 176, height: 32, hasNotch: false) }
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            return .init(width: s.frame.width - l.width - r.width, height: s.safeAreaInsets.top, hasNotch: true)
        }
        return .init(width: 176, height: 32, hasNotch: false)
    }
}

extension NSScreen {
    /// The screen the island lives on: the built-in display with the notch, even when another display has focus.
    static var island: NSScreen? {
        screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? main
    }
}

enum Activity: Equatable {
    case none, scanning, cleaning, ready, done(Int64)
}

/// Butler's own pages sit on the left of the island; the shelf and Now Playing on the right.
/// `hot` has no icon of its own: it opens only from the running-hot alert beside the notch.
enum IslandPage { case storage, tasks, music, shelf, hot }

@MainActor
final class IslandState: ObservableObject {
    @Published var expanded = false
    @Published var activity: Activity = .none          // left wing: scanning, cleaning, results
    @Published var alert: Watchman.Alert?              // left wing: low space, fast drop, weekly tidy
    @Published var hog: Hog?                           // left wing: an app running hot, or memory running low
    @Published var playing = false                     // right wing: something is playing
    @Published var shelfCount = 0                      // right wing: files held on the shelf
    @Published var notch = NotchGeometry.current()
    @Published var page: IslandPage = .storage
    @Published var dropTarget = false                  // a file is being dragged over the open island
    /// A reminder that has come due, and how many more are waiting behind it.
    @Published var reminder: TodoItem?
    @Published var more = 0

    var leftWing: Bool { activity != .none || alert != nil || hog != nil }
    var rightWing: Bool { playing || shelfCount > 0 }
    /// Both wings open together so the island stays centred on the notch; each side only shows its own things.
    var wings: Bool { leftWing || rightWing }
}
