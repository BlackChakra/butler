import Foundation
import SwiftUI

enum Bucket: String, CaseIterable, Identifiable {
    case rebuildable, yours, appData, macOS
    var id: String { rawValue }

    var title: String {
        switch self {
        case .rebuildable: "Rebuildable"
        case .yours: "Yours"
        case .appData: "App data"
        case .macOS: "macOS"
        }
    }
    var blurb: String {
        switch self {
        case .rebuildable: "Comes back by itself when it is needed."
        case .yours: "Large files you chose to keep. You decide."
        case .appData: "Owned by an app. Clear it from inside that app."
        case .macOS: "Kept by the system. Some of it is safe to remove."
        }
    }
    var symbol: String {
        switch self {
        case .rebuildable: "arrow.triangle.2.circlepath"
        case .yours: "person.crop.circle"
        case .appData: "square.stack.3d.up"
        case .macOS: "macwindow"
        }
    }
    var tint: Color {
        switch self {
        case .rebuildable: Color(red: 0.20, green: 0.78, blue: 0.55)
        case .yours: Color(red: 0.25, green: 0.52, blue: 1.00)
        case .appData: Color(red: 1.00, green: 0.62, blue: 0.20)
        case .macOS: Color(red: 0.62, green: 0.62, blue: 0.68)
        }
    }
}

enum Policy {
    /// Move to the Trash, or delete outright when the user turns Trash off.
    case trash
    /// Delete outright. Used for caches that rebuild themselves, where an undo would not mean anything.
    case permanent
    /// Delete outright, but only files not touched for this many days.
    case permanentOlderThan(Int)
    /// Never deleted from here. The text says how to clear it properly.
    case explain(String)
}

struct Spot: Identifiable {
    let id: String
    var name: String
    var detail: String
    var ifRemoved: String
    var bucket: Bucket
    var paths: [URL]
    var policy: Policy
    var quitBundleID: String? = nil
    var lockedReason: String? = nil
    var filter: (@Sendable (URL) -> Bool)? = nil
    /// Blocks on disk, each file counted once.
    var size: Int64 = 0
    /// What deleting it really gives back: the part not shared with a copy elsewhere. Always the smaller number.
    var frees: Int64 = 0
    /// Why the two differ, in plain words, when they do.
    var note: String? = nil
    /// The folder or file "Protect" adds to the protected list.
    var root: URL? = nil

    /// Shared with something outside this item, so it stays on disk after cleaning.
    var shared: Int64 { max(size - frees, 0) }

    var canClean: Bool {
        if lockedReason != nil { return false }
        if case .explain = policy { return false }
        return true
    }
    var howTo: String? {
        if case .explain(let t) = policy { return t }
        return nil
    }
    var permanentByNature: Bool {
        switch policy {
        case .permanent, .permanentOlderThan: true
        default: false
        }
    }
}

enum Catalog {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let devArtifacts: Set<String> = ["node_modules", ".next", ".nuxt", ".turbo"]
    /// Top-level folders that never hold projects. Walking them would also make macOS ask for Music, Photos or Movies access.
    static let skipAtTop: Set<String> = ["Library", "Applications", "Music", "Pictures", "Movies", "Public"]

    static func lib(_ s: String) -> URL { home.appendingPathComponent("Library/" + s) }
    static func h(_ s: String) -> URL { home.appendingPathComponent(s) }

    /// Fixed places we know about. Sizes are filled in by the scanner.
    /// Chrome's leftover app copies, minus the one the running Chrome has open. Deleting that one would stop Chrome
    /// from opening new tabs until it restarts.
    static func chromeClones(in dir: URL) -> [URL] {
        guard let all = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
              !all.isEmpty else { return [] }
        var inUse = Set<String>()
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            p.arguments = ["-a", "-c", "Google Chrome", "-Fn"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return [] }   // cannot tell which one is in use: leave them all
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            for line in out.split(separator: "\n") where line.contains("code_sign_clone.") {
                if let r = line.range(of: #"code_sign_clone\.[^/]+"#, options: .regularExpression) { inUse.insert(String(line[r])) }
            }
        }
        return all.filter { $0.lastPathComponent.hasPrefix("code_sign_clone.") && !inUse.contains($0.lastPathComponent) }
    }

    static func known() -> [Spot] {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).deletingLastPathComponent()
        var s: [Spot] = []

