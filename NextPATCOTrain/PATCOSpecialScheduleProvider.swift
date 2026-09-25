import Combine
import Foundation
import PDFKit

@MainActor
final class PATCOSpecialScheduleProvider: ObservableObject {
    @Published private(set) var specialSchedule: PATCOSpecialSchedule?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?

    private let schedulesURL = URL(string: "https://www.ridepatco.org/schedules/schedules.asp")!
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return calendar
    }

    func refresh(for date: Date = Date(), force: Bool = false) {
        Task {
            await refreshNow(for: date, force: force)
        }
    }

    func refreshNow(for date: Date = Date(), force: Bool = false) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let result = await SharedSpecialScheduleCache.refreshIfNeeded(
            from: date,
            calendar: calendar,
            force: force
        )
        specialSchedule = result.schedules.first {
            calendar.isDate($0.serviceDate, inSameDayAs: date)
        }
        lastUpdated = result.lastChecked
        if result.failed {
            errorMessage = "Unable to load PATCO special schedule"
        }
    }
}

struct PATCOSpecialScheduleLoader {
    private static let schedulesURL = URL(string: "https://www.ridepatco.org/schedules/schedules.asp")!

    static func specialSchedule(for date: Date, calendar: Calendar) async throws -> PATCOSpecialSchedule? {
        try await specialSchedules(for: [date], calendar: calendar).first
    }

    static func specialSchedules(
        for dates: [Date],
        calendar: Calendar,
        optionalDates: [Date] = []
    ) async throws -> [PATCOSpecialSchedule] {
        var request = URLRequest(url: schedulesURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw URLError(.badServerResponse)
        }

        let html = String(decoding: data, as: UTF8.self)
        let links = specialScheduleLinks(from: html, baseURL: schedulesURL, calendar: calendar)
        var schedules: [PATCOSpecialSchedule] = []
        for date in dates {
            guard let link = links.first(where: { calendar.isDate($0.date, inSameDayAs: date) }) else {
                continue
            }
            schedules.append(try await specialSchedule(from: link)!)
        }
        for date in optionalDates {
            guard let link = links.first(where: { calendar.isDate($0.date, inSameDayAs: date) }),
                  let schedule = try? await specialSchedule(from: link) else {
                continue
            }
            schedules.append(schedule)
        }
        return schedules
    }

    static func specialScheduleLink(for date: Date, calendar: Calendar) async throws -> SpecialScheduleLink? {
        var request = URLRequest(url: schedulesURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw URLError(.badServerResponse)
        }

        let html = String(decoding: data, as: UTF8.self)
        guard let link = specialScheduleLinks(from: html, baseURL: schedulesURL, calendar: calendar)
            .first(where: { calendar.isDate($0.date, inSameDayAs: date) }) else {
            return nil
        }

        return link
    }

    static func specialSchedule(from link: SpecialScheduleLink?) async throws -> PATCOSpecialSchedule? {
        guard let link else { return nil }

        let pdfRequest = URLRequest(url: link.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18)
        let (pdfData, pdfResponse) = try await URLSession.shared.data(for: pdfRequest)
        guard let pdfHTTPResponse = pdfResponse as? HTTPURLResponse, 200..<300 ~= pdfHTTPResponse.statusCode else {
            throw URLError(.badServerResponse)
        }

        return try parseSpecialSchedulePDF(
            data: pdfData,
            title: link.title,
            serviceDate: link.date,
            sourceURL: link.url
        )
    }

    static func specialScheduleLinks(from html: String, baseURL: URL, calendar: Calendar) -> [SpecialScheduleLink] {
        let pattern = #"<a\s+[^>]*href\s*=\s*["']([^"']+\.pdf)["'][^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html) else {
                return nil
            }

            let title = String(html[titleRange])
                .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                .htmlDecoded
                .trimmed
            guard let date = dateFromSpecialScheduleTitle(title, calendar: calendar),
                  let url = URL(string: String(html[hrefRange]), relativeTo: baseURL)?.absoluteURL else {
                return nil
            }

