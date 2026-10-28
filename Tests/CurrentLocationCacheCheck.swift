import Foundation
import CoreLocation

@main
struct CurrentLocationCacheCheck {
    static func main() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = SharedCurrentLocationCache.Snapshot(latitude: 39.95, longitude: -75.16,
            horizontalAccuracy: 4, timestamp: timestamp, speed: 0.2)
        let decoded = try JSONDecoder().decode(SharedCurrentLocationCache.Snapshot.self,
            from: JSONEncoder().encode(snapshot))
        precondition(decoded.location.speed == 0.2)
        precondition(decoded.location.timestamp == timestamp)
        precondition(decoded.location.horizontalAccuracy == 4)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
        legacy.removeValue(forKey: "speed")
        let old = try JSONDecoder().decode(SharedCurrentLocationCache.Snapshot.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        precondition(old.location.speed == -1)
        for speed in [-1.0, Double.nan, Double.infinity] {
            var invalid = snapshot
            invalid.speed = speed
            precondition(invalid.location.speed == -1)
        }
        var gate = DestinationArrivalGate()
        let station = CLLocation(latitude: snapshot.latitude, longitude: snapshot.longitude)
        precondition(!gate.accepts(destinationId: "B", station: station, location: decoded.location, now: timestamp))
        precondition(!gate.accepts(destinationId: "B", station: station, location: decoded.location,
            now: timestamp.addingTimeInterval(10)))
        precondition(gate.diagnosticDescription(for: decoded.location, now: timestamp).contains("1 unique fixes"))
        let fresh = SharedCurrentLocationCache.Snapshot(latitude: snapshot.latitude, longitude: snapshot.longitude,
            horizontalAccuracy: 4, timestamp: timestamp.addingTimeInterval(10), speed: 0.2)
        precondition(gate.accepts(destinationId: "B", station: station, location: fresh.location,
            now: timestamp.addingTimeInterval(10)))
        print("Current location cache checks passed")
    }
}
