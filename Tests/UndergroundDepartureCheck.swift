import Foundation
import CoreLocation

@main
struct UndergroundDepartureCheck {
    static func main() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var evidence = UndergroundDepartureEvidence()
        func sample(_ t: Double, station: String = "B", reliable: Bool = false,
                    distance: Double = 30, other: Double = 500, active: Bool = true,
                    wall: Double? = nil, route: [String] = ["A", "B", "C", "D"]) -> String? {
            let location = CLLocation(coordinate: .init(latitude: 39.95, longitude: -75.16),
                altitude: 0, horizontalAccuracy: reliable ? 10 : 1414, verticalAccuracy: -1,
                timestamp: base.addingTimeInterval(t))
            return evidence.observe(route: route, stationId: station, reliable: reliable,
                underground: true, distance: distance, otherDistance: other, location: location,
                journeyActive: active, now: base.addingTimeInterval(wall ?? t))
        }
        for t in [0.0, 5, 10] { precondition(sample(t) == nil, "Requires reliable journey anchor") }
        precondition(sample(11, station: "A", reliable: true) == nil)
        precondition(sample(12) == nil)
        for _ in 0..<10 { precondition(sample(12) == nil, "Duplicates cannot build evidence") }
        precondition(sample(17) == nil)
        precondition(sample(22) == "B")
        precondition(sample(23, station: "A") == nil, "Cannot move backward")
        precondition(sample(24, station: "C") == nil)
        precondition(sample(29, station: "C") == nil)
        precondition(sample(34, station: "C") == "C")
        for t in [35.0, 40, 45] { precondition(sample(t, station: "D") == nil, "Never infer destination arrival") }
        for t in [46.0, 51, 56] { precondition(sample(t, station: "C", distance: 500) == nil) }
        for t in [57.0, 62, 67] { precondition(sample(t, station: "C", other: 60) == nil) }
        for t in [68.0, 73, 78] { precondition(sample(t, station: "C", active: false) == nil) }
        precondition(sample(79, station: "C", wall: 100) == nil, "Stale readings rejected")
        precondition(sample(101, station: "C", wall: 100) == nil, "Future readings rejected")
        precondition(sample(102, station: "C") == nil)
        precondition(sample(107, station: "C") == nil)
        precondition(sample(160, station: "C") == nil, "Long gaps reset evidence")
        precondition(sample(161, station: "C", route: ["D", "C", "B", "A"]) == nil)
        precondition(sample(166, station: "C", route: ["D", "C", "B", "A"]) == nil)
        precondition(sample(171, station: "C", route: ["D", "C", "B", "A"]) == nil, "New route needs new anchor")
        print("Underground departure checks passed")
    }
}