            return SpecialScheduleLink(title: title, date: date, url: url)
        }
    }

    private static func dateFromSpecialScheduleTitle(_ title: String, calendar: Calendar) -> Date? {
        let pattern = #"^[A-Za-z]+,\s+[A-Za-z]+\s+\d{1,2},\s+\d{4}"#
        guard let range = title.range(of: pattern, options: .regularExpression) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter.date(from: String(title[range]))
    }

    static func parseSpecialSchedulePDF(data: Data, title: String, serviceDate: Date, sourceURL: URL) throws -> PATCOSpecialSchedule {
        guard let document = PDFDocument(data: data) else {
            throw URLError(.cannotDecodeContentData)
        }

        let text = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")

        let groups = groupedScheduleRows(from: text)
        guard groups.count >= 2 else {
            throw URLError(.cannotParseResponse)
        }

        let westboundTrips = groups[0].compactMap { normalizedTripTimes(from: $0) }
            .map { PATCOSpecialSchedule.ScheduledTrip(directionId: 0, stopTimes: $0) }
        let eastboundTrips = groups[1].compactMap { normalizedTripTimes(from: $0) }
            .map { PATCOSpecialSchedule.ScheduledTrip(directionId: 1, stopTimes: $0) }
        let trips = eastboundTrips + westboundTrips

        guard !trips.isEmpty else {
            throw URLError(.cannotParseResponse)
        }

        return PATCOSpecialSchedule(title: title, serviceDate: serviceDate, sourceURL: sourceURL, trips: trips)
    }

    static func groupedScheduleRows(from text: String) -> [[String]] {
        let rows = text
            .components(separatedBy: .newlines)
            .map { scheduleTokens(in: $0) }

        var groups: [[String]] = []
        var currentGroup: [String] = []

        for row in rows {
            if row.count == 14 {
                currentGroup.append(row.joined(separator: " "))
            } else if !currentGroup.isEmpty {
                groups.append(currentGroup)
                currentGroup = []
            }
        }

        if !currentGroup.isEmpty {
            groups.append(currentGroup)
        }

        return groups.filter { !$0.isEmpty }
    }

    private static func scheduleTokens(in line: String) -> [String] {
        let pattern = "\\b\\d{1,2}:\\d{2}\\s*[AP]\\b|[\u{00E0}\u{2192}]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.matches(in: line, range: range).compactMap { match in
            guard let tokenRange = Range(match.range, in: line) else {
                return nil
            }

            let token = String(line[tokenRange]).replacingOccurrences(of: " ", with: "")
            return token == "\u{00E0}" || token == "\u{2192}" ? token : token.uppercased()
        }
    }

    static func normalizedTripTimes(from row: String) -> [String]? {
        let tokens = scheduleTokens(in: row)
        guard tokens.count == 14 else { return nil }

        var previousMinutes: Int?
        var normalizedTimes: [String] = []

        for token in tokens {
            if token == "\u{00E0}" || token == "\u{2192}" {
                normalizedTimes.append("")
                continue
            }
            guard var minutes = minutesAfterMidnight(from: token) else {
                return nil
            }

            if let previousMinutes, minutes < previousMinutes {
                minutes += 24 * 60
            }

            previousMinutes = minutes
            normalizedTimes.append(String(format: "%02d:%02d:00", minutes / 60, minutes % 60))
        }

        return normalizedTimes
    }

    private static func minutesAfterMidnight(from token: String) -> Int? {
        let suffix = token.suffix(1)
        let time = token.dropLast()
        let pieces = time.split(separator: ":").compactMap { Int($0) }
        guard pieces.count == 2 else { return nil }

        var hour = pieces[0] % 12
        if suffix == "P" {
            hour += 12
        }

        return hour * 60 + pieces[1]
    }
}

struct SpecialScheduleLink {
    let title: String
    let date: Date
    let url: URL
}

enum SharedSpecialScheduleCache {
    private static let suiteName = "group.com.rhome.patconext"
    private static let schedulesKey = "cachedSpecialSchedules"
    private static let lastCheckKeyPrefix = "specialScheduleLastCheck."
    private static let lastCheckFailedKeyPrefix = "specialScheduleLastCheckFailed."
    private static let refreshInterval: TimeInterval = 60 * 60

    struct RefreshResult {
        let schedules: [PATCOSpecialSchedule]
        let lastChecked: Date?
        let failed: Bool
    }

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func save(_ schedules: [PATCOSpecialSchedule]) {
        let merged = deduplicated(allSchedules() + schedules)
        guard !merged.isEmpty,
              let data = try? JSONEncoder().encode(merged) else {
            return
        }

        defaults.set(data, forKey: schedulesKey)
    }

