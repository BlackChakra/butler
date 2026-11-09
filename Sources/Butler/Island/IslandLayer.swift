import AppKit

/// Keeps the island in a layer of its own, above every desktop and full-screen app, the way the menu bar is.
///
/// A window that joins all Spaces is drawn into both the old and the new Space while you swipe between them, so a
/// second black notch slides across the screen. A window in its own top layer never moves: it stays on the notch while
/// the Spaces slide underneath it. This uses the window server's private Space calls (SkyLight), the approach notch apps
/// take for the same problem. If they are missing on some future macOS, the island simply behaves as before.
enum IslandLayer {
    private typealias ConnFn = @convention(c) () -> Int32
    private typealias CreateFn = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias LevelFn = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias SpacesFn = @convention(c) (Int32, CFArray) -> Void
    private typealias AddFn = @convention(c) (Int32, CFArray, CFArray) -> Void

    nonisolated(unsafe) private static var conn: Int32 = 0
    nonisolated(unsafe) private static var space: UInt64 = 0
    nonisolated(unsafe) private static var add: AddFn?

    /// Puts the window into the island layer. Call after the window is on screen. Returns false if unavailable.
    @discardableResult
    static func attach(_ window: NSWindow) -> Bool {
        guard window.windowNumber > 0 else { return false }
        if space == 0 && !setUp() { return false }
        guard let add else { return false }
        add(conn, [NSNumber(value: window.windowNumber)] as CFArray, [NSNumber(value: space)] as CFArray)
        return true
    }

    private static func setUp() -> Bool {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else { return false }
        func sym<T>(_ names: [String], _: T.Type) -> T? {
            for n in names { if let p = dlsym(h, n) { return unsafeBitCast(p, to: T.self) } }
            return nil
        }
        guard let mainConn = sym(["SLSMainConnectionID", "CGSMainConnectionID"], ConnFn.self),
              let create = sym(["SLSSpaceCreate", "CGSSpaceCreate"], CreateFn.self),
              let setLevel = sym(["SLSSpaceSetAbsoluteLevel", "CGSSpaceSetAbsoluteLevel"], LevelFn.self),
              let show = sym(["SLSShowSpaces", "CGSShowSpaces"], SpacesFn.self),
              let addFn = sym(["SLSAddWindowsToSpaces", "CGSAddWindowsToSpaces"], AddFn.self)
        else { return false }
        conn = mainConn()
        let s = create(conn, 1, nil)
        guard s != 0 else { return false }
        setLevel(conn, s, Int32.max)   // above every desktop and full-screen Space
        show(conn, [NSNumber(value: s)] as CFArray)
        space = s
        add = addFn
        return true
    }
}
