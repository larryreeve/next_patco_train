#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct TripSpeedCheck {
    static func run() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func reading(speed: Double = 20, accuracy: Double = 10, speedAccuracy: Double = 1,
                     age: Double = 0) -> CLLocation {
            CLLocation(coordinate: .init(latitude: 39.95, longitude: -75.16), altitude: 0,
                horizontalAccuracy: accuracy, verticalAccuracy: 1, course: 0, courseAccuracy: 1,
                speed: speed, speedAccuracy: speedAccuracy, timestamp: now.addingTimeInterval(-age))
        }
        XCTAssertTrue(TripSpeedPresentation.milesPerHour(reading(), now: now) == 45)
        XCTAssertTrue(TripSpeedPresentation.milesPerHour(reading(speed: 0), now: now) == 0)
        for fix in [reading(speed: -1), reading(speed: .nan), reading(speed: .infinity),
                    reading(speed: 100), reading(accuracy: 1414), reading(accuracy: -1),
                    reading(speedAccuracy: -1), reading(speedAccuracy: 6),
                    reading(age: 11), reading(age: -1)] {
            XCTAssertTrue(TripSpeedPresentation.milesPerHour(fix, now: now) == nil)
        }
        XCTAssertTrue(TripSpeedPresentation.milesPerHour(nil, now: now) == nil)
        XCTAssertTrue(!TripSpeedPresentation.isDuringTrip(departure: now.addingTimeInterval(1), arrival: now.addingTimeInterval(600), now: now))
        XCTAssertTrue(TripSpeedPresentation.isDuringTrip(departure: now, arrival: now.addingTimeInterval(600), now: now))
        XCTAssertTrue(TripSpeedPresentation.isDuringTrip(departure: now.addingTimeInterval(-600), arrival: now.addingTimeInterval(1), now: now))
        XCTAssertTrue(!TripSpeedPresentation.isDuringTrip(departure: now.addingTimeInterval(-600), arrival: now, now: now), "Hide at scheduled arrival")
        XCTAssertTrue(!TripSpeedPresentation.isDuringTrip(departure: now.addingTimeInterval(-600), arrival: now.addingTimeInterval(-1), now: now), "Trip shortcut grace period must not extend speed visibility")
        XCTAssertTrue(!TripSpeedPresentation.isDuringTrip(departure: now.addingTimeInterval(3600), arrival: now.addingTimeInterval(5400), now: now), "Choosing a future Live Activity must not show speed")
        XCTAssertTrue(!TripSpeedPresentation.isDuringTrip(departure: now, arrival: now, now: now))
        XCTAssertTrue(!TripSpeedPresentation.isDuringTrip(departure: now.addingTimeInterval(-1200), arrival: now.addingTimeInterval(-600), now: now))
        let geometry = PATCOTrackGeometry(shapes: [[[39.95, -75.16], [39.96, -75.16]]])
        func position(_ latitude: Double, _ longitude: Double, accuracy: Double = 10) -> CLLocation {
            CLLocation(coordinate: .init(latitude: latitude, longitude: longitude), altitude: 0,
                       horizontalAccuracy: accuracy, verticalAccuracy: 1, timestamp: now)
        }
        XCTAssertTrue(geometry.isNearTrack(position(39.955, -75.16)))
        XCTAssertTrue(geometry.isNearTrack(position(39.955, -75.1595)))
        XCTAssertTrue(!geometry.isNearTrack(position(39.955, -75.158)))
        XCTAssertTrue(!geometry.isNearTrack(position(39.97, -75.16)), "Do not extend segments beyond endpoints")
        XCTAssertTrue(!geometry.isNearTrack(position(39.955, -75.159, accuracy: 50)), "Include position uncertainty")
        XCTAssertTrue(!geometry.isNearTrack(position(39.955, -75.16, accuracy: 1414)))
        XCTAssertTrue(!PATCOTrackGeometry(shapes: []).isNearTrack(position(39.955, -75.16)))
        let trackData = try Data(contentsOf: URL(fileURLWithPath: "NextPATCOTrain/Resources/patco_tracks.json"))
        let tracks = try JSONDecoder().decode(PATCOTrackGeometry.self, from: trackData)
        XCTAssertTrue(tracks.shapes.count >= 2 && tracks.shapes.allSatisfy { $0.count > 50 })
        for shape in tracks.shapes {
            for point in shape { XCTAssertTrue(tracks.isNearTrack(position(point[0], point[1]))) }
        }
        XCTAssertTrue(!tracks.isNearTrack(position(39.95, -75.20)), "Off-route city location must not show speed")
        let data = try Data(contentsOf: URL(fileURLWithPath: "NextPATCOTrain/Resources/patco_schedule.json"))
        let store = PATCOScheduleStore(feed: try JSONDecoder().decode(PATCOFeed.self, from: data))
        let origin = store.stations.first { $0.name == "Ashland" }!
        let destination = store.stations.first { $0.name == "15/16th and Locust" }!
        let start = PATCOClock.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!
        let trip = store.departures(from: origin, to: destination, after: start, limit: 1).first!
        let url = URL(string: "patconext://departure?origin=\(origin.id)&destination=\(destination.id)&departure=\(trip.departureDate.timeIntervalSince1970)")!
        let link = DepartureDeepLink(url: url)!
        XCTAssertTrue(store.departure(matching: link)?.departureDate == trip.departureDate,
                     "Live Activity links must resolve departed trains outside the upcoming list")
        XCTAssertTrue(!ScheduledTripExpiration.hasExpired(arrivalDate: trip.arrivalDate, now: trip.arrivalDate.addingTimeInterval(599)))
        XCTAssertTrue(ScheduledTripExpiration.hasExpired(arrivalDate: trip.arrivalDate, now: trip.arrivalDate.addingTimeInterval(600)))
        print("Trip speed and Live Activity shortcut checks passed")
    }
}
