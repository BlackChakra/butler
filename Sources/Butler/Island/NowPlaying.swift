import SwiftUI
import AppKit
import Carbon

/// What is playing in Apple Music, VLC or YouTube Music (in Chrome or another Chromium browser).
///
/// Each app is asked directly through AppleScript, its supported automation interface. macOS asks once per app
/// whether Butler may do that. Apps that are not open are never asked, so nothing is launched by accident.
struct Track: Equatable {
    enum Source: Equatable {
        case music, vlc, youtube(browser: String)
        var name: String {
            switch self {
            case .music: "Music"
            case .vlc: "VLC"
            case .youtube: "YouTube Music"
            }
        }
        /// One line on how to get the artist and controls when a browser only shares the tab title.
        var browserHint: String {
            if case .youtube(let b) = self, b == "com.apple.Safari" { return "For controls: Safari › Settings › Developer › Allow JavaScript from Apple Events" }
            return "For controls: View › Developer › Allow JavaScript from Apple Events"
        }
    }
    var source: Source
    var title: String
    var artist: String
    var playing: Bool
    var duration: Double?
    var position: Double?
    var stamp = Date()
    /// Changes when the song changes, so artwork is fetched once per song.
    var artworkKey: String
    var artworkURL: String?
    /// False when the browser does not let Butler read or control the page (see Chrome's Apple Events setting).
    var controllable = true

    func position(at date: Date) -> Double? {
        guard let p = position else { return nil }
        let now = playing ? p + date.timeIntervalSince(stamp) : p
        return duration.map { min(now, $0) } ?? now
    }
}

@MainActor
final class NowPlaying: ObservableObject {
    static let shared = NowPlaying()

    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?

    static var enabled: Bool { UserDefaults.standard.object(forKey: "showNowPlaying") as? Bool ?? true }

    private let queue = DispatchQueue(label: "butler.nowplaying")
    private var timer: Timer?
    private var busy = false
    private var artKey: String?
    private var lastRefresh = Date.distantPast

    func start() {
        guard timer == nil else { return }
        // Every 1.5 seconds while something plays (so the progress and controls keep up), every 4 when nothing does.
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let gap: TimeInterval = self.track?.playing == true ? 1.5 : 4
                if Date().timeIntervalSince(self.lastRefresh) >= gap - 0.05 { self.refresh() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    // MARK: Reading

    private func refresh() {
        guard Self.enabled else { if track != nil { track = nil; artwork = nil }; return }
        guard !busy else { return }
        busy = true
        lastRefresh = Date()
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        queue.async {
            let found = Probe.all(running: running)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.busy = false
                    self.apply(found)
                }
            }
        }
    }

    private func apply(_ found: [Track]) {
        // Something playing wins over something paused; otherwise keep showing the last paused song.
        let pick = found.first(where: \.playing) ?? found.first(where: { $0.source == track?.source }) ?? found.first
        if pick != track { track = pick }
        guard let pick else { artwork = nil; artKey = nil; return }
        if pick.artworkKey != artKey {
            artKey = pick.artworkKey
            artwork = nil
            loadArtwork(for: pick)
        }
    }

    private func loadArtwork(for t: Track) {
        let key = t.artworkKey
        switch t.source {
        case .music:
            queue.async {
                let img = Probe.musicArtwork()
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { if self?.artKey == key { self?.artwork = img } }
                }
            }
        case .youtube:
            guard let s = t.artworkURL, let url = URL(string: s), url.scheme == "https" else { return }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                let img = data.flatMap(NSImage.init(data:))
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { if self?.artKey == key { self?.artwork = img } }
                }
            }.resume()
        case .vlc:
            break   // VLC does not share artwork through AppleScript
        }
    }

    // MARK: Controls

    enum Command { case playPause, next, previous }

    func send(_ c: Command) {
        guard let t = track else { return }
        // Show the new state at once; the next refresh confirms it.
        if c == .playPause {
            var u = t
            u.position = t.position(at: Date())
            u.stamp = Date()
            u.playing.toggle()
            track = u
        }
        queue.async { Probe.send(c, to: t.source) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
    }
}

