import Foundation
import CoreLocation

@main
struct LocationRandomizedCheck {
    struct Random {
        var state: UInt64
        mutating func next(_ upper: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(upper))
        }
    }
    static func main() {
        let stations = [("A", 39.98), ("C", 39.965), ("B", 39.95)].map { id, latitude in
            Station(id: id, code: id, name: id, latitude: latitude, longitude: -75.16, zone: "1", url: "")
        }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for seed: UInt64 in [1, 42, 20261005, 0xDEADBEEF] {
            var random = Random(state: seed)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var route = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true,
                now: base, directory: directory)!
            var previous: CLLocation?
            for iteration in 1...500 {
                let now = base.addingTimeInterval(Double(iteration * 2))
                let latitude = [39.98, 39.965, 39.95, 39.952, 39.9556, 40.5, 91][random.next(7)]
                let accuracy = [1.0, 20, 52, 75, 150, 300, 1414, 0, -1, .nan][random.next(10)]
                let age = [0.0, 30, 60, 120, 300, -1, -30][random.next(7)]
                let generated = CLLocation(coordinate: .init(latitude: latitude, longitude: -75.16),
                    altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 1, timestamp: now.addingTimeInterval(-age))
                let location = iteration % 11 == 0 ? previous ?? generated : generated
                previous = location
                let message = "seed=\(seed), iteration=\(iteration)"
                if iteration % 23 == 0 {
                    route = SharedRouteCoordinator.reverse(expectedRevision: route.revision, selectionLocation: location,
                        stations: stations, now: now, directory: directory)!
                    precondition(route.manual, message)
                }
                let before = route
                let gate = SharedRouteCoordinator.checkArrival(expectedRevision: route.revision,
                    location: location, stations: stations, now: now, directory: directory)
                route = SharedRouteCoordinator.current(directory: directory)!
                precondition(route.originId == before.originId && route.destinationId == before.destinationId,
                    "Observation changed route without a commit: \(message)")
                precondition(route.manual == before.manual && route.revision == before.revision, message)
                if !CLLocationCoordinate2DIsValid(location.coordinate) || location.horizontalAccuracy <= 0
                    || location.horizontalAccuracy > 300 || !(0...60).contains(now.timeIntervalSince(location.timestamp)) {
                    precondition(gate?.confirmed != true, "Invalid fix confirmed arrival: \(message)")
                }
                if gate?.confirmed == true {
                    let destination = stations.first { $0.id == route.destinationId }!
                    let distance = location.distance(from: destination.location)
                    precondition(!gate!.usedNearestStationFallback, message)
                    precondition(distance + location.horizontalAccuracy <= 150, message)
                    precondition(location.horizontalAccuracy <= 50, message)
                    precondition(gate!.lastDecision.contains("geofence") || (location.speed >= 0 && location.speed <= 0.5), message)
                    precondition((0...15).contains(now.timeIntervalSince(location.timestamp)), message)
                    let returnId = SharedWidgetRouteMemory.returnDestination(arrivingAt: destination.id,
                        currentOrigin: route.originId, savedOrigin: route.savedOriginId, savedDestination: route.savedDestinationId)
                    let committed = SharedRouteCoordinator.commit(originId: destination.id, destinationId: returnId,
                        expectedRevision: route.revision, arrival: true, observationAt: location.timestamp,
                        now: now, directory: directory)!
                    if location.timestamp <= route.updatedAt { precondition(committed == route, message) }
                    route = committed
                }
                if route.manual {
                    let guarded = SharedRouteCoordinator.commit(originId: route.destinationId, destinationId: route.originId,
                        expectedRevision: route.revision, observationAt: now, now: now, directory: directory)!
                    precondition(guarded == route, "Automatic fix erased manual choice: \(message)")
                }
                if !LocationGuidancePolicy.isUsable(location, now: now) || location.horizontalAccuracy > 75 {
                    let result = SharedRouteCoordinator.resolve(location: location, stations: stations, now: now, directory: directory)!
                    precondition(result.revision == route.revision && result.manual == route.manual, message)
                    route = result
                }
                let stale = SharedRouteCoordinator.reverse(expectedRevision: route.revision - 1, now: now, directory: directory)!
                precondition(stale == route && route.originId != route.destinationId, message)
                route = SharedRouteCoordinator.current(directory: directory)!
            }
        }
        // Force the invalid-coordinate case even when random sampling does not land on the destination.
        var gate = DestinationArrivalGate()
        let invalid = CLLocation(coordinate: .init(latitude: 91, longitude: -75.16), altitude: 0,
            horizontalAccuracy: 20, verticalAccuracy: 1, timestamp: base)
        precondition(!gate.accepts(destinationId: "B", station: stations[2].location, location: invalid, now: base))
        print("Location randomized checks passed: 2000 seeded transitions, duplicates, reordering, invalid fixes and manual protection")
    }
}
