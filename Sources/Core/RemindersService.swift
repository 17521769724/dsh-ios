import Foundation
import EventKit

/// 系统「提醒事项 / 日历」：给智能体一个操作待办与日程的入口。
/// 全部走本机 EventKit，不经过任何服务器；首次使用会弹系统授权。
final class RemindersService {

    private let store = EKEventStore()

    // MARK: - 入口

    /// 把一次调用转成给模型的文本结果
    func perform(action: String, arguments: [String: Any]) async -> String {
        switch action {
        case "list_reminders":
            return await listReminders(arguments: arguments)
        case "create_reminder":
            return await createReminder(arguments: arguments)
        case "list_events":
            return await listEvents(arguments: arguments)
        case "create_event":
            return await createEvent(arguments: arguments)
        default:
            return "不支持的动作：\(action)（可用：list_reminders / create_reminder / list_events / create_event）"
        }
    }

    // MARK: - 提醒事项

    private func listReminders(arguments: [String: Any]) async -> String {
        guard await requestRemindersAccess() else {
            return "没有「提醒事项」权限，请到系统设置 → 隐私与安全性 → 提醒事项里允许本 App。"
        }
        let days = max(1, arguments["days"] as? Int ?? 7)
        let windowEnd = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
        let windowStart = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()

        let reminders = await withCheckedContinuation { (continuation: CheckedContinuation<[EKReminder], Never>) in
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            _ = store.fetchReminders(matching: predicate) { result in
                continuation.resume(returning: result ?? [])
            }
        }

        let filtered = reminders.compactMap { reminder -> (EKReminder, Date)? in
            guard let due = dueDate(of: reminder) else { return nil }
            guard due >= windowStart, due <= windowEnd else { return nil }
            return (reminder, due)
        }
        .sorted { $0.1 < $1.1 }

        guard !filtered.isEmpty else {
            return "未来 \(days) 天内没有到期的未完成提醒（含逾期 30 天内的）。"
        }
        let lines = filtered.prefix(40).map { reminder, due -> String in
            let list = reminder.calendar?.title ?? "提醒事项"
            var notes = ""
            if let text = reminder.notes, !text.isEmpty {
                notes = "（备注：\(text.prefix(60))）"
            }
            return "- \(Self.format(due))  \(reminder.title ?? "(无标题)")  ［\(list)］\(notes)"
        }
        return "共 \(filtered.count) 条未完成提醒：\n" + lines.joined(separator: "\n")
    }

