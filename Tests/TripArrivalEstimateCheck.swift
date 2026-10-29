#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct TripArrivalEstimateCheck {
    static func run() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let stations = [39.9, 39.91, 39.92].enumerated().map { index, latitude in
            Station(id: "\(index)", code: "\(index)", name: "Station \(index)", latitude: latitude,
                    longitude: -75, zone: "1", url: "")
        }
        let geometry = PATCOTrackGeometry(shapes: [[[39.9, -75], [39.91, -75], [39.92, -75]]])
        func reading(_ seconds: Double, latitude: Double) -> CLLocation {
            CLLocation(coordinate: .init(latitude: latitude, longitude: -75), altitude: 0,
                horizontalAccuracy: 5, verticalAccuracy: 1, course: -1, speed: -1,
                timestamp: base.addingTimeInterval(seconds))
        }
        for ordered in [stations, Array(stations.reversed())] {
            let schedule = Dictionary(uniqueKeysWithValues: ordered.enumerated().map {
                ($0.element.id, base.addingTimeInterval(Double($0.offset) * 300))
            })
            var progress = TripLocationProgress()
            let midpoint = (ordered[0].latitude + ordered[1].latitude) / 2
            let fix = reading(390, latitude: midpoint)
            progress.observe(fix, stations: ordered, geometry: geometry, departure: base,
                             arrival: base.addingTimeInterval(600), now: fix.timestamp)
            let estimate = progress.arrivalEstimate(stations: ordered, scheduled: schedule, geometry: geometry, now: fix.timestamp)!
            XCTAssertTrue(abs(estimate.date.timeIntervalSince(base) - 840) < 1)
            XCTAssertTrue(estimate.delayText(scheduled: base.addingTimeInterval(600)) == "4 min late")
            XCTAssertTrue(estimate.basis == "Based on current location")
            XCTAssertTrue(progress.arrivalEstimate(stations: ordered, scheduled: schedule, geometry: geometry,
                now: fix.timestamp.addingTimeInterval(15)) != nil, "GPS freshness includes exactly 15 seconds")
            XCTAssertTrue(progress.arrivalEstimate(stations: ordered, scheduled: schedule, geometry: geometry,
                now: fix.timestamp.addingTimeInterval(15.001)) == nil, "GPS expiry must not slide with redraws")
            XCTAssertTrue(progress.arrivalEstimate(stations: ordered, scheduled: schedule, geometry: nil,
                now: fix.timestamp) == nil, "Without geometry or an observed anchor, keep the schedule")
            XCTAssertTrue(progress.arrivalEstimate(stations: ordered, scheduled: schedule, geometry: geometry,
                now: fix.timestamp.addingTimeInterval(-1)) == nil, "Future observations cannot support an ETA")
            XCTAssertTrue(progress.arrivalEstimate(stations: ordered, scheduled: schedule, geometry: geometry,
                now: base.addingTimeInterval(406)) == nil, "Stale GPS without a station anchor must use the schedule")

            let stationFix = reading(540, latitude: ordered[1].latitude)
            progress.observe(stationFix, stations: ordered, geometry: geometry, departure: base,
                arrival: base.addingTimeInterval(600), now: stationFix.timestamp)
            progress = try JSONDecoder().decode(TripLocationProgress.self, from: JSONEncoder().encode(progress))
            let stationEstimate = progress.arrivalEstimate(stations: ordered, scheduled: schedule, geometry: geometry,
                now: base.addingTimeInterval(570))!
            XCTAssertTrue(stationEstimate.basis == "Based on Station 1")
            XCTAssertTrue(abs(stationEstimate.date.timeIntervalSince(base) - 840) < 1)
            let boundary = progress.arrivalEstimate(stations: ordered, scheduled: schedule, geometry: nil,
                now: stationFix.timestamp.addingTimeInterval(120))
            XCTAssertTrue(boundary?.observedAt == stationFix.timestamp, "Anchor timestamp survives persistence and redraws")
            XCTAssertTrue(progress.arrivalEstimate(stations: ordered, scheduled: schedule, geometry: nil,
                now: stationFix.timestamp.addingTimeInterval(120.001)) == nil)
            var missingDestination = schedule
            missingDestination.removeValue(forKey: ordered.last!.id)
            XCTAssertTrue(progress.arrivalEstimate(stations: ordered, scheduled: missingDestination, geometry: geometry,
                now: stationFix.timestamp) == nil, "Missing destination schedule cannot produce an ETA")
            XCTAssertTrue(progress.arrivalEstimate(stations: ordered, scheduled: schedule, geometry: geometry,
                now: base.addingTimeInterval(661)) == nil)
            XCTAssertTrue(progress.arrivalEstimate(stations: ordered, scheduled: schedule, geometry: geometry,
                now: base.addingTimeInterval(-1)) == nil)
            let destinationFix = reading(840, latitude: ordered[2].latitude)
            progress.observe(destinationFix, stations: ordered, geometry: geometry, departure: base,
                arrival: base.addingTimeInterval(600), now: destinationFix.timestamp)
            XCTAssertTrue(progress.arrivalEstimate(stations: ordered, scheduled: schedule, geometry: geometry,
                now: destinationFix.timestamp) == nil, "Completed destination must not show a future ETA")
        }
        let empty = TripLocationProgress()
        let stopEstimate = TripLocationProgress.ArrivalEstimate(date: base.addingTimeInterval(840),
            basis: "Test", observedAt: base.addingTimeInterval(390))
        for stopSeconds in [300.0, 450, 600] {
            XCTAssertTrue(stopEstimate.arrival(at: base.addingTimeInterval(stopSeconds),
                scheduledDestination: base.addingTimeInterval(600), now: base.addingTimeInterval(390))
                == base.addingTimeInterval(stopSeconds + 240), "Every remaining stop shares the destination delay")
        }
        XCTAssertTrue(stopEstimate.arrival(at: base.addingTimeInterval(100),
            scheduledDestination: base.addingTimeInterval(600), now: base.addingTimeInterval(390)) == nil,
            "Never display a past arrival as an upcoming ETA")
        XCTAssertTrue(stopEstimate.arrival(at: base.addingTimeInterval(601),
            scheduledDestination: base.addingTimeInterval(600), now: base) == nil)
        // Detail presentation is exercised by TripDetailPresentationCheck and JourneyUITests.
        XCTAssertTrue(empty.arrivalEstimate(stations: stations, scheduled: [:], geometry: geometry, now: base) == nil)
        let legacy = try JSONDecoder().decode(TripLocationProgress.self, from: Data("{\"detectedStationIds\":[],\"lastStationIndex\":-1}".utf8))
        XCTAssertTrue(legacy.arrivalAnchorAt == nil)
        let parser = ISO8601DateFormatter()
        for (scheduledText, estimatedText, expected) in [
            ("2026-10-22T18:04:05-04:00", "2026-10-22T18:07:45-04:00", "3 min late"),
            ("2026-10-22T18:04:59-04:00", "2026-10-22T18:05:01-04:00", "1 min late"),
            ("2026-10-22T18:04:01-04:00", "2026-10-22T18:04:59-04:00", "On time"),
            ("2026-10-22T18:07:45-04:00", "2026-10-22T18:04:05-04:00", "3 min early"),
            ("2026-10-22T23:59:50-04:00", "2026-10-23T00:02:01-04:00", "3 min late"),
            ("2026-10-23T00:02:01-04:00", "2026-10-22T23:59:50-04:00", "3 min early")
        ] {
            let scheduled = parser.date(from: scheduledText)!
            let estimated = parser.date(from: estimatedText)!
            let result = TripLocationProgress.ArrivalEstimate(date: estimated, basis: "Test", observedAt: base)
            XCTAssertTrue(result.delayText(scheduled: scheduled) == expected,
                         "Delay label must agree with the displayed minute-level times")
            XCTAssertTrue(result.date == estimated, "Display rounding must not change the underlying ETA")
        }
        print("Trip arrival estimate checks passed: both directions, scheduled interpolation, delay, station fallback, expiry, completion and persistence")
    }
}
