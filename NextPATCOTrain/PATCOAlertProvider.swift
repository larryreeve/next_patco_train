import Combine
import Foundation

struct PATCOAlertItem: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let url: URL?

    var displayTitle: String? {
        let cleaned = title.displayCleaned
        guard cleaned.rangeOfCharacter(from: .alphanumerics) != nil,
              !cleaned.localizedCaseInsensitiveContains("Travel Alerts & Special Schedules"),
              !cleaned.localizedCaseInsensitiveContains("Travel Alerts & Notices"),
              !cleaned.localizedCaseInsensitiveContains("Train Schedules"),
              !cleaned.localizedCaseInsensitiveContains("Schedules & Fares") else {
            return nil
        }

        return cleaned
    }
}

@MainActor
final class PATCOAlertProvider: ObservableObject {
    @Published private(set) var alerts: [PATCOAlertItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?

    private let alertURLs = [
        URL(string: "https://www.ridepatco.org/schedules/schedules.asp")!
    ]

    func refresh() {
        Task {
            await refreshNow()
        }
    }

    func refreshNow() async {
        await fetchAlerts()
    }

    private func fetchAlerts() async {
        isLoading = true
        errorMessage = nil

        do {
            var foundAlerts: [PATCOAlertItem] = []
            var loadedAtLeastOneSource = false

            for url in alertURLs {
                do {
                    var request = URLRequest(url: url)
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    request.timeoutInterval = 12

                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
                        continue
                    }

                    let html = String(decoding: data, as: UTF8.self)
                    foundAlerts.append(contentsOf: Self.parseAlerts(from: html, baseURL: url))
                    loadedAtLeastOneSource = true
                } catch {
                    continue
                }
            }

            guard loadedAtLeastOneSource else {
                throw URLError(.cannotLoadFromNetwork)
            }

            alerts = Self.deduplicated(foundAlerts).filter { $0.displayTitle != nil }
            lastUpdated = Date()
        } catch {
            alerts = []
            errorMessage = "Unable to load PATCO alerts"
        }

        isLoading = false
    }

    static func parseAlerts(from html: String, baseURL: URL) -> [PATCOAlertItem] {
        let specialScheduleSections = [
            html.slice(after: "Special Schedule(s)", beforeAnyOf: ["Need assistance?", "<hr", "Port Authority Transit Corporation"]),
            html.slice(after: "Special Schedules", beforeAnyOf: ["Need assistance?", "<hr", "Port Authority Transit Corporation"])
        ].compactMap { $0 }

        let canScanWholePageForSpecialSchedules = baseURL.path.localizedCaseInsensitiveContains("/schedules/schedules.asp")
        let specialScheduleTargets = specialScheduleSections.isEmpty && canScanWholePageForSpecialSchedules ? [html] : specialScheduleSections

        var alerts: [PATCOAlertItem] = []
        for target in specialScheduleTargets {
            alerts.append(contentsOf: parseSpecialScheduleAlerts(from: target, baseURL: baseURL))
        }

        return deduplicated(alerts)
    }

    private static func parseSpecialScheduleAlerts(from section: String, baseURL: URL) -> [PATCOAlertItem] {
        let listItemPattern = #"<li[^>]*>(.*?)(?=<li\b|</ul>|$)"#
        guard let listItemRegex = try? NSRegularExpression(pattern: listItemPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }

        let range = NSRange(section.startIndex..<section.endIndex, in: section)
        return listItemRegex.matches(in: section, range: range).compactMap { match in
            guard let itemRange = Range(match.range(at: 1), in: section) else {
                return nil
            }

            let itemHTML = String(section[itemRange])
            let title = itemHTML
                .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                .htmlDecoded
                .trimmed
            let alertTitle = specialScheduleAlertTitle(from: title)

            guard let alertTitle else {
                return nil
            }

            let url = preferredAlertLinkURL(in: itemHTML, baseURL: baseURL)
            return PATCOAlertItem(title: alertTitle, url: url)
        }
    }

    private static func specialScheduleAlertTitle(from title: String) -> String? {
        let cleaned = title
            .replacingOccurrences(of: #"\s*\|\s*"#, with: " | ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+:"#, with: ":", options: .regularExpression)
            .displayCleaned

        guard isLikelyAlertTitle(cleaned) || cleaned.localizedCaseInsensitiveContains("Service Advisory") else {
            return nil
        }

        guard let dateRange = cleaned.range(
            of: #"(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday),\s+[A-Z][a-z]+\s+\d{1,2},\s+\d{4}"#,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return cleaned
        }

        let date = String(cleaned[dateRange])
        if let advisoryDate = advisoryDate(from: date),
           advisoryDate < patcoCalendar.startOfDay(for: Date()) {
            return nil
        }

        guard let advisoryRange = cleaned.range(of: "Service Advisory", options: .caseInsensitive) else {
            return cleaned
        }

        let advisory = String(cleaned[advisoryRange.lowerBound...]).trimmed
        return "\(date) | \(advisory)"
    }

    private static func advisoryDate(from title: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = patcoCalendar
        formatter.timeZone = patcoCalendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter.date(from: title)
    }

    private static var patcoCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return calendar
    }

    private static func parseLinkedAlerts(from section: String, baseURL: URL) -> [PATCOAlertItem] {
        let pattern = #"<a\s+[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }

        let range = NSRange(section.startIndex..<section.endIndex, in: section)
        return regex.matches(in: section, range: range).compactMap { match in
            guard let hrefRange = Range(match.range(at: 1), in: section),
                  let textRange = Range(match.range(at: 2), in: section) else {
                return nil
            }

            let title = String(section[textRange]).htmlDecoded.trimmed
            guard isLikelyAlertTitle(title) else {
                return nil
            }

            let href = String(section[hrefRange])
            let url = URL(string: href, relativeTo: baseURL)?.absoluteURL
            return PATCOAlertItem(title: title, url: url)
        }
    }

