import SwiftUI

struct TasksView: View {
    @ObservedObject var tasks: Tasks
    @ObservedObject var sync = AppleSync.shared
    @State private var draft = ""
    @State private var picked: Date?
    @State private var ignoreDetected = false
    @State private var pickOpen = Debug.picker
    @State private var pickDate = Date().addingTimeInterval(3600)
    @State private var showDone = false
    @FocusState private var focused: Bool

    private var parsed: (title: String, due: Date?) { Remind.parse(draft) }
    private var due: Date? { picked ?? (ignoreDetected ? nil : parsed.due) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                header
                addBar
            }
            .padding(.horizontal, 36).padding(.top, 44).padding(.bottom, 22)

            Divider().opacity(0.5)

            if tasks.items.isEmpty && sync.events.isEmpty {
                Spacer()
                Text("Nothing on your list").font(.system(size: 15)).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        if !sync.events.isEmpty { ScheduleSection(events: sync.events) }
                        VStack(spacing: 0) {
                            ForEach(tasks.open) { item in
                                TaskRow(tasks: tasks, item: item, showList: showLists)
                                if item.id != tasks.open.last?.id { Divider().padding(.leading, 34).opacity(0.5) }
                            }
                        }
                        if !tasks.finished.isEmpty { finishedSection }
                    }
                    .padding(.horizontal, 36).padding(.vertical, 24)
                }
            }
        }
        .onAppear { focused = true }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tasks.open.isEmpty ? "Clear" : "\(tasks.open.count)")
                    .font(.system(size: 54, weight: .semibold)).monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: tasks.open.count)
                Text(subtitle).font(.system(size: 15)).foregroundStyle(.secondary)
            }
            Spacer()
            SyncMenu(sync: sync).padding(.top, 14)
        }
    }

    /// List names only help once tasks come from more than one Reminders list.
    private var showLists: Bool { Set(tasks.open.compactMap(\.list)).count > 1 }

    private var subtitle: String {
        if tasks.open.isEmpty { return "Nothing to do" }
        if let next = tasks.open.first(where: { $0.due != nil }), let d = next.due {
            let overdue = tasks.open.filter { ($0.due ?? .distantFuture) < Date() }.count
            return overdue > 0 ? "to do · \(overdue) overdue" : "to do · next \(Remind.label(d, allDay: next.allDay == true).lowercased())"
        }
        return "to do"
    }

    // MARK: Add

    private var addBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus").foregroundStyle(.secondary).font(.system(size: 13, weight: .semibold))
            TextField("Add a task. Try “call Sam tomorrow at 5pm”", text: $draft)
                .textFieldStyle(.plain).font(.system(size: 15))
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: draft) { _, new in if new.isEmpty { ignoreDetected = false } }
            if let d = due { chip(d) }
            Menu {
                ForEach(Remind.presets(), id: \.name) { p in Button(p.name) { picked = p.date } }
                Divider()
                Button("Pick a time…") {
                    pickDate = Date().addingTimeInterval(3600)
                    pickOpen = true
                }
                if due != nil { Button("No reminder") { picked = nil; ignoreDetected = true } }
            } label: {
                Image(systemName: due == nil ? "bell" : "bell.fill")
                    .foregroundStyle(due == nil ? Color.secondary : Color.orange)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .popover(isPresented: $pickOpen, arrowEdge: .bottom) {
                VStack(spacing: 14) {
                    DatePicker("", selection: $pickDate, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                        .datePickerStyle(.graphical).labelsHidden()
                    HStack {
                        Text("Time").font(.system(size: 13)).foregroundStyle(.secondary)
                        Spacer()
                        DatePicker("", selection: $pickDate, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.stepperField).labelsHidden()
                    }
                    Button { picked = pickDate; pickOpen = false } label: {
                        Text("Remind me").font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pickDate <= Date())
                }
                .padding(18).frame(width: 300).fixedSize()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func chip(_ d: Date) -> some View {
        HStack(spacing: 5) {
            Text(Remind.label(d)).font(.system(size: 12, weight: .medium))
            Button { picked = nil; ignoreDetected = true } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Color.orange)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(Color.orange.opacity(0.14)))
    }

    private func commit() {
        let title = (picked == nil && !ignoreDetected && parsed.due != nil) ? parsed.title : draft
        withAnimation(.easeOut(duration: 0.25)) { tasks.add(title, due: due) }
        draft = ""; picked = nil; ignoreDetected = false
    }

    // MARK: Done

    private var finishedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button { withAnimation(.easeOut(duration: 0.2)) { showDone.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(showDone ? 90 : 0))
                        Text("Done").font(.system(size: 15, weight: .semibold))
                        Text("\(tasks.finished.count)").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if showDone { Button("Clear", action: tasks.clearFinished).buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary) }
            }
            if showDone {
                VStack(spacing: 0) {
                    ForEach(tasks.finished) { item in
                        TaskRow(tasks: tasks, item: item, showList: false)
                        if item.id != tasks.finished.last?.id { Divider().padding(.leading, 34).opacity(0.5) }
                    }
                }
            }
        }
    }
}

