import SwiftUI
import EventKit

/// A reminder as read from Reminders, copied out of EventKit so it can cross threads.
struct ReminderCopy: Sendable {
    var id: String
    var externalID: String?
    var title: String
    var due: Date?
    var allDay: Bool
    var list: String
    var completed: Bool
    var completedAt: Date?
}

/// A Calendar event for the Tasks tab and the island.
struct CalendarEvent: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var calendar: String
    var color: Color
    var location: String?

    var now: Bool { start <= Date() && end > Date() }
}

/// Connects Butler to Apple Reminders and Calendar on this Mac. Both are carried to the iPhone, iPad and Watch by
/// iCloud, so this is how Butler's tasks reach your other devices. Nothing goes through a server of Butler's own.
///
/// Reminders sync both ways: a task added in Butler appears in your default Reminders list, and a reminder added on
/// the iPhone appears in Butler. Calendar is read only: today's and tomorrow's events show beside your tasks.
@MainActor
final class AppleSync: ObservableObject {
    static let shared = AppleSync()

    let store = EKEventStore()
    /// Switched on by the person, and macOS has granted access.
    @Published private(set) var reminders = false
    @Published private(set) var calendar = false
    /// Today's events that have not ended, then tomorrow's.
    @Published private(set) var events: [CalendarEvent] = []
    /// macOS said no, so the switch has to be flipped in System Settings instead.
    @Published private(set) var remindersDenied = false
    @Published private(set) var calendarDenied = false

    private var changeTimer: DispatchWorkItem?
    private var dayTimer: Timer?

    private static let remindersKey = "syncReminders"
    private static let calendarKey = "showCalendar"

