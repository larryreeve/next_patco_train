#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation

struct FeedValidationCheck {
    static func run() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "NextPATCOTrain/Resources/patco_schedule.json"))
        let valid = try PATCOFeedCache.decodeValidatedFeed(data)
        XCTAssertTrue(PATCOScheduleStore(feed: valid).loadError == nil)
        let duplicate = PATCOFeed(generatedFrom: valid.generatedFrom, feed: valid.feed,
            route: valid.route, stops: valid.stops + [valid.stops[0]], calendars: valid.calendars,
            calendarDates: valid.calendarDates, trips: valid.trips)
        do {
            _ = try PATCOFeedCache.decodeValidatedFeed(JSONEncoder().encode(duplicate))
            XCTFail("Duplicate identifiers accepted from cache")
        } catch ScheduleLoadError.invalidStopIdentifiers {}
        let rejectedStore = PATCOScheduleStore(feed: duplicate)
        XCTAssertTrue(rejectedStore.loadError != nil)
        XCTAssertTrue(rejectedStore.stations.isEmpty)
        let metadata = PATCOFeedMetadata(downloadedAt: Date(), feedStartDate: "", feedEndDate: "",
            feedVersion: nil, lastUpdatedAt: nil, previousFeedVersion: nil,
            sourceURL: URL(string: "https://example.com/feed.zip")!)
        do {
            try PATCOFeedCache.save(duplicate, metadata: metadata)
            XCTFail("Duplicate identifiers saved to shared cache")
        } catch ScheduleLoadError.invalidStopIdentifiers {}
        print("Feed validation checks passed")
    }
}
