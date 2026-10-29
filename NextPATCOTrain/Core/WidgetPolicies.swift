import Combine
import CoreLocation
import Foundation
import Darwin

enum WidgetDepartureDay {
    static func groupLabel(for date: Date, previousDeparture: Date?, relativeTo reference: Date,
                           timeZone: TimeZone) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if let previousDeparture, calendar.isDate(date, inSameDayAs: previousDeparture) { return nil }
        return label(for: date, relativeTo: reference, timeZone: timeZone)
    }

    static func label(for date: Date, relativeTo reference: Date, timeZone: TimeZone) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: reference) { return nil }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: reference),
           calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}

enum WidgetReachabilitySettings {
    static let enabledKey = "widgetReachabilityEnabled"
    static let suiteName = "group.com.rhome.patconext"
    static var isEnabled: Bool {
        isEnabled(defaults: UserDefaults(suiteName: suiteName) ?? .standard)
    }
    static func isEnabled(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey)
    }
}

enum WidgetActionProgress {
    enum Kind: String, Codable { case reverse, mode, refresh }
    struct Ticket: Codable, Equatable {
        let id: UUID
        let kind: Kind
        let startedAt: Date
        let expiresAt: Date

        func isActive(at date: Date) -> Bool { date >= startedAt && date < expiresAt }

        func permitsWork(reserving seconds: TimeInterval = 0, at date: Date = Date()) -> Bool {
            isActive(at: date) && date.addingTimeInterval(max(0, seconds)) < expiresAt.addingTimeInterval(-6)
        }
    }

    private static func locked<T>(directory: URL?, body: (URL) -> T?) -> T? {
        guard let root = directory ?? FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetReachabilitySettings.suiteName) else { return nil }
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { return nil }
        let fd = open(root.appendingPathComponent("widget-action.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return nil }
        defer { flock(fd, LOCK_UN) }
        return body(root.appendingPathComponent("widget-action.json"))
    }

    private static func read(_ file: URL) -> Ticket? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Ticket.self, from: $0) }
    }

    static func current(now: Date = Date(), directory: URL? = nil) -> Ticket? {
        locked(directory: directory) { file in
            guard let ticket = read(file), ticket.isActive(at: now) else { return nil }
            return ticket
        }
    }

    static func begin(_ kind: Kind, now: Date? = nil, directory: URL? = nil) -> Ticket? {
        locked(directory: directory) { file in
            // Sample after acquiring the lock: another process may have just started work.
            let now = now ?? Date()
            guard read(file)?.isActive(at: now) != true else { return nil }
            let ticket = Ticket(id: UUID(), kind: kind, startedAt: now, expiresAt: now.addingTimeInterval(30))
            do {
                try JSONEncoder().encode(ticket).write(to: file, options: .atomic)
                return ticket
            } catch { return nil }
        }
    }

    static func finish(_ ticket: Ticket, directory: URL? = nil) {
        let _: Bool? = locked(directory: directory) { file in
            guard read(file)?.id == ticket.id else { return false }
            do { try FileManager.default.removeItem(at: file); return true }
            catch { return false }
        }
    }
}

enum WidgetDepartureSelection {
    static func timelinePayload<T: Identifiable>(_ departures: [T], isRecommended: (T) -> Bool) -> [T] {
        let compact = prioritized(departures, limit: 3, isRecommended: isRecommended)
        let ids = Set(departures.prefix(10).map(\.id) + compact.map(\.id))
        return departures.filter { ids.contains($0.id) }
    }

    static func select<T>(_ departures: [T], limit: Int) -> [T] {
        guard limit > 0 else { return [] }
        return Array(departures.prefix(limit))
    }

    static func prioritized<T>(_ departures: [T], limit: Int,
                               isRecommended: (T) -> Bool) -> [T] {
        guard limit > 0 else { return [] }
        guard let index = departures.firstIndex(where: isRecommended) else {
            return select(departures, limit: limit)
        }
        // Keep a consecutive window so the train just before the recommendation is never skipped.
        let start = limit > 1 ? max(0, index - 1) : index
        return Array(departures[start...].prefix(limit))
    }
}

