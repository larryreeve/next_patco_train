import Foundation
import ZIPFoundation

actor PATCOGTFSUpdateService {
    static let shared = PATCOGTFSUpdateService()

    enum UpdateResult {
        case notNeeded
        case updated
        case failed(String)
    }

    private let developerPageURL = URL(string: "https://www.ridepatco.org/developers/")!
    private let appGroup = "group.com.rhome.patconext"
    private let lastAttemptKey = "gtfsLastUpdateAttempt"
    private let refreshWindow: TimeInterval = 7 * 24 * 60 * 60
    private let normalRetryInterval: TimeInterval = 24 * 60 * 60
    private let expiredRetryInterval: TimeInterval = 60 * 60
    private let maximumArchiveBytes = 5_000_000
    private let maximumExtractedFileBytes = 10_000_000

    func updateIfNeeded(currentFeed: PATCOFeed, force: Bool = false, now: Date = Date()) async -> UpdateResult {
        guard force || shouldUpdate(feed: currentFeed, now: now) else { return .notNeeded }

        let defaults = UserDefaults(suiteName: appGroup) ?? .standard
        let lastAttempt = defaults.object(forKey: lastAttemptKey) as? Date
        let retryInterval = isExpired(feed: currentFeed, now: now) ? expiredRetryInterval : normalRetryInterval
        guard force || lastAttempt.map({ now.timeIntervalSince($0) >= retryInterval }) != false else {
            return .notNeeded
        }
        defaults.set(now, forKey: lastAttemptKey)

        do {
            let sourceURL = try await currentGTFSURL()
            let archiveData = try await download(from: sourceURL)
            let files = try extractRequiredFiles(from: archiveData)
            let feed = try PATCOGTFSParser.parse(files: files, sourceURL: sourceURL)
            try PATCOGTFSValidator.validate(feed, replacing: currentFeed, requireNewer: !force)

            let metadata = PATCOFeedMetadata(
                downloadedAt: now,
                feedStartDate: feed.startDate ?? "",
                feedEndDate: feed.endDate ?? "",
                feedVersion: feed.feed["feed_version"],
                sourceURL: sourceURL
            )
            try PATCOFeedCache.save(feed, metadata: metadata)
            return .updated
        } catch {
            return .failed(String(describing: error))
        }
    }

    private func shouldUpdate(feed: PATCOFeed, now: Date) -> Bool {
        guard let endDate = feed.endDate.flatMap(Self.date(from:)) else { return true }
        return endDate.timeIntervalSince(now) <= refreshWindow
    }

    private func isExpired(feed: PATCOFeed, now: Date) -> Bool {
        guard let endDate = feed.endDate.flatMap(Self.date(from:)) else { return true }
        return now >= Calendar.patco.date(byAdding: .day, value: 1, to: endDate) ?? endDate
    }

    private func currentGTFSURL() async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: developerPageURL)
        try Self.requireSuccessful(response)
        guard let html = String(data: data, encoding: .utf8) else {
            throw PATCOGTFSUpdateError.invalidDeveloperPage
        }

        let pattern = #"href\s*=\s*["']([^"']+\.zip(?:\?[^"']*)?)["']"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let linkRange = Range(match.range(at: 1), in: html) else {
            throw PATCOGTFSUpdateError.missingDownloadLink
        }

        let link = String(html[linkRange]).replacingOccurrences(of: "&amp;", with: "&")
        guard let url = URL(string: link, relativeTo: developerPageURL)?.absoluteURL,
              url.scheme == "https" else {
            throw PATCOGTFSUpdateError.invalidDownloadLink
        }
        return url
    }

    private func download(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        try Self.requireSuccessful(response)
        guard data.count <= maximumArchiveBytes else {
            throw PATCOGTFSUpdateError.archiveTooLarge
        }
        return data
    }

    private func extractRequiredFiles(from archiveData: Data) throws -> [String: Data] {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PATCO-\(UUID().uuidString).zip")
        try archiveData.write(to: temporaryURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let archive = try Archive(url: temporaryURL, accessMode: .read)
        let required = [
            "agency.txt", "feed_info.txt", "routes.txt", "stops.txt",
            "calendar.txt", "calendar_dates.txt", "trips.txt", "stop_times.txt"
        ]
        var files: [String: Data] = [:]

        for filename in required {
            guard let entry = archive[filename], entry.uncompressedSize <= maximumExtractedFileBytes else {
                throw PATCOGTFSUpdateError.missingRequiredFile(filename)
            }
            var data = Data()
            _ = try archive.extract(entry) { chunk in
                data.append(chunk)
            }
            files[filename] = data
        }
        return files
    }

    private static func requireSuccessful(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PATCOGTFSUpdateError.downloadFailed
        }
    }

    private static func date(from yyyymmdd: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = .patco
        formatter.timeZone = Calendar.patco.timeZone
        formatter.dateFormat = "yyyyMMdd"
        return formatter.date(from: yyyymmdd)
    }
}

