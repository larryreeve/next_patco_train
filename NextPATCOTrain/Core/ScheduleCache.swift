import Combine
import CoreLocation
import Foundation
import Darwin

enum PATCOFeedCache {
    private static let appGroup = "group.com.rhome.patconext"
    private static let scheduleDirectory = "Schedules"
    private static let feedFilename = "patco_schedule.json"
    private static let metadataFilename = "metadata.json"

    static func load() -> PATCOFeed? {
        guard let data = try? Data(contentsOf: feedURL) else { return nil }
        return try? decodeValidatedFeed(data)
    }

    static func decodeValidatedFeed(_ data: Data) throws -> PATCOFeed {
        let feed = try JSONDecoder().decode(PATCOFeed.self, from: data)
        try feed.validateStopIdentifiers()
        return feed
    }

    static func loadMetadata() -> PATCOFeedMetadata? {
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PATCOFeedMetadata.self, from: data)
    }

    static func save(_ feed: PATCOFeed, metadata: PATCOFeedMetadata) throws {
        try feed.validateStopIdentifiers()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let feedData = try JSONEncoder().encode(feed)
        let metadataEncoder = JSONEncoder()
        metadataEncoder.dateEncodingStrategy = .iso8601
        let metadataData = try metadataEncoder.encode(metadata)

        try feedData.write(to: feedURL, options: .atomic)
        try metadataData.write(to: metadataURL, options: .atomic)
    }

    private static var directoryURL: URL {
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return container.appendingPathComponent(scheduleDirectory, isDirectory: true)
    }

    private static var feedURL: URL {
        directoryURL.appendingPathComponent(feedFilename)
    }

    private static var metadataURL: URL {
        directoryURL.appendingPathComponent(metadataFilename)
    }
}

extension PATCOFeed {
    var startDate: String? {
        calendars.map(\.startDate).min()
    }

    var endDate: String? {
        calendars.map(\.endDate).max()
    }

    var serviceEndDate: Date? {
        guard let endDate else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.date(from: endDate)
    }

    func isExpired(on date: Date = Date()) -> Bool {
        guard let serviceEndDate,
              let expirationDate = PATCOClock.calendar.date(
                byAdding: .day,
                value: 1,
                to: serviceEndDate
              ) else {
            return true
        }
        return date >= expirationDate
    }
}
