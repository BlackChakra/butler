import Foundation

enum Remind {
    /// "call Sam tomorrow at 5pm" becomes the title "call Sam" and tomorrow at 17:00.
    static func parse(_ text: String) -> (title: String, due: Date?) {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var found: (range: NSRange, date: Date)?

        // "in 30 minutes", "in 2 hours", "in 3 days": the system detector does not read these.
        if let re = try? NSRegularExpression(pattern: #"\bin\s+(\d{1,3})\s*(min(?:ute)?s?|h(?:ou)?rs?|days?)\b"#, options: .caseInsensitive),
           let m = re.firstMatch(in: text, range: full) {
            let n = Double(ns.substring(with: m.range(at: 1))) ?? 0
            let unit = ns.substring(with: m.range(at: 2)).lowercased()
            let secs = unit.hasPrefix("m") ? 60.0 : (unit.hasPrefix("h") ? 3600.0 : 86400.0)
            found = (m.range, Date().addingTimeInterval(n * secs))
        } else if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
                  let m = det.firstMatch(in: text, range: full), let date = m.date {
            // Plain words like "may" or "march" are not a time; ask for a digit or an unmistakable word.
            let hit = ns.substring(with: m.range).lowercased()
            let words = ["tomorrow", "tonight", "today", "noon", "midnight", "morning", "evening", "afternoon"]
            if hit.contains(where: \.isNumber) || words.contains(where: hit.contains) { found = (m.range, date) }
        }

        guard let f = found, f.date > Date() else { return (text, nil) }
        var title = ns.replacingCharacters(in: f.range, with: "")
        title = title.replacingOccurrences(of: #"\s+(at|on|by|in|before|for|until)\s*$"#, with: "",
                                           options: [.regularExpression, .caseInsensitive])
        title = title.trimmingCharacters(in: .whitespaces)
        return (title.isEmpty ? text : title, f.date)
    }

    static func presets() -> [(name: String, date: Date)] {
        let cal = Calendar.current
        let now = Date()
        var out: [(String, Date)] = [
            ("In 15 minutes", now.addingTimeInterval(15 * 60)),
            ("In an hour", now.addingTimeInterval(3600)),
        ]
        if let eve = cal.date(bySettingHour: 18, minute: 0, second: 0, of: now), eve > now.addingTimeInterval(1800) {
            out.append(("This evening", eve))
        }
        if let tmr = cal.date(byAdding: .day, value: 1, to: now), let nine = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tmr) {
            out.append(("Tomorrow morning", nine))
        }
        return out
    }

    /// "Today, 17:00", "Fri, 09:30", "12 Dec, 08:00". All-day reminders from Reminders show just the day.
    static func label(_ d: Date, allDay: Bool = false) -> String {
        let cal = Calendar.current
        let day: String
        if cal.isDateInToday(d) { day = "Today" }
        else if cal.isDateInTomorrow(d) { day = "Tomorrow" }
        else if let week = cal.date(byAdding: .day, value: 6, to: Date()), d < week, d > Date() {
            day = d.formatted(.dateTime.weekday(.abbreviated))
        } else { day = d.formatted(.dateTime.day().month(.abbreviated)) }
        return allDay ? day : "\(day), \(d.formatted(date: .omitted, time: .shortened))"
    }
}