    private static func preferredAlertLinkURL(in html: String, baseURL: URL) -> URL? {
        let pattern = #"<a\s+[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let links: [URL] = regex.matches(in: html, range: range).compactMap { match in
            guard let hrefRange = Range(match.range(at: 1), in: html) else {
                return nil
            }

            return URL(string: String(html[hrefRange]), relativeTo: baseURL)?.absoluteURL
        }

        return links.first { $0.path.localizedCaseInsensitiveContains("/news/") } ?? links.last
    }

    private static func parseStructuredAlerts(from section: String) -> [PATCOAlertItem] {
        let pattern = #"<[^>]*(?:class|id)\s*=\s*["'][^"']*(?:alert|advisory|notice|special)[^"']*["'][^>]*>(.*?)</[^>]+>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }

        let range = NSRange(section.startIndex..<section.endIndex, in: section)
        return regex.matches(in: section, range: range).compactMap { match in
            guard let textRange = Range(match.range(at: 1), in: section) else {
                return nil
            }

            let title = String(section[textRange])
                .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                .htmlDecoded
                .trimmed

            return isLikelyAlertTitle(title) ? PATCOAlertItem(title: title, url: nil) : nil
        }
    }

    private static func parsePlainAlerts(from section: String) -> [PATCOAlertItem] {
        let text = section
            .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"</li>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .htmlDecoded

        return text
            .components(separatedBy: .newlines)
            .map(\.trimmed)
            .filter { isLikelyAlertTitle($0) }
            .map { PATCOAlertItem(title: $0, url: nil) }
    }

    private static func isLikelyAlertTitle(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 8,
              !normalized.localizedCaseInsensitiveContains("PATCO Timetable"),
              !normalized.localizedCaseInsensitiveContains("Travel Alerts & Notices"),
              !normalized.localizedCaseInsensitiveContains("Travel Alerts & Special Schedules"),
              !normalized.localizedCaseInsensitiveContains("View Schedules"),
              !normalized.localizedCaseInsensitiveContains("Select a station"),
              !normalized.localizedCaseInsensitiveContains("No active PATCO alerts"),
              !normalized.localizedCaseInsensitiveContains("No active alerts"),
              !normalized.localizedCaseInsensitiveContains("No current alerts"),
              !normalized.localizedCaseInsensitiveContains("No service alerts") else {
            return false
        }

        let keywords = ["service advisory", "travel alert", "special schedule", "special schedules", "track work", "maintenance", "delay", "closure", "holiday schedule", "schedule change"]
        return keywords.contains { normalized.localizedCaseInsensitiveContains($0) }
    }

    private static func isLikelySpecialScheduleTitle(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 8,
              !normalized.localizedCaseInsensitiveContains("No special schedules"),
              !normalized.localizedCaseInsensitiveContains("No active alerts"),
              !normalized.localizedCaseInsensitiveContains("Need assistance") else {
            return false
        }

        let containsDatedSchedule = normalized.range(
            of: #"(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday),\s+[A-Z][a-z]+\s+\d{1,2},\s+\d{4}"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil

        return containsDatedSchedule ||
            normalized.localizedCaseInsensitiveContains("Service Advisory") ||
            normalized.localizedCaseInsensitiveContains("Special Schedule")
    }

    private static func deduplicated(_ alerts: [PATCOAlertItem]) -> [PATCOAlertItem] {
        var seen = Set<String>()
        return alerts.compactMap { alert in
            let title = alert.title.displayCleaned
            guard !title.isEmpty,
                  PATCOAlertItem(title: title, url: alert.url).displayTitle != nil else {
                return nil
            }

            let key = "\(title.lowercased())|\(alert.url?.absoluteString ?? "")"
            if seen.contains(key) {
                return nil
            }
            seen.insert(key)
            return PATCOAlertItem(title: title, url: alert.url)
        }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    var displayCleaned: String {
        replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmed
    }

    var htmlDecoded: String {
        var decoded = self
        let entities = [
            "&amp;": "&",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&lt;": "<",
            "&gt;": ">",
            "&nbsp;": " "
        ]

        for (entity, replacement) in entities {
            decoded = decoded.replacingOccurrences(of: entity, with: replacement)
        }

        return decoded.replacingNumericHTMLCharacters()
    }

    func slice(after startMarker: String, beforeAnyOf endMarkers: [String]) -> String? {
        guard let startRange = range(of: startMarker, options: [.caseInsensitive]) else {
            return nil
        }

        let remainder = String(self[startRange.upperBound...])
        let endIndex = endMarkers
            .compactMap { marker in remainder.range(of: marker, options: [.caseInsensitive])?.lowerBound }
            .min()

        if let endIndex {
            return String(remainder[..<endIndex])
        }

        return remainder
    }

    private func replacingNumericHTMLCharacters() -> String {
        let pattern = #"&#(\d+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return self
        }

        var result = self
        let matches = regex.matches(in: self, range: NSRange(startIndex..<endIndex, in: self)).reversed()
        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: result),
                  let numberRange = Range(match.range(at: 1), in: result),
                  let value = UInt32(result[numberRange]),
                  let scalar = UnicodeScalar(value) else {
                continue
            }

            result.replaceSubrange(fullRange, with: String(Character(scalar)))
        }

        return result
    }
}