private enum PATCOGTFSUpdateError: Error {
    case invalidDeveloperPage
    case missingDownloadLink
    case invalidDownloadLink
    case downloadFailed
    case archiveTooLarge
    case missingRequiredFile(String)
    case invalidCSV(String)
    case invalidFeed(String)
    case feedDoesNotExtendSchedule
}

private enum PATCOGTFSParser {
    static func parse(files: [String: Data], sourceURL: URL) throws -> PATCOFeed {
        let agency = try rows("agency.txt", files: files).first ?? [:]
        let feedInfo = try rows("feed_info.txt", files: files).first ?? [:]
        let routeRows = try rows("routes.txt", files: files)
        guard let route = routeRows.first(where: { $0["route_short_name"]?.uppercased() == "PATCO" })
                ?? routeRows.first else {
            throw PATCOGTFSUpdateError.invalidFeed("missing PATCO route")
        }
        let routeId = route["route_id"] ?? ""

        let stops = try rows("stops.txt", files: files).compactMap { row -> Station? in
            guard row["location_type", default: "0"] != "1",
                  let id = row["stop_id"],
                  let name = row["stop_name"],
                  let latitude = Double(row["stop_lat"] ?? ""),
                  let longitude = Double(row["stop_lon"] ?? "") else { return nil }
            return Station(
                id: id,
                code: row["stop_code"] ?? id,
                name: normalizedStationName(name),
                latitude: latitude,
                longitude: longitude,
                zone: row["zone_id"] ?? "",
                url: row["stop_url"] ?? ""
            )
        }

        let calendars = try rows("calendar.txt", files: files).compactMap { row -> ServiceCalendar? in
            guard let serviceId = row["service_id"],
                  let startDate = row["start_date"],
                  let endDate = row["end_date"] else { return nil }
            return ServiceCalendar(
                serviceId: serviceId,
                weekdays: Weekdays(
                    monday: row["monday"] == "1",
                    tuesday: row["tuesday"] == "1",
                    wednesday: row["wednesday"] == "1",
                    thursday: row["thursday"] == "1",
                    friday: row["friday"] == "1",
                    saturday: row["saturday"] == "1",
                    sunday: row["sunday"] == "1"
                ),
                startDate: startDate,
                endDate: endDate
            )
        }

        let calendarDates = try rows("calendar_dates.txt", files: files).compactMap { row -> CalendarDateException? in
            guard let serviceId = row["service_id"],
                  let date = row["date"],
                  let exceptionType = Int(row["exception_type"] ?? "") else { return nil }
            return CalendarDateException(serviceId: serviceId, date: date, exceptionType: exceptionType)
        }

        let stopTimesByTrip = Dictionary(grouping: try rows("stop_times.txt", files: files)) {
            $0["trip_id"] ?? ""
        }
        let trips = try rows("trips.txt", files: files).compactMap { row -> Trip? in
            guard row["route_id"] == routeId,
                  let id = row["trip_id"],
                  let serviceId = row["service_id"],
                  let headsign = row["trip_headsign"] else { return nil }
            let stopTimes = (stopTimesByTrip[id] ?? []).compactMap { stopRow -> StopTime? in
                guard let stopId = stopRow["stop_id"],
                      let arrival = stopRow["arrival_time"],
                      let departure = stopRow["departure_time"],
                      let sequence = Int(stopRow["stop_sequence"] ?? "") else { return nil }
                return StopTime(stopId: stopId, arrival: arrival, departure: departure, sequence: sequence)
            }.sorted { $0.sequence < $1.sequence }
            guard stopTimes.count >= 2 else { return nil }
            return Trip(
                id: id,
                serviceId: serviceId,
                headsign: headsign,
                directionId: Int(row["direction_id"] ?? ""),
                bikesAllowed: row["bikes_allowed"] == "1",
                wheelchairAccessible: row["wheelchair_accessible"] == "1",
                stopTimes: stopTimes
            )
        }

        var normalizedFeedInfo = feedInfo
        if normalizedFeedInfo["feed_publisher_name"] == nil {
            normalizedFeedInfo["feed_publisher_name"] = agency["agency_name"]
        }
        return PATCOFeed(
            generatedFrom: sourceURL.absoluteString,
            feed: normalizedFeedInfo,
            route: route,
            stops: stops,
            calendars: calendars,
            calendarDates: calendarDates,
            trips: trips
        )
    }

