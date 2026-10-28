import Foundation
import CoreLocation

@main
struct ReturnDirectionCheck {
    static func main() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let stations = [("A", 39.98), ("C", 39.965), ("B", 39.95)].map { id, lat in
            Station(id: id, code: id, name: id, latitude: lat, longitude: -75.16, zone: "1", url: "")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func fix(_ seconds: Double, latitude: Double, accuracy: Double = 20, age: Double = 0) -> CLLocation {
            CLLocation(coordinate: .init(latitude: latitude, longitude: -75.16), altitude: 0,
                horizontalAccuracy: accuracy, verticalAccuracy: 1, course: -1, speed: -1,
                timestamp: base.addingTimeInterval(seconds - age))
        }
        func recover(_ revision: Int, _ location: CLLocation?, at seconds: Double, directory: URL) -> SharedRouteCoordinator.Route {
            SharedRouteCoordinator.recoverReturnDirection(expectedRevision: revision, location: location,
                stations: stations, now: base.addingTimeInterval(seconds), directory: directory)!
        }
        for temporary in [false, true] {
            let directory = root.appendingPathComponent("trip-\(temporary)")
            var route = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true,
                now: base, directory: directory)!
            route = recover(route.revision, fix(1, latitude: 39.98), at: 1, directory: directory)
            if temporary {
                route = SharedRouteCoordinator.selectStationDepartures(expectedRevision: route.revision,
                    originId: "C", destinationId: "B", stations: stations, automatic: true,
                    now: base.addingTimeInterval(5), directory: directory)!
                route = SharedRouteCoordinator.restoreStationRoute(expectedRevision: route.revision,
                    now: base.addingTimeInterval(6), directory: directory)!
            }
            let revision = route.revision
            // A reliable destination visit followed by increasing distance, with speed unavailable.
            route = recover(revision, fix(80, latitude: 39.9505), at: 80, directory: directory)
            let near = fix(100, latitude: 39.9527, accuracy: 49)
            route = recover(revision, near, at: 100, directory: directory)
            precondition(route.revision == revision)
            let candidateEvidence = route.returnDirectionEvidence!
            route = recover(revision, near, at: 110, directory: directory)
            precondition(route.revision == revision, "Duplicate callbacks must not advance evidence")
            precondition(route.returnDirectionEvidence == candidateEvidence)
            route = recover(revision, near, at: 131, directory: directory)
            precondition(route.revision == revision && route.returnDirectionEvidence == candidateEvidence,
                "A cached timestamp-100 fix replayed when stale must not clear the departure candidate")
            route = SharedRouteCoordinator.current(directory: directory)!
            precondition(route.returnDirectionEvidence == candidateEvidence)
            route = recover(revision, fix(140, latitude: 39.9556, accuracy: 49), at: 140, directory: directory)
            precondition(route.originId == "B" && route.destinationId == "A" && route.revision == revision + 1)
            precondition(route.arrivalGate == nil && route.temporaryRoute == nil)
            precondition(route.reason == "Return direction recovered; station arrival unconfirmed")
            let returned = recover(route.revision, fix(150, latitude: 39.9556), at: 150, directory: directory)
            precondition(returned.revision == route.revision, "Recovery must not oscillate")
        }
        for (name, bad, wallTime) in [
            ("new-stale", fix(110, latitude: 39.9527), 141.0),
            ("new-coarse", fix(110, latitude: 39.9527, accuracy: 76), 110.0),
            ("new-invalid-coordinate", fix(110, latitude: 91), 110.0)
        ] {
            let directory = root.appendingPathComponent(name)
            var route = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true,
                now: base, directory: directory)!
            let revision = route.revision
            for (seconds, latitude) in [(1.0, 39.98), (80, 39.9505), (100, 39.9527)] {
                route = recover(revision, fix(seconds, latitude: latitude), at: seconds, directory: directory)
                precondition(route.revision == revision)
            }
            let candidateEvidence = route.returnDirectionEvidence!
            route = recover(revision, bad, at: wallTime, directory: directory)
            precondition(route.revision == revision && route.returnDirectionEvidence != candidateEvidence,
                "Genuinely new \(name) fixes must reset departure evidence")
            route = SharedRouteCoordinator.current(directory: directory)!
            route = recover(revision, fix(150, latitude: 39.9556), at: 150, directory: directory)
            precondition(route.revision == revision, "A new valid fix must restart, not reuse, the discarded candidate")
            route = recover(revision, fix(160, latitude: 39.9575), at: 160, directory: directory)
            precondition(route.revision == revision + 1 && route.originId == "B" && route.destinationId == "A",
                "New outward observations may recover after \(name) evidence was discarded")
        }
        // The evidence object itself must ignore duplicates before checking their freshness or quality.
        var cachedEvidence = ReturnDirectionEvidence()
        for (seconds, latitude) in [(1.0, 39.98), (80, 39.9505), (100, 39.9527)] {
            precondition(!cachedEvidence.accepts(location: fix(seconds, latitude: latitude), origin: stations[0].location,
                destination: stations[2].location, selectedAt: base, now: base.addingTimeInterval(seconds)))
        }
        let beforeReplay = cachedEvidence
        for replay in [fix(100, latitude: 39.9527), fix(100, latitude: 91), fix(99, latitude: 39.98)] {
            precondition(!cachedEvidence.accepts(location: replay, origin: stations[0].location,
                destination: stations[2].location, selectedAt: base, now: base.addingTimeInterval(131)))
            precondition(cachedEvidence == beforeReplay, "Duplicate or older fixes cannot change departure evidence")
        }
        precondition(cachedEvidence.accepts(location: fix(140, latitude: 39.9556), origin: stations[0].location,
            destination: stations[2].location, selectedAt: base, now: base.addingTimeInterval(140)))
        for scenario in 0..<12 {
            let directory = root.appendingPathComponent("rejected-\(scenario)")
            var route = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true,
                now: base, directory: directory)!
            if scenario != 0 {
                route = recover(route.revision, fix(1, latitude: 39.98), at: 1, directory: directory)
            }
            if scenario == 1 {
                // A new explicit choice discards the prior journey's evidence.
                route = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true,
                    now: base.addingTimeInterval(50), directory: directory)!
            }
            let revision = route.revision
            if scenario != 9 {
                route = recover(revision, fix(80, latitude: 39.9505), at: 80, directory: directory)
            }
            for second in [100.0, 110] {
                let observedAt = scenario == 8 ? second + 50_000 : second
                let latitude = scenario == 4 ? 39.965 : scenario == 5 ? 39.962
                    : scenario == 10 ? (second == 100 ? 39.9556 : 39.9527)
                    : scenario == 11 ? 39.9556 : (second == 100 ? 39.9527 : 39.9556)
                let location = fix(observedAt, latitude: latitude,
                    accuracy: scenario == 2 ? 1414 : scenario == 3 ? 76 : 20,
                    age: scenario == 6 ? 100 : 0)
                route = recover(scenario == 7 ? revision - 1 : revision, location,
                    at: observedAt, directory: directory)
            }
            precondition(route.revision == revision && route.originId == "A", "Unsafe recovery scenario \(scenario)")
        }
        // An approaching train must never recover, even after passing through a GPS boundary reading.
        var evidence = ReturnDirectionEvidence()
        precondition(!evidence.accepts(location: fix(1, latitude: 39.98), origin: stations[0].location,
            destination: stations[2].location, selectedAt: base, now: base.addingTimeInterval(1)))
        for (second, latitude) in [(80.0, 39.9505), (100, 39.9556), (110, 39.9546), (120, 39.9536), (130, 39.9527)] {
            precondition(!evidence.accepts(location: fix(second, latitude: latitude), origin: stations[0].location,
                destination: stations[2].location, selectedAt: base, now: base.addingTimeInterval(second)))
        }
        // Old persisted evidence must not inherit destination/departure proof from the previous rule.
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence)) as! [String: Any]
        for key in ["destinationSeenAt", "candidateDistance", "candidateAccuracy"] { legacy.removeValue(forKey: key) }
        evidence = try JSONDecoder().decode(ReturnDirectionEvidence.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(!evidence.accepts(location: fix(140, latitude: 39.9556), origin: stations[0].location,
            destination: stations[2].location, selectedAt: base, now: base.addingTimeInterval(140)))
        print("Return direction checks passed: destination visit and departure, stale cached replay, new bad-fix resets, approach/stationary rejection, legacy evidence, duplicates, manual reset, revision races and expiry")
    }
}
