import SwiftUI
import AppKit
import UserNotifications

struct TodoItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var done = false
    var due: Date?
    var created = Date()
    var fired = false          // the reminder has already been shown
    var completedAt: Date?
    // Set when the task is linked to Apple Reminders. Optional so lists saved before syncing existed still load.
    var reminderID: String?
    var externalID: String?
    var list: String?
    var allDay: Bool?
    /// Came from Reminders rather than being typed into Butler. Removed from Butler again if syncing is switched off.
    var imported: Bool?

    var linked: Bool { reminderID != nil }
}

/// The to-do list and its reminders. Stored as a small JSON file on this Mac. When Reminders syncing is on
/// (`AppleSync`), each task is also a reminder in Apple Reminders, which iCloud carries to your other devices.
@MainActor
final class Tasks: ObservableObject {
    static let shared = Tasks()

    @Published private(set) var items: [TodoItem] = []
    /// Reminders that have come due and have not been answered yet. The island shows the first one.
    @Published private(set) var ringing: [TodoItem] = []

    private let url: URL
    private var timer: Timer?
    /// Notifications need a real app bundle; a bare `swift run` binary has none.
    private var center: UNUserNotificationCenter? { Bundle.main.bundlePath.hasSuffix(".app") ? .current() : nil }

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Butler")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("tasks.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([TodoItem].self, from: data) {
            items = saved
        }
    }

    // MARK: Reading

    /// Open tasks: the ones with a time first (soonest on top), then the rest in the order they were added.
    var open: [TodoItem] {
        items.filter { !$0.done }.sorted {
            switch ($0.due, $1.due) {
            case let (a?, b?): return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.created < $1.created
            }
        }
    }
    var finished: [TodoItem] { items.filter(\.done).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) } }

    // MARK: Changing

    func add(_ title: String, due: Date?) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var item = TodoItem(title: t, due: due)
        link(&item)
        items.append(item)
        if due != nil { askPermission() }
        commit()
    }

    func toggle(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].done.toggle()
        items[i].completedAt = items[i].done ? Date() : nil
        if items[i].done { settle(id) }
        if let r = remote(i) { AppleSync.shared.setDone(r, items[i].done) }
        commit()
    }

    func complete(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].done = true
        items[i].completedAt = Date()
        settle(id)
        if let r = remote(i) { AppleSync.shared.setDone(r, true) }
        commit()
    }

    func snooze(_ id: UUID, minutes: Int) { setDue(id, Date().addingTimeInterval(Double(minutes) * 60)) }

    func setDue(_ id: UUID, _ date: Date?) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].due = date
        items[i].fired = false
        items[i].allDay = nil
        if date != nil { askPermission() }
        settle(id)
        if let r = remote(i) { AppleSync.shared.setDue(r, date) }
        commit()
    }

    func delete(_ id: UUID) {
        if let i = items.firstIndex(where: { $0.id == id }), let r = remote(i) { AppleSync.shared.delete(r) }
        items.removeAll { $0.id == id }
        settle(id)
        commit()
    }

    /// Takes finished tasks off Butler's list. Their reminders stay in Reminders, ticked off, as Reminders keeps them.
    func clearFinished() {
        items.removeAll { $0.done }
        commit()
    }

    /// The reminder was answered, so drop it from the island and from Notification Centre.
    private func settle(_ id: UUID) {
        ringing.removeAll { $0.id == id }
        center?.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }

    // MARK: Apple Reminders

    /// The reminder to update for this task, when syncing is on.
    private func remote(_ i: Int) -> String? { AppleSync.shared.reminders ? items[i].reminderID : nil }

    /// Gives a task its twin in Reminders, if syncing is on and it has none yet.
    private func link(_ item: inout TodoItem) {
        guard AppleSync.shared.reminders, item.reminderID == nil, !item.done,
              let r = AppleSync.shared.create(title: item.title, due: item.due) else { return }
        item.reminderID = r.id
        item.externalID = r.external
        item.list = r.list
    }

    /// Syncing was switched on: send Butler's own open tasks to Reminders once, then read everything back.
    func connectReminders() {
        for i in items.indices where items[i].reminderID == nil && !items[i].done { link(&items[i]) }
        commit()
        pullReminders()
    }

    /// Syncing was switched off: keep the tasks typed into Butler, drop the ones that only came from Reminders.
    /// They are still in Reminders, untouched.
    func disconnectReminders() {
        items.removeAll { $0.imported == true }
        commit()
    }

    /// Brings Butler's list in line with Reminders. Reminders wins: it is where changes from the iPhone land.
    func pullReminders() {
        Task {
            let open = await AppleSync.shared.fetchOpenReminders()
            guard AppleSync.shared.reminders else { return }
            merge(open)
        }
    }

    private func merge(_ open: [ReminderCopy]) {
        let now = Date()
        var seen = Set<String>()
        var changed = false
        for r in open {
            seen.insert(r.id)
            if let i = items.firstIndex(where: { $0.reminderID == r.id || ($0.reminderID != nil && $0.externalID != nil && $0.externalID == r.externalID) }) {
                var it = items[i]
                it.reminderID = r.id
                it.title = r.title.isEmpty ? it.title : r.title
                it.list = r.list
                it.allDay = r.allDay ? true : nil
                if it.done { it.done = false; it.completedAt = nil }
                if it.due != r.due { it.due = r.due; it.fired = (r.due ?? .distantFuture) <= now }
                if it != items[i] { items[i] = it; changed = true }
            } else {
                // Reminders already overdue when they arrive are not rung all at once; they show in red instead.
                var it = TodoItem(title: r.title.isEmpty ? "Untitled" : r.title, due: r.due)
                it.fired = (r.due ?? .distantFuture) <= now
                it.reminderID = r.id
                it.externalID = r.externalID
                it.list = r.list
                it.allDay = r.allDay ? true : nil
                it.imported = true
                items.append(it)
                changed = true
            }
        }
        // Linked tasks that are no longer open in Reminders were either ticked off elsewhere or deleted there.
        for it in items where it.reminderID != nil && !it.done && !seen.contains(it.reminderID!) {
            guard let i = items.firstIndex(where: { $0.id == it.id }) else { continue }
            if let r = AppleSync.shared.lookUp(it.reminderID!) {
                if r.completed {
                    items[i].done = true
                    items[i].completedAt = r.completedAt ?? now
                    settle(it.id)
                    changed = true
                }
            } else {
                items.remove(at: i)
                settle(it.id)
                changed = true
            }
        }
        if changed { commit() }
    }

    // MARK: Ringing

    func start() {
        guard timer == nil else { return }
        tick()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        syncNotifications()
    }

    private func tick() {
        let now = Date()
        var fresh = false
        for i in items.indices where !items[i].done && !items[i].fired {
            if let d = items[i].due, d <= now {
                items[i].fired = true
                ringing.append(items[i])
                fresh = true
            }
        }
        if fresh {
            NSSound(named: "Glass")?.play()
            commit()
        }
    }

    private func commit() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: url, options: .atomic) }
        syncNotifications()
    }

    private func askPermission() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Backup for when Butler is not running. While it is running the island answers at the exact time and these
    /// are cancelled first, so the delivery below lands 20 seconds late on purpose.
    private func syncNotifications() {
        guard let c = center else { return }
        c.removeAllPendingNotificationRequests()
        let reminders = AppleSync.shared.reminders
        for it in items where !it.done && !it.fired {
            // Reminders alerts for its own items on every device, so Butler does not add a second notification.
            if reminders && it.linked { continue }
            guard let due = it.due else { continue }
            let when = due.addingTimeInterval(20)
            guard when > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = it.title
            content.body = "Reminder from Butler"
            content.sound = .default
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: when)
            c.add(UNNotificationRequest(identifier: it.id.uuidString, content: content,
                                        trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
        }
    }
}