/// The AppleScript side. Runs on one background queue only.
private enum Probe {
    static let browsers = ["com.google.Chrome", "com.apple.Safari", "com.brave.Browser", "com.microsoft.edgemac", "ai.perplexity.comet", "company.thebrowser.Browser"]
    static let safari = "com.apple.Safari"

    /// Safari names things differently from Chromium browsers: "name" for a tab's title, "do JavaScript … in" to run a script.
    private static func tabTitle(_ b: String) -> String { b == safari ? "name of t" : "title of t" }
    private static func runJS(_ b: String, _ js: String) -> String {
        b == safari ? "do JavaScript \"\(appleScriptString(js))\" in t" : "execute t javascript \"\(appleScriptString(js))\""
    }
    /// When an app last refused. Asked again after two minutes: macOS can refuse without asking when a prompt cannot be
    /// shown at that moment (for example while Butler's own window is opening), and that is not a real "no".
    nonisolated(unsafe) static var refusedAt = [String: Date]()
    nonisolated(unsafe) static var allowed = Set<String>()

    static func all(running: Set<String>) -> [Track] {
        var out: [Track] = []
        if running.contains("com.apple.Music"), let t = music() { out.append(t) }
        if running.contains("org.videolan.vlc"), let t = vlc() { out.append(t) }
        for b in browsers where running.contains(b) {
            if let t = youtube(b) { out.append(t); break }
        }
        return out
    }