        // macOS
        s.append(Spot(
            id: "notif-attachments", name: "Notification images",
            detail: "Pictures that arrived with push notifications. macOS does not clear them.",
            ifRemoved: "Notifications older than 30 days may show a blank thumbnail. Nothing else changes.",
            bucket: .macOS,
            paths: [lib("Group Containers/group.com.apple.UserNotifications/Library/UserNotifications")],
            policy: .permanentOlderThan(30),
            filter: { $0.path.contains("/Attachments/") }))
        s.append(Spot(
            id: "messages-tmp", name: "Messages temporary files",
            detail: "Leftover files from sending and previewing attachments.",
            ifRemoved: "Messages is closed first. Your conversations and attachments are not touched.",
            bucket: .macOS,
            paths: [lib("Containers/com.apple.MobileSMS/Data/tmp")],
            policy: .permanent, quitBundleID: "com.apple.MobileSMS"))
        s.append(Spot(
            id: "chrome-clones", name: "Chrome update copies",
            detail: "Copies of the Chrome app that Chrome leaves behind after updates or crashes.",
            ifRemoved: "The copy Chrome is using right now is left alone. The size is what you really get back: the copies share most of their space with Chrome, so Finder shows them far bigger.",
            bucket: .macOS,
            paths: chromeClones(in: tmp.appendingPathComponent("X/com.google.Chrome.code_sign_clone")),
            policy: .permanent))

        // Rebuildable
        s.append(Spot(
            id: "npm", name: "npm cache",
            detail: "Packages npm downloaded before. Fills up again as you install things.",
            ifRemoved: "The next install downloads what it needs again.",
            bucket: .rebuildable, paths: [h(".npm/_cacache"), h(".npm/_npx")], policy: .permanent))
        s.append(Spot(
            id: "pnpm", name: "pnpm store",
            detail: "Shared copy of every package your pnpm projects use.",
            ifRemoved: "Installed projects keep working. New installs download packages again.",
            bucket: .rebuildable, paths: [lib("pnpm/store"), lib("Caches/pnpm")], policy: .permanent))
        s.append(Spot(
            id: "brew", name: "Homebrew downloads",
            detail: "Installers Homebrew already used.",
            ifRemoved: "Nothing breaks. Upgrades download again.",
            bucket: .rebuildable, paths: [lib("Caches/Homebrew")], policy: .permanent))
        s.append(Spot(
            id: "playwright", name: "Playwright browsers",
            detail: "Test browsers downloaded for automation.",
            ifRemoved: "They download again the next time a project runs Playwright.",
            bucket: .rebuildable, paths: [lib("Caches/ms-playwright")], policy: .permanent))