    private func createReminder(arguments: [String: Any]) async -> String {
        guard let title = (arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return "请给出提醒标题（title）。"
        }
        guard await requestRemindersAccess() else {
            return "没有「提醒事项」权限，请到系统设置 → 隐私与安全性 → 提醒事项里允许本 App。"
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = (arguments["notes"] as? String)?.nonEmpty
        reminder.calendar = reminderList(named: arguments["list"] as? String)

        var dueText = ""
        if let rawDue = (arguments["due"] as? String)?.nonEmpty {
            guard let due = Self.parseDate(rawDue) else {
                return "看不懂这个时间：\(rawDue)。请用「2026-10-10 09:00」或「2026-10-10」这样的写法。"
            }
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: due
            )
            dueText = "，到期 \(Self.format(due))"
        }

        do {
            try store.save(reminder, commit: true)
            return "已添加提醒「\(title)」\(dueText)\(reminder.calendar.map { "（清单：\($0.title)）" } ?? "")。"
        } catch {
            return "添加提醒失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 日历

    private func listEvents(arguments: [String: Any]) async -> String {
        guard await requestCalendarAccess() else {
            return "没有「日历」权限，请到系统设置 → 隐私与安全性 → 日历里允许本 App。"
        }
        let days = max(1, arguments["days"] as? Int ?? 7)
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }

        guard !events.isEmpty else { return "未来 \(days) 天没有日程。" }
        let lines = events.prefix(40).map { event -> String in
            let calendar = event.calendar?.title ?? "日历"
            var location = ""
            if let place = event.location, !place.isEmpty {
                location = "  @\(place)"
            }
            return "- \(Self.format(event.startDate)) - \(Self.time(event.endDate))  \(event.title ?? "(无标题)")  ［\(calendar)］\(location)"
        }
        return "未来 \(days) 天共 \(events.count) 个日程：\n" + lines.joined(separator: "\n")
    }

    private func createEvent(arguments: [String: Any]) async -> String {
        guard let title = (arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return "请给出日程标题（title）。"
        }
        guard let rawStart = (arguments["start"] as? String)?.nonEmpty else {
            return "请给出开始时间（start），例如 2026-10-10 15:00。"
        }
        guard let start = Self.parseDate(rawStart) else {
            return "看不懂这个开始时间：\(rawStart)。请用「2026-10-10 15:00」这样的写法。"
        }
        guard await requestCalendarAccess() else {
            return "没有「日历」权限，请到系统设置 → 隐私与安全性 → 日历里允许本 App。"
        }

        var end = Calendar.current.date(byAdding: .hour, value: 1, to: start) ?? start
        if let rawEnd = (arguments["end"] as? String)?.nonEmpty {
            guard let parsed = Self.parseDate(rawEnd) else {
                return "看不懂这个结束时间：\(rawEnd)。"
            }
            end = max(parsed, start)
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.notes = (arguments["notes"] as? String)?.nonEmpty
        event.location = (arguments["location"] as? String)?.nonEmpty
        event.calendar = store.defaultCalendarForNewEvents

        do {
            try store.save(event, span: .thisEvent, commit: true)
            return "已添加日程「\(title)」：\(Self.format(start)) - \(Self.time(end))"
                + (event.calendar.map { "（日历：\($0.title)）" } ?? "") + "。"
        } catch {
            return "添加日程失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 权限

    private func requestRemindersAccess() async -> Bool {
        if #available(iOS 17.0, *) {
            return (try? await store.requestFullAccessToReminders()) ?? false
        }
        return await withCheckedContinuation { continuation in
            store.requestAccess(to: .reminder) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func requestCalendarAccess() async -> Bool {
        if #available(iOS 17.0, *) {
            return (try? await store.requestFullAccessToEvents()) ?? false
        }
        return await withCheckedContinuation { continuation in
            store.requestAccess(to: .event) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - 工具方法

    /// 按名称找提醒清单，找不到时用系统默认清单
    private func reminderList(named name: String?) -> EKCalendar? {
        guard let name, !name.isEmpty else {
            return store.defaultCalendarForNewReminders()
        }
        let matched = store.calendars(for: .reminder).first { $0.title == name }
        return matched ?? store.defaultCalendarForNewReminders()
    }

    private func dueDate(of reminder: EKReminder) -> Date? {
        guard let components = reminder.dueDateComponents else { return nil }
        return Calendar.current.date(from: components)
    }

    /// 支持 2026-10-10 09:00 / 2026-10-10 / 2026/10/10 09:00 / 2026年10月10日 09:00 / 09:00（今天）等写法
    static func parseDate(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "T", with: " ")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "年", with: "-")
            .replacingOccurrences(of: "月", with: "-")
            .replacingOccurrences(of: "日", with: "")
        let calendar = Calendar.current

        // 只有时间：按今天算
        if let time = timeComponents(from: text, calendar: calendar) {
            let today = calendar.startOfDay(for: Date())
            return calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: today)
        }

        let parts = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let datePart = parts.first else { return nil }
        let segments = datePart.split(separator: "-").compactMap { Int($0) }
        guard segments.count >= 3 else { return nil }
        var components = DateComponents()
        components.year = segments[0]
        components.month = segments[1]
        components.day = segments[2]

        if parts.count > 1, let time = timeComponents(from: parts[1], calendar: calendar) {
            components.hour = time.hour ?? 9
            components.minute = time.minute ?? 0
        } else {
            components.hour = 9
            components.minute = 0
        }
        components.second = 0
        return calendar.date(from: components)
    }

    private static func timeComponents(from text: String, calendar: Calendar) -> (hour: Int?, minute: Int?)? {
        let pieces = text.replacingOccurrences(of: "：", with: ":").split(separator: ":").compactMap { Int($0) }
        guard pieces.count >= 2, pieces[0] >= 0, pieces[0] < 24, pieces[1] >= 0, pieces[1] < 60 else { return nil }
        // 日期段里不会带冒号，所以能走到这里就说明是纯时间
        return (pieces[0], pieces[1])
    }

    static func format(_ date: Date) -> String {
        formatter.string(from: date)
    }

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private extension String {
    /// 去空白后为空时返回 nil
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}