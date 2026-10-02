import Foundation

@main
struct FeedValidationCheck {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "NextPATCOTrain/Resources/patco_schedule.json"))
        let valid = try PATCOFeedCache.decodeValidatedFeed(data)
        precondition(PATCOScheduleStore(feed: valid).loadError == nil)
        let duplicate = PATCOFeed(generatedFrom: valid.generatedFrom, feed: valid.feed,
            route: valid.route, stops: valid.stops + [valid.stops[0]], calendars: valid.calendars,
            calendarDates: valid.calendarDates, trips: valid.trips)
        do {
            _ = try PATCOFeedCache.decodeValidatedFeed(JSONEncoder().encode(duplicate))
            preconditionFailure("Duplicate identifiers accepted from cache")
        } catch ScheduleLoadError.invalidStopIdentifiers {}
        let rejectedStore = PATCOScheduleStore(feed: duplicate)
        precondition(rejectedStore.loadError != nil)
        precondition(rejectedStore.stations.isEmpty)
        let metadata = PATCOFeedMetadata(downloadedAt: Date(), feedStartDate: "", feedEndDate: "",
            feedVersion: nil, lastUpdatedAt: nil, previousFeedVersion: nil,
            sourceURL: URL(string: "https://example.com/feed.zip")!)
        do {
            try PATCOFeedCache.save(duplicate, metadata: metadata)
            preconditionFailure("Duplicate identifiers saved to shared cache")
        } catch ScheduleLoadError.invalidStopIdentifiers {}
        print("Feed validation checks passed")
    }
}
