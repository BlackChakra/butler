import Foundation

/// Launch switches for development, read from environment variables. None of them is needed to use Butler; they
/// stage a state so it can be checked or filmed without waiting for it to happen for real.
///
///     BUTLER_TAB=tasks|activity        open the main window on that tab
///     BUTLER_PAGE=tasks|music|shelf|hot open the island on that page
///     BUTLER_EXPAND=1                  keep the island open
///     BUTLER_DEMO=1                    open and close the island on a loop
///     BUTLER_CYCLE=1                   step through the island's pages
///     BUTLER_DOCK=1                    dock the main window into the island after 8 seconds
///     BUTLER_PICKER=1                  open the reminder time picker in Tasks
///     BUTLER_ALERT=low                 show a sample low-space warning
///     BUTLER_HOG=1                     show a sample "slowing your Mac" alert
///     BUTLER_PORTS=1                   print what the localhost scan finds to stderr
///     BUTLER_ROWS=n                    how many apps Activity lists before "Show all"
enum Debug {
    private static let env = ProcessInfo.processInfo.environment
    private static func on(_ key: String) -> Bool { env[key] != nil }

    static let tab = env["BUTLER_TAB"]
    static let page = env["BUTLER_PAGE"]
    static let expand = on("BUTLER_EXPAND")
    static let demo = on("BUTLER_DEMO")
    static let cycle = on("BUTLER_CYCLE")
    static let dock = on("BUTLER_DOCK")
    static let picker = on("BUTLER_PICKER")
    static let alert = env["BUTLER_ALERT"]
    static let hog = on("BUTLER_HOG")
    static let ports = on("BUTLER_PORTS")
    static let rows = Int(env["BUTLER_ROWS"] ?? "")
}
