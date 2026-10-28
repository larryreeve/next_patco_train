import Foundation
import CoreLocation

@main
struct PreciseArrivalCheck {
    static func main() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let station = CLLocation(latitude: 39.95, longitude: -75.16)
        func fix(_ seconds: Double, accuracy: Double = 20, speed: Double = 0, offset: Double = 0) -> CLLocation {
            CLLocation(coordinate: .init(latitude: 39.95 + offset / 111_195, longitude: -75.16), altitude: 0,
                horizontalAccuracy: accuracy, verticalAccuracy: 1, course: -1, speed: speed,
                timestamp: base.addingTimeInterval(seconds))
        }
        func accept(_ gate: inout DestinationArrivalGate, _ seconds: Double, accuracy: Double = 20,
                    speed: Double = 0, offset: Double = 0, otherDistance: Double = 1000,
                    wall: Double? = nil) -> Bool {
            gate.accepts(destinationId: "B", station: station, location: fix(seconds, accuracy: accuracy, speed: speed, offset: offset),
                nearestOtherStationDistance: otherDistance, routeSelectedAt: base.addingTimeInterval(-1),
                now: base.addingTimeInterval(wall ?? seconds))
        }
        var gate = DestinationArrivalGate()
        precondition(!accept(&gate, 0))
        precondition(!accept(&gate, 4.999))
        precondition(accept(&gate, 5, speed: 0.5, offset: 5))
        precondition(gate.lastDecision.contains("5 sec"))

        // Coarser readings must not inherit the shorter window in either direction.
        for accuracies in [[21.0, 20, 20], [20, 21, 20], [50, 50, 50]] {
            gate = DestinationArrivalGate()
            precondition(!accept(&gate, 0, accuracy: accuracies[0]))
            precondition(!accept(&gate, 5, accuracy: accuracies[1]))
            precondition(accept(&gate, 10, accuracy: accuracies[2]))
        }
        gate = DestinationArrivalGate()
        precondition(!accept(&gate, 0))
        precondition(!accept(&gate, 5, offset: 12), "Excess drift must restart the precise window")
        precondition(accept(&gate, 10, offset: 12), "The standard window must remain available")

        for scenario in ["moving", "unknown-speed", "inaccurate", "outside", "ambiguous", "stale", "gap"] {
            gate = DestinationArrivalGate()
            precondition(!accept(&gate, 0))
            let second = scenario == "gap" ? 16.0 : 5
            precondition(!accept(&gate, second, accuracy: scenario == "inaccurate" ? 51 : 20,
                speed: scenario == "moving" ? 0.51 : scenario == "unknown-speed" ? -1 : 0,
                offset: scenario == "outside" ? 150 : 0, otherDistance: scenario == "ambiguous" ? 74 : 1000,
                wall: scenario == "stale" ? 21 : second), "Unsafe fast arrival: \(scenario)")
        }
        gate = DestinationArrivalGate()
        precondition(!accept(&gate, 0))
        precondition(!accept(&gate, 0, wall: 16) && gate.hasStopEvidence)
        precondition(accept(&gate, 5, wall: 17), "Stale cached duplicates must preserve the precise evidence")
        gate.resetEvidence()
        precondition(!accept(&gate, 6))
        precondition(accept(&gate, 11))

        // Existing persisted standard evidence cannot be reinterpreted as precise evidence.
        gate = DestinationArrivalGate()
        precondition(!accept(&gate, 0))
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(gate)) as! [String: Any]
        legacy.removeValue(forKey: "preciseStopEvidence")
        gate = try JSONDecoder().decode(DestinationArrivalGate.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(!accept(&gate, 5))
        precondition(accept(&gate, 10))
        var presence = StationStopEvidence()
        precondition(!presence.accepts(stationId: "B", station: station, location: fix(0), now: base))
        precondition(!presence.accepts(stationId: "B", station: station, location: fix(5), now: base.addingTimeInterval(5)))

        let stations = [("A", 39.98), ("B", 39.95)].map { id, latitude in
            Station(id: id, code: id, name: id, latitude: latitude, longitude: -75.16, zone: "1", url: "")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for firstWidget in [false, true] {
            for lastWidget in [false, true] {
                let directory = root.appendingPathComponent("\(firstWidget)-\(lastWidget)")
                let original = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true,
                    now: base.addingTimeInterval(-1), directory: directory)!
                if firstWidget {
                    _ = SharedRouteCoordinator.resolveWidgetRoute(location: fix(0), stations: stations, now: base, directory: directory)
                } else {
                    _ = SharedRouteCoordinator.checkArrival(expectedRevision: original.revision, location: fix(0),
                        stations: stations, now: base, directory: directory)
                }
                precondition(SharedRouteCoordinator.current(directory: directory)?.revision == original.revision)
                let now = base.addingTimeInterval(5)
                let arrived: SharedRouteCoordinator.Route
                if lastWidget {
                    arrived = SharedRouteCoordinator.resolveWidgetRoute(location: fix(5), stations: stations, now: now, directory: directory)!
                } else {
                    precondition(SharedRouteCoordinator.checkArrival(expectedRevision: original.revision, location: fix(5),
                        stations: stations, now: now, directory: directory)?.confirmed == true)
                    arrived = SharedRouteCoordinator.commit(originId: "B", destinationId: "A", expectedRevision: original.revision,
                        arrival: true, observationAt: now, now: now, directory: directory)!
                }
                precondition(arrived.originId == "B" && arrived.destinationId == "A" && arrived.revision == original.revision + 1)
                precondition(SharedRouteCoordinator.resolveWidgetRoute(location: fix(5), stations: stations,
                    now: now, directory: directory)?.revision == arrived.revision)
            }
        }
        print("Precise arrival checks passed: five-second app/widget arrival, ten-second fallback, drift, invalid readings, duplicates, persistence and unchanged station presence")
    }
}