enum WidgetTimelinePolicy {
    static func shouldAttemptLocation(lastAttempt: Date?, now: Date, manual: Bool,
                                      lastSuccessfulLocation: Date? = nil) -> Bool {
        guard !manual, let lastAttempt else { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        // Bound automatic retries even when WidgetKit invokes multiple timelines close together.
        let succeeded = lastSuccessfulLocation.map { $0 >= lastAttempt && $0 <= now } ?? false
        return elapsed < 0 || elapsed >= (succeeded ? 180 : 300)
    }

    static func unconfirmedTimesByDay(schedules: [PATCOSpecialSchedule], dates: [Date]) -> [Date: Bool] {
        let days = Set(dates.map { PATCOClock.calendar.startOfDay(for: $0) })
        return Dictionary(uniqueKeysWithValues: days.map { day in
            (day, schedules.contains { $0.hasUnconfirmedTimes(on: day) })
        })
    }

    static func hasUsableGuidance(location: CLLocation?, at date: Date) -> Bool {
        location.map { LocationGuidancePolicy.isUsable($0, maxAge: 180, now: date) } ?? false
    }

    static func lockScreenRefresh(now: Date, trackingDeadline: Date?, hasActiveTrip: Bool) -> Date {
        let tracking = trackingDeadline.map { $0 > now && $0.timeIntervalSince(now) <= 7200 } ?? false
        return now.addingTimeInterval(tracking || hasActiveTrip ? 600 : 1800)
    }
    static func nextRefresh(now: Date, hasService: Bool, hasGuidance: Bool, locationTimestamp: Date?,
                            estimateTimestamp: Date? = nil,
                            reachabilityEnabled: Bool = true) -> (date: Date, reason: String) {
        guard hasService else { return (now.addingTimeInterval(1800), "No upcoming service") }
        guard reachabilityEnabled else { return (now.addingTimeInterval(900), "Schedule-only refresh") }
        guard hasGuidance, let locationTimestamp,
              (0...180).contains(now.timeIntervalSince(locationTimestamp)) else {
            return (now.addingTimeInterval(300), "Reachability unavailable; bounded retry")
        }
        // Future entries still expire stale guidance if WidgetKit delays this request.
        let expiry = min(locationTimestamp.addingTimeInterval(181),
                         estimateTimestamp?.addingTimeInterval(300) ?? .distantFuture)
        return (max(now.addingTimeInterval(60), expiry), "Reachability freshness refresh")
    }
    static func entryDates(now: Date, departures: [Date], guidanceExpiration: Date? = nil) -> [Date] {
        let end = now.addingTimeInterval(24 * 60 * 60)
        let changes = departures.map { $0.addingTimeInterval(1) }.filter { $0 > now && $0 <= end }
        let earlyUpdates = (0...15).map { now.addingTimeInterval(Double($0 * 60)) }
        let fallbackUpdates = (1...24).map { now.addingTimeInterval(Double($0 * 3600)) }
        let expiry = guidanceExpiration.map { $0 > now && $0 <= end ? [$0] : [] } ?? []
        let calendar = PATCOClock.calendar
        let startOfDay = calendar.startOfDay(for: now)
        let midnights = (1...2).compactMap { calendar.date(byAdding: .day, value: $0, to: startOfDay) }
            .filter { $0 > now && $0 <= end }
        return Array(Set(changes + earlyUpdates + fallbackUpdates + expiry + midnights)).sorted()
    }
}

enum ScheduledDeparturePresentation {
    static func staleDate(departureDate: Date, arrivalDate: Date, now: Date = Date()) -> Date {
        now < departureDate ? departureDate : ScheduledTripExpiration.deadline(arrivalDate: arrivalDate)
    }

    static func hasDeparted(departureDate: Date, isStale: Bool, now: Date = Date()) -> Bool {
        isStale || now >= departureDate
    }
}

enum SharedWidgetRouteMemory {
    static func returnDestination(arrivingAt: String, currentOrigin: String, savedOrigin: String?, savedDestination: String?) -> String {
        if arrivingAt == savedDestination, let savedOrigin { return savedOrigin }
        if arrivingAt == savedOrigin, let savedDestination { return savedDestination }
        return currentOrigin
    }

}