    /// Asks macOS whether Butler may automate this app. This is what shows the "Butler wants to control …" prompt;
    /// a plain AppleScript call can fail with "not authorized" without ever asking.
    private static func permission(_ app: String) -> Bool {
        if allowed.contains(app) { return true }
        if let t = refusedAt[app], Date().timeIntervalSince(t) < 120 { return false }
        var target = AEAddressDesc()
        let status: OSStatus = app.withCString { cs in
            guard AECreateDesc(DescType(typeApplicationBundleID), cs, strlen(cs), &target) == noErr else { return -1 }
            defer { AEDisposeDesc(&target) }
            return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), true)
        }
        if status == noErr { allowed.insert(app); refusedAt[app] = nil; return true }
        if status != -600 { refusedAt[app] = Date() }   // -600: the app quit meanwhile
        return false
    }

    /// Runs a script; nil on any error. Remembers a "not allowed" answer so the user is not asked again.
    /// Compiled scripts, kept: compiling AppleScript is the slow part, and the same few scripts run every few seconds.
    nonisolated(unsafe) private static var compiled = [String: NSAppleScript]()
    private static let compileLock = NSLock()

    private static func run(_ source: String, app: String) -> String? {
        guard permission(app) else { return nil }
        var err: NSDictionary?
        compileLock.lock()
        let script: NSAppleScript? = compiled[source] ?? {
            guard let s = NSAppleScript(source: source), s.compileAndReturnError(nil) else { return nil }
            if compiled.count > 40 { compiled.removeAll() }
            compiled[source] = s
            return s
        }()
        compileLock.unlock()
        let result = script?.executeAndReturnError(&err)
        if let e = err {
            if (e[NSAppleScript.errorNumber] as? Int) == -1743 { allowed.remove(app); refusedAt[app] = Date() }
            return nil
        }
        return result?.stringValue
    }

    private static func lines(_ s: String?) -> [String]? { s.map { $0.components(separatedBy: "\n") } }

    // Apple Music
    static func music() -> Track? {
        let s = """
        tell application id "com.apple.Music"
            if player state is stopped then return "stopped"
            set t to current track
            return (player state as text) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (duration of t) & linefeed & (player position) & linefeed & (album of t)
        end tell
        """
        guard let l = lines(run(s, app: "com.apple.Music")), l.count >= 5 else { return nil }
        return Track(source: .music, title: l[1], artist: l[2], playing: l[0] == "playing",
                     duration: num(l[3]), position: num(l[4]),
                     artworkKey: "music|\(l[1])|\(l[2])|\(l.count > 5 ? l[5] : "")")
    }

    static func musicArtwork() -> NSImage? {
        let s = """
        tell application id "com.apple.Music"
            try
                return data of artwork 1 of current track
            end try
        end tell
        """
        var err: NSDictionary?
        guard let d = NSAppleScript(source: s)?.executeAndReturnError(&err), err == nil else { return nil }
        return NSImage(data: d.data)
    }

    // VLC
    static func vlc() -> Track? {
        let s = """
        tell application id "org.videolan.vlc"
            try
                set n to name of current item
            on error
                return "none"
            end try
            return (playing as text) & linefeed & n & linefeed & (duration of current item) & linefeed & (current time)
        end tell
        """
        guard let l = lines(run(s, app: "org.videolan.vlc")), l.count >= 4 else { return nil }
        let name = (l[1] as NSString).deletingPathExtension
        return Track(source: .vlc, title: name, artist: "", playing: l[0] == "true",
                     duration: num(l[2]), position: num(l[3]), artworkKey: "vlc|\(l[1])")
    }

    // YouTube Music in a Chromium browser
    static let readJS = #"(function(){var m=navigator.mediaSession&&navigator.mediaSession.metadata;var v=document.querySelector('video');var a=m&&m.artwork&&m.artwork.length?m.artwork[m.artwork.length-1].src:'';return [m?m.title:'',m?m.artist:'',v?(v.paused?'0':'1'):'',v&&isFinite(v.duration)?v.duration:'',v?v.currentTime:'',a].join('\n');})()"#

    static func youtube(_ browser: String) -> Track? {
        let s = """
        tell application id "\(browser)"
            repeat with w in windows
                -- One request for every address in the window, instead of one per tab.
                set us to URL of tabs of w
                repeat with i from 1 to count of us
                    if item i of us contains "music.youtube.com" then
                        set t to tab i of w
                        try
                            return "js" & linefeed & (\(runJS(browser, readJS)))
                        on error
                            return "title" & linefeed & (\(tabTitle(browser)))
                        end try
                    end if
                end repeat
            end repeat
            return "none"
        end tell
        """
        guard let l = lines(run(s, app: browser)), l.count >= 2 else { return nil }
        if l[0] == "js", l.count >= 7, !l[1].isEmpty {
            return Track(source: .youtube(browser: browser), title: l[1], artist: l[2], playing: l[3] == "1",
                         duration: num(l[4]), position: num(l[5]),
                         artworkKey: "yt|\(l[1])|\(l[2])", artworkURL: l[6].isEmpty ? nil : l[6])
        }
        if l[0] == "title" {
            // The browser does not allow scripts from Apple Events: only the tab title is available.
            var title = l[1]
            for suffix in [" | YouTube Music", " - YouTube Music"] where title.hasSuffix(suffix) { title = String(title.dropLast(suffix.count)) }
            guard !title.isEmpty, title != "YouTube Music" else { return nil }
            return Track(source: .youtube(browser: browser), title: title, artist: "", playing: true,
                         artworkKey: "yt|\(title)", controllable: false)
        }
        return nil
    }

    // Controls
    static func send(_ c: NowPlaying.Command, to source: Track.Source) {
        switch source {
        case .music:
            let verb = c == .playPause ? "playpause" : (c == .next ? "next track" : "previous track")
            _ = run("tell application id \"com.apple.Music\" to \(verb)", app: "com.apple.Music")
        case .vlc:
            let verb = c == .playPause ? "play" : (c == .next ? "next" : "previous")
            _ = run("tell application id \"org.videolan.vlc\" to \(verb)", app: "org.videolan.vlc")
        case .youtube(let browser):
            let sel = c == .playPause ? "#play-pause-button" : (c == .next ? ".next-button" : ".previous-button")
            let js = "var b=document.querySelector('\(sel)');if(b){b.click();}"
            let s = """
            tell application id "\(browser)"
                repeat with w in windows
                    repeat with t in tabs of w
                        if URL of t contains "music.youtube.com" then
                            \(runJS(browser, js))
                            return "ok"
                        end if
                    end repeat
                end repeat
            end tell
            """
            _ = run(s, app: browser)
        }
    }

    /// Escapes text for an AppleScript string literal, where backslash and double quote are special.
    private static func appleScriptString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func num(_ s: String) -> Double? {
        Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }
}