    private init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { AppleSync.shared.changed() }
        }
    }

    /// Picks up where the person left off at launch, without asking for anything new.
    func start() {
        let d = UserDefaults.standard
        reminders = d.bool(forKey: Self.remindersKey) && Self.granted(.reminder)
        calendar = d.bool(forKey: Self.calendarKey) && Self.granted(.event)
        remindersDenied = Self.refused(.reminder)
        calendarDenied = Self.refused(.event)
        if reminders { Tasks.shared.connectReminders() }
        if calendar { loadEvents() }
        // Roll "tomorrow" into "today" and drop finished events even when nothing in the calendar changes.
        let t = Timer(timeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { if AppleSync.shared.calendar { AppleSync.shared.loadEvents() } }
        }
        RunLoop.main.add(t, forMode: .common)
        dayTimer = t
    }

    // MARK: Switching on and off

    func setReminders(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.remindersKey)
        guard on else {
            reminders = false
            Tasks.shared.disconnectReminders()
            return
        }
        Task {
            let ok = (try? await store.requestFullAccessToReminders()) ?? false
            remindersDenied = !ok
            reminders = ok
            if ok { Tasks.shared.connectReminders() } else { UserDefaults.standard.set(false, forKey: Self.remindersKey) }
        }
    }

    func setCalendar(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.calendarKey)
        guard on else { calendar = false; events = []; return }
        Task {
            let ok = (try? await store.requestFullAccessToEvents()) ?? false
            calendarDenied = !ok
            calendar = ok
            if ok { loadEvents() } else { UserDefaults.standard.set(false, forKey: Self.calendarKey) }
        }
    }

    func openPrivacySettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)")!)
    }

    private static func granted(_ type: EKEntityType) -> Bool { EKEventStore.authorizationStatus(for: type) == .fullAccess }
    private static func refused(_ type: EKEntityType) -> Bool {
        let s = EKEventStore.authorizationStatus(for: type)
        return s == .denied || s == .restricted
    }

    /// Something changed in Reminders or Calendar, here or on another device. Changes arrive in bursts, and
    /// Butler's own saves come back through here too, so wait for the burst to settle and read once.
    private func changed() {
        changeTimer?.cancel()
        let w = DispatchWorkItem {
            MainActor.assumeIsolated {
                let s = AppleSync.shared
                if s.reminders { Tasks.shared.pullReminders() }
                if s.calendar { s.loadEvents() }
            }
        }
        changeTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    // MARK: Calendar

    func loadEvents() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: 2, to: today) else { return }
        let now = Date()
        let found = store.events(matching: store.predicateForEvents(withStart: today, end: end, calendars: nil))
            .filter { $0.endDate > now && $0.status != .canceled && !Self.declined($0) }
            .map { e in
                CalendarEvent(id: (e.eventIdentifier ?? UUID().uuidString) + "@\(e.startDate.timeIntervalSince1970)",
                              title: e.title?.isEmpty == false ? e.title : "Untitled",
                              start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                              calendar: e.calendar?.title ?? "",
                              color: Color(cgColor: e.calendar?.cgColor ?? CGColor(gray: 0.5, alpha: 1)),
                              location: e.location?.isEmpty == false ? e.location : nil)
            }
            .sorted { ($0.allDay ? 0 : 1, $0.start) < ($1.allDay ? 0 : 1, $1.start) }
        if found != events { events = found }
    }

    /// Invitations you said no to stay in the calendar but are not part of your day.
    private static func declined(_ e: EKEvent) -> Bool {
        e.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }

    /// The next timed event that has not started yet or is happening now, within the next 12 hours.
    var nextEvent: CalendarEvent? {
        let soon = Date().addingTimeInterval(12 * 3600)
        return events.first { !$0.allDay && $0.start < soon }
    }

    // MARK: Reminders

    /// Every reminder that is not done yet, across all your lists.
    func fetchOpenReminders() async -> [ReminderCopy] {
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        return await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { found in
                cont.resume(returning: (found ?? []).map(Self.copy))
            }
        }
    }

    /// A reminder Butler knows about that is no longer open: done elsewhere (returned, completed) or deleted (nil).
    func lookUp(_ id: String) -> ReminderCopy? {
        (store.calendarItem(withIdentifier: id) as? EKReminder).map(Self.copy)
    }

    /// Adds a Butler task to the default Reminders list. Returns its identifier, or nil if Reminders refused.
    func create(title: String, due: Date?) -> (id: String, external: String?, list: String)? {
        guard let list = store.defaultCalendarForNewReminders() else { return nil }
        let r = EKReminder(eventStore: store)
        r.title = title
        r.calendar = list
        apply(due, to: r)
        do { try store.save(r, commit: true) } catch { return nil }
        return (r.calendarItemIdentifier, r.calendarItemExternalIdentifier, list.title)
    }

    func setDone(_ id: String, _ done: Bool) {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder, r.isCompleted != done else { return }
        r.isCompleted = done
        try? store.save(r, commit: true)
    }

    func setDue(_ id: String, _ due: Date?) {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        apply(due, to: r)
        try? store.save(r, commit: true)
    }

    func delete(_ id: String) {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        try? store.remove(r, commit: true)
    }

    /// A due time plus an alarm at that time, which is what makes the iPhone and Watch alert too.
    private func apply(_ due: Date?, to r: EKReminder) {
        r.alarms?.forEach { r.removeAlarm($0) }
        guard let due else { r.dueDateComponents = nil; return }
        var parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        parts.timeZone = .current
        r.dueDateComponents = parts
        r.addAlarm(EKAlarm(absoluteDate: due))
    }

    /// Reminders with a day but no time are "all day". Butler gives them 9:00, when Reminders alerts for them too.
    nonisolated private static func copy(_ r: EKReminder) -> ReminderCopy {
        var due: Date?
        var allDay = false
        if let parts = r.dueDateComponents {
            var p = parts
            if p.hour == nil { allDay = true; p.hour = 9; p.minute = 0 }
            due = (p.calendar ?? Calendar.current).date(from: p)
        } else if let alarm = r.alarms?.compactMap(\.absoluteDate).min() {
            due = alarm
        }
        return ReminderCopy(id: r.calendarItemIdentifier, externalID: r.calendarItemExternalIdentifier,
                            title: r.title ?? "", due: due, allDay: allDay, list: r.calendar?.title ?? "",
                            completed: r.isCompleted, completedAt: r.completionDate)
    }
}