        // App data: explained only
        s.append(Spot(
            id: "telegram", name: "Telegram", detail: "Message database and media.",
            ifRemoved: "", bucket: .appData,
            paths: [lib("Group Containers/6N38VWS5BX.ru.keepcoder.Telegram")],
            policy: .explain("Open Telegram, then Settings, Data and Storage, Storage Usage, Clear Cache. Deleting the folder by hand can break the login.")))
        s.append(Spot(
            id: "whatsapp", name: "WhatsApp", detail: "Messages, media and logs.",
            ifRemoved: "", bucket: .appData,
            paths: [lib("Group Containers/group.net.whatsapp.WhatsApp.shared")],
            policy: .explain("Clear it from inside WhatsApp. Deleting the folder removes chat history stored on this Mac.")))
        s.append(Spot(
            id: "steam", name: "Steam and its games", detail: "Game files and download cache.",
            ifRemoved: "", bucket: .appData, paths: [lib("Application Support/Steam")],
            policy: .explain("Steam, Library, right-click a game, Manage, Uninstall. Then Steam, Settings, Downloads, Clear Download Cache.")))
        s.append(Spot(
            id: "albion", name: "Albion Online", detail: "Game files from the standalone launcher.",
            ifRemoved: "", bucket: .appData, paths: [lib("Application Support/Sandbox Interactive GmbH")],
            policy: .explain("Quit the game, then drag it from Applications to the Trash. Delete the Sandbox Interactive GmbH folder in Library, Application Support.")))
        s.append(Spot(
            id: "messages-attachments", name: "Messages attachments", detail: "Photos and files from your conversations.",
            ifRemoved: "", bucket: .appData, paths: [lib("Messages/Attachments")],
            policy: .explain("System Settings, General, Storage, Messages. Review large attachments there. Deleting them by hand leaves broken links in your conversations.")))
        s.append(Spot(
            id: "podman", name: "Podman virtual machine", detail: "Disk image for your containers and databases.",
            ifRemoved: "", bucket: .appData, paths: [h(".local/share/containers")],
            policy: .explain("Run podman image prune -a to drop unused images. Never delete the volumes, they hold your database data.")))
        return s
    }

    /// Project folders that hold things the package manager can rebuild.
    static func devFolders() -> [Spot] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: home, includingPropertiesForKeys: [.isDirectoryKey],
                                     options: [.skipsPackageDescendants]) else { return [] }
        var byProject: [String: [URL]] = [:]
        for case let url as URL in en {
            let depth = en.level
            let name = url.lastPathComponent
            if depth == 1 && (name.hasPrefix(".") || skipAtTop.contains(name)) { en.skipDescendants(); continue }
            if depth > 5 || name == ".git" { en.skipDescendants(); continue }
            if devArtifacts.contains(name) {
                en.skipDescendants()
                let rel = Array(url.pathComponents.dropFirst(home.pathComponents.count))
                let loose: Set<String> = ["Downloads", "Desktop", "Documents"]
                let top = (rel.first.map(loose.contains) == true && rel.count > 2) ? rel[0] + "/" + rel[1] : (rel.first ?? name)
                byProject[top, default: []].append(url)
            }
        }
        let busy = Running.workingDirectories()
        return byProject.map { project, urls in
            let kinds = Set(urls.map { $0.lastPathComponent }).sorted().joined(separator: " · ")
            var spot = Spot(
                id: "dev:" + project, name: project, detail: kinds,
                ifRemoved: "Run your package manager to bring them back. Stop any running dev server first.",
                bucket: .rebuildable, paths: urls, policy: .trash)
            let root = home.appendingPathComponent(project).path
            spot.root = home.appendingPathComponent(project)
            if busy.contains(where: { $0 == root || $0.hasPrefix(root + "/") }) {
                spot.lockedReason = "In use right now. Stop it to clean this."
            }
            return spot
        }
    }

    /// Large files and old installers in the folders people actually save things to.
    static func bigFiles() -> [Spot] {
        let fm = FileManager.default
        let installers: Set<String> = ["dmg", "pkg", "iso", "xip"]
        var found: [(URL, Int64)] = []
        for folder in ["Downloads", "Desktop", "Documents", "Movies"] {
            let root = h(folder)
            guard let en = fm.enumerator(at: root,
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
                options: [.skipsPackageDescendants]) else { continue }
            for case let url as URL in en {
                if url.lastPathComponent == "node_modules" || url.lastPathComponent == ".git" { en.skipDescendants(); continue }
                guard let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
                      v.isRegularFile == true, let size = v.totalFileAllocatedSize else { continue }
                let isInstaller = installers.contains(url.pathExtension.lowercased()) && size > 10_000_000
                if size > 100_000_000 || isInstaller { found.append((url, Int64(size))) }
            }
        }
        let telegram = telegramMediaSizes()
        return found.sorted { $0.1 > $1.1 }.prefix(30).map { url, size in
            var spot = Spot(
                id: "file:" + url.path, name: url.lastPathComponent,
                detail: url.deletingLastPathComponent().path.replacingOccurrences(of: home.path, with: "~"),
                ifRemoved: "Moves to the Trash, so you can put it back.",
                bucket: .yours, paths: [url], policy: .trash)
            let m = Scanner.measure(spot)
            spot.size = m.onDisk
            spot.frees = m.frees
            spot.root = url
            if spot.shared > spot.size / 10 {
                var st = stat()
                let bytes = lstat(url.path, &st) == 0 ? Int64(st.st_size) : -1
                spot.note = telegram.contains(bytes)
                    ? "Telegram keeps the same file in its media. The two share their space, so deleting only this copy frees almost nothing. Remove it in Telegram too to get the space back."
                    : "Another copy on this Mac shares this file's space, so deleting only this one frees almost nothing."
            }
            if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
                // Deleting a synced file deletes it everywhere. iCloud keeps it in Recently Deleted for 30 days only.
                let warn = "Synced with iCloud. Deleting it removes it from all your devices, not just this Mac."
                spot.note = spot.note.map { warn + " " + $0 } ?? warn
                spot.ifRemoved = "Moves to the Trash and out of iCloud on every device. You can put it back from the Trash."
            }
            if insideGitRepo(url) { spot.lockedReason = "Part of a git repository" }
            return spot
        }
    }

    /// Byte sizes of the files Telegram has downloaded, to recognise copies saved out of it.
    static func telegramMediaSizes() -> Set<Int64> {
        let base = lib("Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/appstore")
        guard let accounts = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return [] }
        var out = Set<Int64>()
        for a in accounts where a.hasPrefix("account-") {
            let media = base.path + "/" + a + "/postbox/media"
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: media) else { continue }
            for f in files {
                var st = stat()
                if lstat(media + "/" + f, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 50_000_000 { out.insert(Int64(st.st_size)) }
            }
        }
        return out
    }

    static func insideGitRepo(_ url: URL) -> Bool {
        var dir = url.deletingLastPathComponent()
        while dir.path.count > home.path.count {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return true }
            dir.deleteLastPathComponent()
        }
        return false
    }
}
