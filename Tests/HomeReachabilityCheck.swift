#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import CoreLocation
import Foundation

struct HomeReachabilityCheck {
    static func run() throws {
        let feed = try JSONDecoder().decode(PATCOFeed.self, from: Data(contentsOf:
            URL(fileURLWithPath: "NextPATCOTrain/Resources/patco_schedule.json")))
        let store = PATCOScheduleStore(feed: feed)
        let origin = store.stations.first { $0.name == "Ashland" }!
        let destination = store.stations.first { $0.name == "15/16th and Locust" }!
        let now = PATCOClock.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 8))!
        let base = store.departures(from: origin, to: destination, after: now, limit: 1).first!
        func departure(after seconds: Double) -> Departure {
            Departure(trip: base.trip, origin: origin, destination: destination,
                originTime: base.originTime, destinationTime: base.destinationTime, serviceDate: now,
                departureDate: now.addingTimeInterval(seconds), arrivalDate: now.addingTimeInterval(seconds + 1500),
                routeSequenceIndex: 0, isSpecialSchedule: false, isRemovedBySpecialSchedule: false, scheduleAdjustment: nil)
        }
        let departures = [departure(after: -1), departure(after: 1800), departure(after: 7200)]
        func presentation(today: Bool = true, allowed: Bool = true, age: Double = 0,
                          atStation: Bool = false, temporary: Bool = false) -> HomeReachabilityPresentation {
            let location = SharedCurrentLocationCache.Snapshot(
                latitude: origin.latitude + (atStation ? 0 : 0.01), longitude: origin.longitude,
                horizontalAccuracy: 5, timestamp: now.addingTimeInterval(-age))
            let trip = SharedTripState.Snapshot(schema: 1, routeRevision: 1, origin: origin,
                destination: destination, preparedAt: now, departures: departures,
                scheduleVersion: nil, scheduleExpired: false, scheduleExpiresAt: nil, specialSchedules: [],
                guidance: .init(location: location, mode: .driving, travelMinutes: 10,
                    estimateSource: "Maps estimate", estimateFetchedAt: now.addingTimeInterval(-age)),
                lastBroadcastAt: now)
            return .init(isViewingToday: today, departures: departures, sharedTrip: trip,
                authorizationStatus: allowed ? .authorizedAlways : .denied,
                reachabilityLocation: nil, isUsingTemporaryStationRoute: temporary,
                drivingEstimateInFlight: false, driveTimeEstimate: nil, walkingTimeEstimate: nil)
        }
        let current = presentation()
        XCTAssertTrue(current.visibleDepartures(at: now).count == 2)
        XCTAssertTrue(current.listCatchStatus(for: departures[1], at: now)?.isLikelyToCatch == true)
        XCTAssertTrue(current.listCatchStatus(for: departures[2], at: now) == nil)
        XCTAssertTrue(current.catchStatus(for: departures[2], at: now) != nil)
        XCTAssertTrue(current.hasReliableDepartureEstimate(at: now))
        XCTAssertTrue(presentation(today: false).visibleDepartures(at: now).count == 3)
        XCTAssertTrue(presentation(today: false).catchStatus(for: departures[1], at: now) == nil)
        XCTAssertTrue(presentation(allowed: false).catchStatus(for: departures[1], at: now) == nil)
        XCTAssertTrue(presentation(age: 181).usableReachabilityLocation(at: now) == nil)
        XCTAssertTrue(!presentation(age: 301).hasReliableDepartureEstimate(at: now))
        XCTAssertTrue(presentation(atStation: true).isAtDepartureStation(at: now))
        XCTAssertTrue(presentation(atStation: true).listCatchStatus(for: departures[1], at: now) == nil)
        XCTAssertTrue(presentation(age: 301, temporary: true).reachabilityGuidance(at: now)?.systemImage == "tram.fill")
        print("Home reachability checks passed: future dates, permission, stale guidance, station presence, list filtering and temporary routes")
    }
}