    static func schedules(matching dates: [Date], calendar: Calendar) -> [PATCOSpecialSchedule] {
        allSchedules().filter { schedule in
            dates.contains { calendar.isDate(schedule.serviceDate, inSameDayAs: $0) }
        }
    }

    static func refreshIfNeeded(
        from date: Date,
        calendar: Calendar,
        force: Bool = false
    ) async -> RefreshResult {
        let dates = departureWindowDates(from: date, calendar: calendar)
        let previousDate = calendar.date(byAdding: .day, value: -1, to: date)
        let cachedDates = [previousDate].compactMap { $0 } + dates
        let cached = schedules(matching: cachedDates, calendar: calendar)
        let dayKey = dateKey(for: date, calendar: calendar)
        let lastCheckKey = lastCheckKeyPrefix + dayKey
        let lastCheckFailedKey = lastCheckFailedKeyPrefix + dayKey
        let checkedAt = Date()
        let lastCheck = defaults.object(forKey: lastCheckKey) as? Date
        let checkIsRecent = lastCheck.map { checkedAt.timeIntervalSince($0) >= 0 && checkedAt.timeIntervalSince($0) < refreshInterval } ?? false

        guard force || !checkIsRecent else {
            return RefreshResult(
                schedules: cached,
                lastChecked: lastCheck,
                failed: defaults.bool(forKey: lastCheckFailedKey)
            )
        }

        // Record the attempt before networking so the app and widget do not start
        // duplicate checks when they wake at nearly the same time.
        defaults.set(checkedAt, forKey: lastCheckKey)
        do {
            var optionalDates: [Date] = []
            if let previousDate,
               !cached.contains(where: { calendar.isDate($0.serviceDate, inSameDayAs: previousDate) }) {
                optionalDates.append(previousDate)
            }
            let fetched = try await PATCOSpecialScheduleLoader.specialSchedules(
                for: dates,
                calendar: calendar,
                optionalDates: optionalDates
            )
            try Task.checkCancellation()
            replaceSchedules(fetched, matching: dates, calendar: calendar)
            defaults.set(false, forKey: lastCheckFailedKey)
            return RefreshResult(schedules: schedules(matching: cachedDates, calendar: calendar), lastChecked: checkedAt, failed: false)
        } catch {
            if Task.isCancelled {
                if defaults.object(forKey: lastCheckKey) as? Date == checkedAt {
                    defaults.removeObject(forKey: lastCheckKey)
                }
                return RefreshResult(schedules: cached, lastChecked: lastCheck, failed: false)
            }
            defaults.set(true, forKey: lastCheckFailedKey)
            return RefreshResult(schedules: cached, lastChecked: checkedAt, failed: true)
        }
    }

    private static func dateKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func departureWindowDates(from date: Date, calendar: Calendar) -> [Date] {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) else {
            return [date]
        }
        return [date, tomorrow]
    }

    private static func allSchedules() -> [PATCOSpecialSchedule] {
        guard let data = defaults.data(forKey: schedulesKey),
              let schedules = try? JSONDecoder().decode([PATCOSpecialSchedule].self, from: data) else {
            return []
        }
        return schedules
    }

    private static func replaceSchedules(
        _ schedules: [PATCOSpecialSchedule],
        matching dates: [Date],
        calendar: Calendar
    ) {
        let retained = allSchedules().filter { schedule in
            !dates.contains { calendar.isDate(schedule.serviceDate, inSameDayAs: $0) }
        }
        let updated = deduplicated(retained + schedules)
        if let data = try? JSONEncoder().encode(updated) {
            defaults.set(data, forKey: schedulesKey)
        }
    }

    private static func deduplicated(_ schedules: [PATCOSpecialSchedule]) -> [PATCOSpecialSchedule] {
        var uniqueSchedules: [PATCOSpecialSchedule] = []
        for schedule in schedules {
            guard !uniqueSchedules.contains(where: { $0.sourceURL == schedule.sourceURL }) else {
                continue
            }

            uniqueSchedules.append(schedule)
        }

        return uniqueSchedules
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    var htmlDecoded: String {
        var decoded = self
        let entities: [String: String] = [
            "&amp;": "&",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&lt;": "<",
            "&gt;": ">",
            "&nbsp;": " "
        ]

        for (entity, value) in entities {
            decoded = decoded.replacingOccurrences(of: entity, with: value)
        }

        return decoded
    }
}
