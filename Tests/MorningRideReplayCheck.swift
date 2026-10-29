#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct MorningRideReplayCheck {
    struct Recording: Decodable {
        let source: String
        let reconstruction: String
        let scheduledOffsets: [String: Double]
        let events: [Event]
    }
    struct Event: Decodable {
        let seconds: Double
        let age: Double?
        let station: String
        let distance: Double
        let accuracy: Double
        let speed: Double
        let lastAccepted: String
    }
    static func run() throws {
        let recording = try JSONDecoder().decode(Recording.self, from: Data(contentsOf:
            URL(fileURLWithPath: "Tests/Fixtures/morning-2026-10-22.json")))
        XCTAssertTrue(!recording.source.isEmpty && !recording.reconstruction.isEmpty)
        let feed = try JSONDecoder().decode(PATCOFeed.self, from: Data(contentsOf:
            URL(fileURLWithPath: "NextPATCOTrain/Resources/patco_schedule.json")))
        let stations = (10...14).map { code in feed.stops.first { $0.code == String(code) }! }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduled = Dictionary(uniqueKeysWithValues: stations.map {
            ($0.id, base.addingTimeInterval(recording.scheduledOffsets[$0.code]!))
        })
        for restartAfterEveryFix in [false, true] {
            var progress = TripLocationProgress()
            for event in recording.events {
                let station = stations.first { $0.code == event.station }!
                let now = base.addingTimeInterval(event.seconds)
                let location = CLLocation(coordinate: .init(latitude: station.latitude + event.distance / 111_195,
                    longitude: station.longitude), altitude: 0, horizontalAccuracy: event.accuracy,
                    verticalAccuracy: 1, course: -1, speed: event.speed, timestamp: now.addingTimeInterval(-(event.age ?? 0)))
                progress.observe(location, stations: stations, geometry: nil, departure: base.addingTimeInterval(-60),
                    arrival: scheduled[stations.last!.id]!, now: now, stationArrivals: scheduled)
                let expected = stations.first { $0.code == event.lastAccepted }!
                XCTAssertTrue(progress.arrivalAnchorStationId == expected.id,
                    "Morning replay at +\(event.seconds)s: expected \(expected.name), got \(progress.arrivalAnchorStationId ?? "none")")
                XCTAssertTrue(progress.mapPosition(stations: stations, geometry: nil, now: now)?.coordinate.latitude == expected.latitude)
                let original = progress
                progress.observe(location, stations: stations, geometry: nil, departure: base.addingTimeInterval(-60),
                    arrival: scheduled[stations.last!.id]!, now: now, stationArrivals: scheduled)
                XCTAssertTrue(progress == original, "A repeated callback cannot advance progress")
                if restartAfterEveryFix {
                    progress = try JSONDecoder().decode(TripLocationProgress.self, from: JSONEncoder().encode(progress))
                }
            }
        }
        // Synthetic stress extension: a long blackout expires ETA, never the last accepted station.
        var progress = TripLocationProgress()
        let fix = CLLocation(coordinate: stations[0].coordinate, altitude: 0, horizontalAccuracy: 8,
            verticalAccuracy: 1, course: -1, speed: 0, timestamp: base)
        progress.observe(fix, stations: stations, geometry: nil, departure: base,
                         arrival: base.addingTimeInterval(1200), now: base)
        let later = base.addingTimeInterval(300)
        XCTAssertTrue(progress.arrivalEstimate(stations: stations, scheduled: scheduled, geometry: nil, now: later) == nil)
        XCTAssertTrue(progress.mapPosition(stations: stations, geometry: nil, now: later)?.isFreshGPS == false)
        XCTAssertTrue(progress.arrivalAnchorStationId == stations[0].id)
        print("Morning ride replay checks passed: 18 log-derived observations, delayed destination, persistence after every fix, duplicate callbacks and prolonged signal loss")
    }
}
