import Foundation

/// All meeting dates use this locale-aware presentation. Machine timestamps
/// used for filenames and receipts deliberately remain separate.
enum MeetingDate {
    static func string(_ date: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let date else { return "Time not available" }
        let day = DateFormatter(); day.locale = locale; day.calendar = calendar
        day.doesRelativeDateFormatting = true; day.dateStyle = .short; day.timeStyle = .none
        // Relative labels are supported by DateFormatter and localized by the OS.
        if calendar.isDate(date, inSameDayAs: now) || calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: -1, to: now)!) {
            let relative = RelativeDateTimeFormatter(); relative.locale = locale; relative.dateTimeStyle = .named
            let offset = calendar.isDate(date, inSameDayAs: now) ? 0 : -1
            let label = relative.localizedString(from: DateComponents(day: offset))
            return label.prefix(1).uppercased(with: locale) + label.dropFirst() + " · " + time(date, locale: locale)
        }
        var format = Date.FormatStyle().day().month(.abbreviated)
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { format = format.year() }
        format.locale = locale; format.calendar = calendar; format.timeZone = calendar.timeZone
        return date.formatted(format) + " · " + time(date, locale: locale)
    }
    static func time(_ date: Date, locale: Locale = .current) -> String {
        let f = DateFormatter(); f.locale = locale; f.setLocalizedDateFormatFromTemplate("HHmm")
        return f.string(from: date)
    }
    static func title(_ value: String?, started: Date?) -> String {
        value.flatMap(TeamsMeetingTitle.clean) ?? "Teams call · " + (started.map { time($0) }).orUnknownTime
    }
}
private extension Optional where Wrapped == String {
    var orUnknownTime: String { self ?? "--:--" }
}
