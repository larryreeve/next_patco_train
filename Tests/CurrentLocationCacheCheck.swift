#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct CurrentLocationCacheCheck {
    static func run() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = SharedCurrentLocationCache.Snapshot(latitude: 39.95, longitude: -75.16,
            horizontalAccuracy: 4, timestamp: timestamp, speed: 0.2)
        let decoded = try JSONDecoder().decode(SharedCurrentLocationCache.Snapshot.self,
            from: JSONEncoder().encode(snapshot))
        XCTAssertTrue(decoded.location.speed == 0.2)
        XCTAssertTrue(decoded.location.timestamp == timestamp)
        XCTAssertTrue(decoded.location.horizontalAccuracy == 4)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
        legacy.removeValue(forKey: "speed")
        let old = try JSONDecoder().decode(SharedCurrentLocationCache.Snapshot.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(old.location.speed == -1)
        for speed in [-1.0, Double.nan, Double.infinity] {
            var invalid = snapshot
            invalid.speed = speed
            XCTAssertTrue(invalid.location.speed == -1)
        }
        var gate = DestinationArrivalGate()
        let station = CLLocation(latitude: snapshot.latitude, longitude: snapshot.longitude)
        XCTAssertTrue(!gate.accepts(destinationId: "B", station: station, location: decoded.location, now: timestamp))
        XCTAssertTrue(!gate.accepts(destinationId: "B", station: station, location: decoded.location,
            now: timestamp.addingTimeInterval(10)))
        XCTAssertTrue(gate.diagnosticDescription(for: decoded.location, now: timestamp).contains("1 unique fixes"))
        let fresh = SharedCurrentLocationCache.Snapshot(latitude: snapshot.latitude, longitude: snapshot.longitude,
            horizontalAccuracy: 4, timestamp: timestamp.addingTimeInterval(10), speed: 0.2)
        XCTAssertTrue(gate.accepts(destinationId: "B", station: station, location: fresh.location,
            now: timestamp.addingTimeInterval(10)))
        print("Current location cache checks passed")
    }
}