    private static func normalizedStationName(_ name: String) -> String {
        switch name {
        case "9-10th and Locust":
            return "9/10th and Locust"
        case "12-13th and Locust":
            return "12/13th and Locust"
        case "15-16th and Locust":
            return "15/16th and Locust"
        default:
            return name
        }
    }

    private static func rows(_ filename: String, files: [String: Data]) throws -> [[String: String]] {
        guard let data = files[filename], let text = String(data: data, encoding: .utf8) else {
            throw PATCOGTFSUpdateError.invalidCSV(filename)
        }
        let parsed = GTFSCSV.parse(text)
        guard let headers = parsed.first, !headers.isEmpty else {
            throw PATCOGTFSUpdateError.invalidCSV(filename)
        }
        return parsed.dropFirst().filter { !$0.allSatisfy(\.isEmpty) }.map { values in
            Dictionary(uniqueKeysWithValues: headers.enumerated().map { index, header in
                (
                    header
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")),
                    index < values.count ? values[index] : ""
                )
            })
        }
    }
}

private enum GTFSCSV {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isQuoted = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                let next = text.index(after: index)
                if isQuoted, next < text.endIndex, text[next] == "\"" {
                    field.append("\"")
                    index = next
                } else {
                    isQuoted.toggle()
                }
            } else if character == ",", !isQuoted {
                row.append(field)
                field = ""
            } else if (character == "\n" || character == "\r\n" || character == "\r"), !isQuoted {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(character)
            }
            index = text.index(after: index)
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
            rows.append(row)
        }
        return rows
    }
}

private enum PATCOGTFSValidator {
    static func validate(_ feed: PATCOFeed, replacing currentFeed: PATCOFeed, requireNewer: Bool) throws {
        let publisher = feed.feed["feed_publisher_name"]?.uppercased() ?? ""
        let routeName = feed.route["route_short_name"]?.uppercased() ?? ""
        let expectedStations = Set(currentFeed.stops.map { $0.name.lowercased() })
        let downloadedStations = Set(feed.stops.map { $0.name.lowercased() })

        guard publisher.contains("PATCO") else {
            throw PATCOGTFSUpdateError.invalidFeed("publisher")
        }
        guard routeName == "PATCO" else {
            throw PATCOGTFSUpdateError.invalidFeed("route")
        }
        guard feed.stops.count >= 10 else {
            throw PATCOGTFSUpdateError.invalidFeed("stops")
        }
        guard expectedStations.isSubset(of: downloadedStations) else {
            throw PATCOGTFSUpdateError.invalidFeed("station names")
        }
        guard !feed.calendars.isEmpty else {
            throw PATCOGTFSUpdateError.invalidFeed("calendar")
        }
        guard !feed.trips.isEmpty else {
            throw PATCOGTFSUpdateError.invalidFeed("trips")
        }
        guard feed.trips.allSatisfy({ $0.stopTimes.count >= 2 }) else {
            throw PATCOGTFSUpdateError.invalidFeed("stop times")
        }
        guard let newEndDate = feed.endDate, let currentEndDate = currentFeed.endDate else {
            throw PATCOGTFSUpdateError.invalidFeed("feed dates")
        }
        guard !requireNewer || newEndDate > currentEndDate else {
            throw PATCOGTFSUpdateError.feedDoesNotExtendSchedule
        }
    }
}

private extension Calendar {
    static var patco: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return calendar
    }
}
