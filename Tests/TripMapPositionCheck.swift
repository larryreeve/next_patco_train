#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct TripMapPositionCheck {
    static func run() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stops = (0..<3).map { index in
            Station(id: String(index), code: "11", name: "Stop \(index)",
                    latitude: 40 + Double(index) * 0.01, longitude: -75, zone: "1", url: "")
        }
        for stations in [stops, Array(stops.reversed())] {
            for geometry in [nil, PATCOTrackGeometry(shapes: [stops.map { [$0.latitude, $0.longitude] }])] {
                var progress = TripLocationProgress()
                XCTAssertTrue(progress.mapPosition(stations: stations, geometry: geometry, now: now) == nil)
                progress.latitude = stations[0].latitude
                progress.longitude = -75
                progress.positionAt = now.addingTimeInterval(-60)
                progress.detectedStationIds = [stations[1].id]
                var marker = progress.mapPosition(stations: stations, geometry: geometry, now: now)!
                XCTAssertTrue(marker.coordinate.latitude == stations[1].latitude)
                XCTAssertTrue(marker.title == "Last confirmed station" && !marker.isFreshGPS)
                // A fresh but lagging fix must not undo station progress either.
                progress.positionAt = now
                XCTAssertTrue(progress.mapPosition(stations: stations, geometry: geometry, now: now)!.coordinate.latitude == stations[1].latitude)
                let ahead = (stations[1].latitude + stations[2].latitude) / 2
                progress.latitude = ahead
                marker = progress.mapPosition(stations: stations, geometry: geometry, now: now)!
                XCTAssertTrue(marker.coordinate.latitude == ahead && marker.isFreshGPS)
                progress.positionAt = now.addingTimeInterval(-60)
                XCTAssertTrue(progress.mapPosition(stations: stations, geometry: geometry, now: now)!.coordinate.latitude == ahead)
                // Persisted station-only evidence still provides a useful marker.
                progress.latitude = nil
                progress.longitude = nil
                progress.positionAt = nil
                progress = try JSONDecoder().decode(TripLocationProgress.self, from: JSONEncoder().encode(progress))
                XCTAssertTrue(progress.mapPosition(stations: stations, geometry: geometry, now: now)!.coordinate.latitude == stations[1].latitude)
            }
        }
        var inferred = TripLocationProgress()
        func observe(_ seconds: Double, station: Station, accuracy: Double) {
            let reading = CLLocation(coordinate: station.coordinate, altitude: 0, horizontalAccuracy: accuracy,
                verticalAccuracy: 1, course: -1, speed: -1, timestamp: now.addingTimeInterval(seconds))
            inferred.observe(reading, stations: stops, geometry: nil, departure: now,
                arrival: now.addingTimeInterval(600), now: reading.timestamp,
                stationArrivals: [stops[1].id: now.addingTimeInterval(100)])
        }
        observe(1, station: stops[0], accuracy: 10)
        inferred.latitude = stops[0].latitude
        inferred.longitude = -75
        inferred.positionAt = now.addingTimeInterval(1)
        observe(100, station: stops[1], accuracy: 1414)
        observe(105, station: stops[1], accuracy: 1414)
        let marker = inferred.mapPosition(stations: stops, geometry: nil, now: now.addingTimeInterval(105))!
        XCTAssertTrue(marker.coordinate.latitude == stops[1].latitude && marker.title == "Estimated station position")
        XCTAssertTrue(!marker.isFreshGPS && inferred.latitude == stops[0].latitude,
                     "Display fallback must not rewrite GPS evidence")
        print("Trip map position checks passed: both directions, station floor, GPS ahead, inferred stops and persistence")
    }
}