private struct TaskRow: View {
    @ObservedObject var tasks: Tasks
    var item: TodoItem
    var showList: Bool
    @State private var hover = false

    private var overdue: Bool { !item.done && (item.due ?? .distantFuture) < Date() }

    var body: some View {
        HStack(spacing: 12) {
            Button { withAnimation(.easeOut(duration: 0.2)) { tasks.toggle(item.id) } } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(item.done ? Color.green : Color.primary.opacity(0.25))
                    .frame(width: 22)
            }
            .buttonStyle(.plain)

            Text(item.title).font(.system(size: 14))
                .strikethrough(item.done)
                .foregroundStyle(item.done ? Color.secondary : Color.primary)
                .lineLimit(2)
            if showList, let list = item.list {
                Text(list).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }

            Spacer(minLength: 12)

            if let d = item.due, !item.done {
                HStack(spacing: 4) {
                    Image(systemName: "bell.fill").font(.system(size: 9))
                    Text(Remind.label(d, allDay: item.allDay == true)).font(.system(size: 12)).monospacedDigit()
                }
                .foregroundStyle(overdue ? Color.red : Color.secondary)
            }
            if hover {
                Button { withAnimation(.easeOut(duration: 0.2)) { tasks.delete(item.id) } } label: {
                    Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hover ? 0.04 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            if !item.done {
                Menu("Remind me") {
                    ForEach(Remind.presets(), id: \.name) { p in Button(p.name) { tasks.setDue(item.id, p.date) } }
                    if item.due != nil { Divider(); Button("No reminder") { tasks.setDue(item.id, nil) } }
                }
            }
            Button(item.linked && AppleSync.shared.reminders ? "Delete from Reminders Too" : "Delete", role: .destructive) {
                tasks.delete(item.id)
            }
        }
    }
}

// MARK: Reminders and Calendar

/// One quiet control in the corner: connect Reminders and Calendar, or switch either off again.
private struct SyncMenu: View {
    @ObservedObject var sync: AppleSync

    var body: some View {
        Menu {
            Toggle("Sync with Reminders", isOn: Binding(get: { sync.reminders }, set: { sync.setReminders($0) }))
            Toggle("Show Calendar", isOn: Binding(get: { sync.calendar }, set: { sync.setCalendar($0) }))
            if sync.remindersDenied || sync.calendarDenied {
                Divider()
                if sync.remindersDenied { Button("Allow Reminders in System Settings…") { sync.openPrivacySettings("Reminders") } }
                if sync.calendarDenied { Button("Allow Calendar in System Settings…") { sync.openPrivacySettings("Calendars") } }
            }
            Divider()
            Text("Tasks reach your iPhone through Reminders and iCloud")
        } label: {
            if sync.reminders || sync.calendar {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
            } else {
                Label("Connect Reminders & Calendar", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(sync.reminders ? "Syncing with Reminders" : "Sync with Reminders and Calendar")
    }
}

/// Today's remaining events and tomorrow's, from Calendar. Read only.
private struct ScheduleSection: View {
    var events: [CalendarEvent]

    var body: some View {
        let cal = Calendar.current
        let today = events.filter { cal.isDateInToday($0.start) || ($0.start < Date() && $0.end > Date()) }
        let tomorrow = events.filter { !today.contains($0) && cal.isDateInTomorrow($0.start) }
        VStack(alignment: .leading, spacing: 18) {
            if !today.isEmpty { day("Today", today) }
            if !tomorrow.isEmpty { day("Tomorrow", tomorrow) }
        }
    }

    private func day(_ title: String, _ list: [CalendarEvent]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(list) { e in EventRow(event: e) }
            }
        }
    }
}

private struct EventRow: View {
    var event: CalendarEvent

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(event.color).frame(width: 4, height: 28)
                .padding(.leading, 9).padding(.trailing, 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(size: 14)).lineLimit(1)
                if let place = event.location {
                    Text(place).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if event.now && !event.allDay {
                Text("Now").font(.system(size: 11, weight: .semibold)).foregroundStyle(event.color)
            }
            Text(time).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 6).padding(.trailing, 4)
    }

    private var time: String {
        if event.allDay { return "All day" }
        let f: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
        return "\(f(event.start)) – \(f(event.end))"
    }
}
