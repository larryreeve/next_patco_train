#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct TravelEstimateCacheCheck {
    static func run() throws {
        var walking = TravelEstimateRequestGate()
        var driving = TravelEstimateRequestGate()
        let oldWalking = walking.begin()
        let oldDriving = driving.begin()
        let newWalking = walking.begin()
        let newDriving = driving.begin()
        var walkingValue: Int? = nil
        var drivingValue: Int? = nil
        if walking.accepts(newWalking) { walkingValue = 12 }
        if driving.accepts(newDriving) { drivingValue = 8 }
        // Late successes and failures from superseded requests must both be ignored.
        if walking.accepts(oldWalking) { walkingValue = 40 }
        if driving.accepts(oldDriving) { drivingValue = 40 }
        if walking.accepts(oldWalking) { walkingValue = nil }
        if driving.accepts(oldDriving) { drivingValue = nil }
        XCTAssertTrue(walkingValue == 12 && drivingValue == 8)
        _ = walking.begin()
        XCTAssertTrue(!walking.accepts(newWalking) && driving.accepts(newDriving), "Modes have independent request ordering")
        let app = try SourceInspection.home()
        let data = try Data(contentsOf: URL(fileURLWithPath: "NextPATCOTrain/Resources/patco_schedule.json"))
        let store = PATCOScheduleStore(feed: try JSONDecoder().decode(PATCOFeed.self, from: data))
        let origin = store.stations.first { $0.name == "Ashland" }!
        let other = store.stations.first { $0.name == "Woodcrest" }!
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func location(meters: Double) -> CLLocation {
            CLLocation(latitude: 39.9 + meters / 111_195, longitude: -75.0)
        }
        func estimate(age: Double = 0) -> SharedTravelTimeEstimateCache.Estimate {
            .init(originId: origin.id, sourceLatitude: 39.9, sourceLongitude: -75.0,
                  minutes: 12, fetchedAt: now.addingTimeInterval(-age))
        }
        let cached = estimate(age: 120)
        XCTAssertTrue(cached.isValid(for: origin, currentLocation: location(meters: 0), mode: .walking, now: now))
        XCTAssertTrue(cached.isValid(for: origin, currentLocation: location(meters: 49), mode: .walking, now: now))
        XCTAssertTrue(!cached.isValid(for: origin, currentLocation: location(meters: 51), mode: .walking, now: now))
        XCTAssertTrue(cached.isValid(for: origin, currentLocation: location(meters: 99), mode: .driving, now: now))
        XCTAssertTrue(!cached.isValid(for: origin, currentLocation: location(meters: 101), mode: .driving, now: now))
        XCTAssertTrue(!cached.isValid(for: other, currentLocation: location(meters: 0), mode: .driving, now: now))
        XCTAssertTrue(estimate(age: 299).isValid(for: origin, currentLocation: location(meters: 0), mode: .walking, now: now))
        XCTAssertTrue(!estimate(age: 300).isValid(for: origin, currentLocation: location(meters: 0), mode: .walking, now: now))
        XCTAssertTrue(!estimate(age: -1).isValid(for: origin, currentLocation: location(meters: 0), mode: .walking, now: now))
        XCTAssertTrue(!cached.isValid(for: origin, currentLocation: location(meters: 0), mode: .walking,
                                     now: now.addingTimeInterval(180)), "Reusing an estimate must not renew its age")

        let expiry = now.addingTimeInterval(83)
        func guidance(minutes: Int = 12, source: String = "Maps estimate", age: Double = 0,
                      locationAge: Double = 0, mode: SharedReachabilityModeStore.Mode = .driving) -> SharedTripState.Guidance {
            .init(location: .init(latitude: 39.9, longitude: -75, horizontalAccuracy: 10,
                                 timestamp: now.addingTimeInterval(-locationAge)),
                  mode: mode, travelMinutes: minutes, estimateSource: source,
                  estimateFetchedAt: now.addingTimeInterval(-age))
        }
        let old = guidance(source: "Distance-based fallback")
        XCTAssertTrue(SharedTripState.Guidance.meaningfullyChanged(from: old, to: guidance(), at: now))
        XCTAssertTrue(SharedTripState.Guidance.meaningfullyChanged(from: guidance(), to: guidance(minutes: 25), at: now))
        XCTAssertTrue(SharedTripState.Guidance.meaningfullyChanged(from: guidance(), to: guidance(mode: .walking), at: now))
        XCTAssertTrue(SharedTripState.Guidance.meaningfullyChanged(from: guidance(), to: nil, at: now))
        XCTAssertTrue(SharedTripState.Guidance.meaningfullyChanged(from: guidance(age: 300), to: guidance(), at: now))
        XCTAssertTrue(!SharedTripState.Guidance.meaningfullyChanged(from: guidance(age: 5, locationAge: 5), to: guidance(), at: now),
                     "Timestamp-only changes must not create reload loops")
        let expiring = guidance(age: 290)
        XCTAssertTrue(expiring.expirationDate == now.addingTimeInterval(10))
        XCTAssertTrue(guidance(locationAge: 175).expirationDate == now.addingTimeInterval(6))
        let stationGuidance = guidance(source: "At station", locationAge: 29)
        XCTAssertTrue(stationGuidance.expirationDate == now.addingTimeInterval(2))
        let stationDates = WidgetTimelinePolicy.entryDates(now: now, departures: [now.addingTimeInterval(500)],
                                                          guidanceExpiration: stationGuidance.expirationDate)
        XCTAssertTrue(stationDates.first { $0 > now } == now.addingTimeInterval(2))
        let suite = "TravelEstimateWriteCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        XCTAssertTrue(SharedTravelTimeEstimateCache.save(mode: .walking, origin: origin, currentLocation: location(meters: 0),
            minutes: 12, fetchedAt: now, defaults: defaults, directory: directory))
        XCTAssertTrue(!SharedTravelTimeEstimateCache.save(mode: .walking, origin: origin, currentLocation: location(meters: 0),
            minutes: 40, fetchedAt: now.addingTimeInterval(-60), defaults: defaults, directory: directory),
                     "Legacy or in-memory app writes must not overwrite a newer widget estimate")
        XCTAssertTrue(!SharedTravelTimeEstimateCache.save(mode: .walking, origin: origin, currentLocation: location(meters: 0),
            minutes: 40, fetchedAt: now.addingTimeInterval(5), requestStartedAt: now.addingTimeInterval(-5),
            defaults: defaults, directory: directory), "Older response cannot overwrite a newer app/widget cache write")
        XCTAssertTrue(SharedTravelTimeEstimateCache.save(mode: .driving, origin: origin, currentLocation: location(meters: 0),
            minutes: 8, fetchedAt: now.addingTimeInterval(5), requestStartedAt: now.addingTimeInterval(-5),
            defaults: defaults, directory: directory), "Modes must remain independent")
        XCTAssertTrue(SharedTravelTimeEstimateCache.save(mode: .walking, origin: origin, currentLocation: location(meters: 0),
            minutes: 10, fetchedAt: now.addingTimeInterval(10), requestStartedAt: now.addingTimeInterval(6),
            defaults: defaults, directory: directory))
        XCTAssertTrue(SharedTravelTimeEstimateCache.save(mode: .walking, origin: origin, currentLocation: location(meters: 0),
            minutes: 9, fetchedAt: now.addingTimeInterval(11), requestStartedAt: now.addingTimeInterval(7),
            defaults: defaults, directory: directory), "Newer requests remain valid when they overlap an older response")
        XCTAssertTrue(!SharedTravelTimeEstimateCache.save(mode: .walking, origin: origin, currentLocation: location(meters: 0),
            minutes: 40, fetchedAt: now.addingTimeInterval(9), defaults: defaults, directory: directory),
                     "Cache reuse must compare fetch dates even if it was fetched after the newer request started")
        for mode in [SharedTravelTimeEstimateCache.Mode.walking, .driving] {
            XCTAssertTrue(SharedTravelTimeEstimateCache.save(mode: mode, origin: origin, currentLocation: location(meters: 0),
                minutes: 25, fetchedAt: now.addingTimeInterval(20), requestStartedAt: now.addingTimeInterval(12),
                defaults: defaults, directory: directory))
            let key = mode == .walking ? "cachedWalkingTravelTimeEstimate" : "cachedDrivingTravelTimeEstimate"
            let original = defaults.data(forKey: key)!
            XCTAssertTrue(!SharedTravelTimeEstimateCache.clear(mode: mode, ifNotNewerThan: now.addingTimeInterval(10),
                originId: origin.id, defaults: defaults, directory: directory), "Older failure cannot erase a newer success")
            XCTAssertTrue(defaults.data(forKey: key) == original)
            XCTAssertTrue(!SharedTravelTimeEstimateCache.clear(mode: mode, ifNotNewerThan: now.addingTimeInterval(15),
                originId: origin.id, defaults: defaults, directory: directory), "Success received during the failed request must survive")
            XCTAssertTrue(!SharedTravelTimeEstimateCache.clear(mode: mode, ifNotNewerThan: now.addingTimeInterval(30),
                originId: other.id, defaults: defaults, directory: directory), "Another origin's cache must survive")
            XCTAssertTrue(SharedTravelTimeEstimateCache.clear(mode: mode, ifNotNewerThan: now.addingTimeInterval(30),
                originId: origin.id, defaults: defaults, directory: directory), "Pre-request cache can be invalidated")
            XCTAssertTrue(defaults.data(forKey: key) == nil)
            XCTAssertTrue(SharedTravelTimeEstimateCache.clear(mode: mode, defaults: defaults, directory: directory),
                         "Explicit unconditional clear remains supported")
        }
        let lockDates = WidgetTimelinePolicy.entryDates(now: now, departures: [now.addingTimeInterval(500)],
                                                       guidanceExpiration: expiring.expirationDate)
        XCTAssertTrue(lockDates.contains(now.addingTimeInterval(10)), "Lock Screen must invalidate colors at Maps expiry")
        let widget = try SourceInspection.widget()
        XCTAssertTrue(widget.contains("guidanceExpiration: shared?.guidance?.expirationDate"))
        XCTAssertTrue(widget.contains("walkingRequests.accepts(requestID) : drivingRequests.accepts(requestID)"))
        XCTAssertTrue(widget.contains("route.revision == requestRevision, route.originId == origin.id"))
        XCTAssertTrue(widget.contains("latestLocation.distance(from: currentLocation) < (mode == .walking ? 50 : 100)"))
        XCTAssertTrue(app.contains("requestWidgetReload(reason: \"Shared travel guidance updated\")"),
                     "Routine guidance changes must use the coalesced reload path")
        XCTAssertTrue(!app.contains("requestWidgetReload(reason: \"Shared travel guidance updated\", force: true)"))
        let dates = WidgetTimelinePolicy.entryDates(now: now, departures: [now.addingTimeInterval(500)],
                                                   guidanceExpiration: expiry)
        XCTAssertTrue(dates.contains(expiry), "Freshness must expire without another GPS/Maps request")
        XCTAssertTrue(dates.contains(now.addingTimeInterval(60)), "Catchability still recalculates each minute")
        let normal = WidgetTimelinePolicy.nextRefresh(now: now, hasService: true, hasGuidance: true,
                                                       locationTimestamp: now)
        XCTAssertTrue(normal.date == now.addingTimeInterval(181))
        let cachedRefresh = WidgetTimelinePolicy.nextRefresh(now: now, hasService: true, hasGuidance: true,
            locationTimestamp: now, estimateTimestamp: now.addingTimeInterval(-200))
        XCTAssertTrue(cachedRefresh.date == now.addingTimeInterval(100), "Request renewal at Maps expiry while precomputed entries still invalidate stale guidance")
        print("Travel estimate cache checks passed: movement, station, mode limits, age and timeline freshness")
    }
}
