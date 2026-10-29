#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation

struct GTFSUpdateServiceCheck {
    static func run() async throws {
        let suite = "patco.gtfs.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = try PATCOFeedCache.decodeValidatedFeed(Data(contentsOf:
            URL(fileURLWithPath: "NextPATCOTrain/Resources/patco_schedule.json")))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let strings = [
            "agency.txt": "agency_name\nPATCO\n",
            "feed_info.txt": "feed_publisher_name,feed_start_date,feed_end_date,feed_version\nPATCO,20200101,20991231,test\n",
            "routes.txt": "route_id,route_short_name\n1,PATCO\n",
            "stops.txt": "stop_id,stop_name,stop_lat,stop_lon\n" + current.stops.map {
                "\($0.id),\($0.name),\($0.latitude),\($0.longitude)"
            }.joined(separator: "\n"),
            "calendar.txt": "service_id,start_date,end_date,monday,tuesday,wednesday,thursday,friday,saturday,sunday\ndaily,20200101,20991231,1,1,1,1,1,1,1\n",
            "calendar_dates.txt": "service_id,date,exception_type\n",
            "trips.txt": "route_id,trip_id,service_id,trip_headsign\n1,test,daily,Philadelphia\n",
            "stop_times.txt": "trip_id,stop_id,arrival_time,departure_time,stop_sequence\ntest,\(current.stops[0].id),10:00:00,10:00:00,1\ntest,\(current.stops[1].id),10:05:00,10:05:00,2\n"
        ]
        let files = strings.mapValues { Data($0.utf8) }
        var requests = 0
        var saves = 0
        var saved: PATCOFeed?
        var metadata: PATCOFeedMetadata?
        var failNetwork = false
        var failSave = false
        var invalidArchive = false
        let service = PATCOGTFSUpdateService(dependencies: .init(defaults: defaults, fetch: { request in
            requests += 1
            XCTAssertTrue(request.cachePolicy == .reloadIgnoringLocalCacheData)
            if failNetwork { throw URLError(.notConnectedToInternet) }
            let data = request.url!.path.hasSuffix(".zip") ? Data([1, 2])
                : Data("<a href='feed.zip'>Schedule</a>".utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, extract: { _ in
            if invalidArchive { throw PATCOGTFSUpdateError.missingRequiredFile("stops.txt") }
            return files
        }, loadMetadata: { metadata }, save: { feed, info in
            if failSave { throw CocoaError(.fileWriteNoPermission) }
            saves += 1; saved = feed; metadata = info
        }))
        guard case .updated = await service.updateIfNeeded(currentFeed: current, force: true, now: now) else {
            XCTFail("Valid update must be saved")
            return
        }
        XCTAssertTrue(requests == 2 && saves == 1 && metadata?.downloadedAt == now)
        guard case .notNeeded = await service.updateIfNeeded(currentFeed: saved!, now: now.addingTimeInterval(60)) else {
            XCTFail("Successful update should honor throttle")
            return
        }
        XCTAssertTrue(requests == 2)
        guard case .current = await service.updateIfNeeded(currentFeed: saved!, force: true, now: now.addingTimeInterval(120)) else {
            XCTFail("Identical schedule must not be reported changed")
            return
        }
        XCTAssertTrue(metadata?.lastUpdatedAt == now && saves == 2)
        for failure in ["network", "archive", "save"] {
            failNetwork = failure == "network"; invalidArchive = failure == "archive"; failSave = failure == "save"
            guard case .failed = await service.updateIfNeeded(currentFeed: saved!, force: true, now: now.addingTimeInterval(180)) else {
                XCTFail("Expected \(failure) failure")
            return
            }
            XCTAssertTrue(saves == 2 && defaults.bool(forKey: "gtfsLastUpdateFailed"))
        }
        failSave = false; invalidArchive = false; failNetwork = false
        guard case .current = await service.updateIfNeeded(currentFeed: saved!, now: now.addingTimeInterval(3780)) else {
            XCTFail("Failed updates must retry after one hour")
            return
        }
        XCTAssertTrue(!defaults.bool(forKey: "gtfsLastUpdateFailed"))
        print("GTFS dependency checks passed: update, unchanged feed, throttle, failure isolation and retry")
    }
}
