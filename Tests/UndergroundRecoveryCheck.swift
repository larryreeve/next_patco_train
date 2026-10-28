import Foundation
import CoreLocation

@main
struct UndergroundRecoveryCheck {
    static func main() throws {
        let feed = try JSONDecoder().decode(PATCOFeed.self,
            from: Data(contentsOf: URL(fileURLWithPath: "NextPATCOTrain/Resources/patco_schedule.json")))
        let stations = feed.stops
        let origin = stations.first { $0.code == "2" }!
        let destination = stations.first { $0.code == "14" }!
        let neighbor = stations.first { $0.code == "13" }!
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func fix(_ seconds: Double, station: Station = destination, north: Double = 330, east: Double = 0,
                 accuracy: Double = 8, speed: Double = 0, age: Double = 0) -> CLLocation {
            CLLocation(coordinate: .init(latitude: station.latitude + north / 111_195,
                longitude: station.longitude + east / (111_195 * cos(station.latitude * .pi / 180))),
                altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 1, course: -1, speed: speed,
                timestamp: base.addingTimeInterval(seconds - age))
        }
        func select(_ directory: URL, at seconds: Double = 0, target: Station = destination) -> SharedRouteCoordinator.Route {
            SharedRouteCoordinator.commit(originId: origin.id, destinationId: target.id, manual: true,
                now: base.addingTimeInterval(seconds), directory: directory)!
        }
        func update(_ directory: URL, _ location: CLLocation?, at seconds: Double, widget: Bool) -> SharedRouteCoordinator.Route {
            if widget {
                return SharedRouteCoordinator.resolveWidgetRoute(location: location, stations: stations,
                    now: base.addingTimeInterval(seconds), directory: directory)!
            }
            let current = SharedRouteCoordinator.current(directory: directory)!
            _ = SharedRouteCoordinator.checkArrival(expectedRevision: current.revision, location: location,
                stations: stations, now: base.addingTimeInterval(seconds), directory: directory)
            return SharedRouteCoordinator.recoverReturnDirection(expectedRevision: current.revision, location: location,
                stations: stations, now: base.addingTimeInterval(seconds), directory: directory)!
        }
        var distantExit = UndergroundExitEvidence()
        precondition(!distantExit.accepts(location: fix(0, north: 582, accuracy: 14, speed: 0.7),
            destination: destination, stations: stations, now: base))
        precondition(distantExit.decision.contains("exceeds 500 m"),
            "Distant exit readings must identify the range rejection, not blame the rail corridor")
        for mode in ["app", "widget", "mixed"] {
            let directory = root.appendingPathComponent(mode)
            let selected = select(directory)
            _ = update(directory, fix(1, station: origin, north: 0, speed: 10), at: 1, widget: mode == "widget")
            _ = update(directory, fix(60, north: 0, accuracy: 1414, speed: -1), at: 60, widget: true)
            _ = update(directory, nil, at: 80, widget: true)
            for (index, seconds) in [100.0, 110, 120, 130].enumerated() {
                let location = fix(seconds, north: 330 + Double(index) * 5, speed: 0.5)
                precondition(location.distance(from: destination.location) > 150)
                let route = update(directory, location, at: seconds,
                    widget: mode == "widget" || (mode == "mixed" && index % 2 == 0))
                precondition(route.revision == selected.revision + (index == 3 ? 1 : 0),
                    "\(mode) must wait for four distinct fixes spanning 30 seconds outside the corridor")
                if index < 3 {
                    let evidence = route.returnDirectionEvidence
                    let replay = update(directory, location, at: seconds + 9, widget: true)
                    precondition(replay.returnDirectionEvidence == evidence, "Replays cannot advance exit evidence")
                }
            }
            let recovered = SharedRouteCoordinator.current(directory: directory)!
            precondition(recovered.originId == destination.id && recovered.destinationId == origin.id)
            precondition(recovered.reason == "Return direction recovered; station arrival unconfirmed")
            precondition(recovered.arrivalGate == nil && recovered.temporaryRoute == nil)
            precondition(update(directory, fix(140), at: 140, widget: true).revision == recovered.revision)
        }

        for scenario in ["no-journey", "manual-reset", "expired-journey", "train-speed", "missing-speed",
                         "inaccurate", "stale", "approach", "slow-train", "stopped-train", "ambiguous",
                         "neighbor-exit", "too-far", "long-gaps", "duplicates", "implied-speed", "missing-neighbor"] {
            let directory = root.appendingPathComponent(scenario)
            var selected = select(directory)
            if scenario != "no-journey" {
                _ = update(directory, fix(1, station: origin, north: 0), at: 1, widget: true)
            }
            if scenario == "manual-reset" { selected = select(directory, at: 90) }
            for index in 0..<4 {
                let seconds = (scenario == "expired-journey" ? 5500.0 : 100)
                    + Double(index) * (scenario == "long-gaps" ? 21 : 10)
                let north: Double = scenario == "approach" ? 100 - Double(index) * 20
                    : ["slow-train", "stopped-train"].contains(scenario) ? 0
                    : scenario == "too-far" ? 600 : scenario == "implied-speed" ? (index % 2 == 0 ? 250 : 410) : 330
                let location: CLLocation
                if scenario == "ambiguous" {
                    location = CLLocation(coordinate: .init(latitude: (destination.latitude + neighbor.latitude) / 2 + 330 / 111_195,
                        longitude: (destination.longitude + neighbor.longitude) / 2), altitude: 0,
                        horizontalAccuracy: 8, verticalAccuracy: 1, course: -1, speed: 0,
                        timestamp: base.addingTimeInterval(seconds))
                } else {
                    location = fix(scenario == "duplicates" ? 100 : seconds,
                        station: scenario == "neighbor-exit" ? neighbor : destination, north: north,
                        east: scenario == "slow-train" ? -260 - Double(index) * 10 : scenario == "stopped-train" ? -300 : 0,
                        accuracy: scenario == "inaccurate" ? 21 : 8,
                        speed: scenario == "train-speed" ? 15 : scenario == "missing-speed" ? -1
                            : ["slow-train", "approach"].contains(scenario) ? 1 : 0,
                        age: scenario == "stale" ? 16 : 0)
                }
                let route: SharedRouteCoordinator.Route
                if scenario == "missing-neighbor" {
                    route = SharedRouteCoordinator.resolveWidgetRoute(location: location,
                        stations: stations.filter { $0.id != neighbor.id }, now: base.addingTimeInterval(seconds), directory: directory)!
                } else {
                    route = update(directory, location, at: seconds, widget: index % 2 == 0)
                }
                precondition(route.revision == selected.revision + (scenario == "approach" ? 1 : 0),
                    "Only destination geofence entry may bypass underground recovery: \(scenario)")
                if scenario == "approach" { precondition(route.reason == "Background arrival") }
            }
        }

        // Losing GPS or receiving a new bad fix restarts the pedestrian window, but not the prior trip proof.
        for interruption in ["nil", "speed", "accuracy", "stale-replay"] {
            let directory = root.appendingPathComponent("interrupted-\(interruption)")
            let selected = select(directory)
            _ = update(directory, fix(1, station: origin, north: 0), at: 1, widget: true)
            let first = fix(100)
            _ = update(directory, first, at: 100, widget: true)
            if interruption == "stale-replay" {
                let evidence = SharedRouteCoordinator.current(directory: directory)!.returnDirectionEvidence
                _ = update(directory, first, at: 131, widget: true)
                precondition(SharedRouteCoordinator.current(directory: directory)!.returnDirectionEvidence == evidence)
            } else {
                _ = update(directory, interruption == "nil" ? nil : fix(105,
                    accuracy: interruption == "accuracy" ? 76 : 8, speed: interruption == "speed" ? 10 : 0),
                    at: 105, widget: true)
            }
            for (index, seconds) in [140.0, 150, 160, 170].enumerated() {
                let route = update(directory, fix(seconds), at: seconds, widget: true)
                precondition(route.revision == selected.revision + (index == 3 ? 1 : 0))
            }
        }

        // Explicit destination geofence entry now completes arrival even on a moving train.
        let through = root.appendingPathComponent("through-train")
        let selected = select(through)
        _ = update(through, fix(1, station: origin, north: 0), at: 1, widget: true)
        _ = update(through, fix(80, north: 0, speed: 10), at: 80, widget: true)
        for seconds in [100.0, 110, 120, 130] {
            precondition(update(through, fix(seconds, north: seconds * 3, speed: 10), at: seconds,
                widget: true).revision == selected.revision + 1)
        }
        // New fields must be optional when loading pre-fallback route evidence.
        let legacy = try JSONDecoder().decode(ReturnDirectionEvidence.self,
            from: Data("{\"originSideAt\":0,\"lastAt\":0}".utf8))
        precondition(legacy.undergroundDiagnostic == nil)
        precondition(!origin.supportsUndergroundReturnRecovery && destination.supportsUndergroundReturnRecovery)
        print("Underground recovery checks passed: app/widget shared evidence, tunnel GPS loss, pedestrian exit, train exclusion, ambiguity, freshness, resets, duplicates and legacy decoding")
    }
}
