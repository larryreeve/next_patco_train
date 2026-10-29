import Combine
import CoreLocation
import Foundation
import Darwin

enum PATCOClock {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    static func isRepeatedTime(_ date: Date) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let first = calendar.date(bySettingHour: parts.hour!, minute: parts.minute!, second: parts.second!,
                                  of: date, matchingPolicy: .strict, repeatedTimePolicy: .first)
        let last = calendar.date(bySettingHour: parts.hour!, minute: parts.minute!, second: parts.second!,
                                 of: date, matchingPolicy: .strict, repeatedTimePolicy: .last)
        return first != nil && last != nil && first != last
    }

    static func needsTimeZone(_ date: Date, relativeTo other: Date? = nil) -> Bool {
        isRepeatedTime(date) || other.map {
            calendar.timeZone.secondsFromGMT(for: date) != calendar.timeZone.secondsFromGMT(for: $0)
        } == true
    }

    static func timeZoneSuffix(_ date: Date, relativeTo other: Date? = nil) -> String {
        needsTimeZone(date, relativeTo: other) ? " \(calendar.timeZone.abbreviation(for: date) ?? "ET")" : ""
    }

    static func timeText(_ date: Date, locale: Locale = .current, relativeTo other: Date? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date) + timeZoneSuffix(date, relativeTo: other)
    }

    static func accessibleTimeText(_ date: Date, now: Date = Date(), relativeTo other: Date? = nil) -> String {
        let day: String
        if calendar.isDate(date, inSameDayAs: now) {
            day = "Today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
                  calendar.isDate(date, inSameDayAs: tomorrow) {
            day = "Tomorrow"
        } else {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateStyle = .full
            formatter.timeStyle = .none
            day = formatter.string(from: date)
        }
        return "\(day), \(timeText(date, relativeTo: other))"
    }
}
