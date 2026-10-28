import Foundation
import CoreLocation

@main
struct WidgetReturnDirectionCheck {
    static func main() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let stations = [("A", 39.98), ("C", 39.965), ("B", 39.95)].map { id, lat in
            Station(id: id, code: id, name: id, latitude: lat, longitude: -75.16, zone: "1", url: "")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func fix(_ seconds: Double, latitude: Double, accuracy: Double = 20, speed: Double = -1) -> CLLocation {
            CLLocation(coordinate: .init(latitude: latitude, longitude: -75.16), altitude: 0,
                horizontalAccuracy: accuracy, verticalAccuracy: 1, course: -1, speed: speed,
                timestamp: base.addingTimeInterval(seconds))
        }
        func select(_ directory: URL, at seconds: Double = 0) -> SharedRouteCoordinator.Route {
            SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true,
                now: base.addingTimeInterval(seconds), directory: directory)!
        }
        func update(_ directory: URL, _ location: CLLocation?, at seconds: Double) -> SharedRouteCoordinator.Route {
            SharedRouteCoordinator.resolveWidgetRoute(location: location, stations: stations,
                now: base.addingTimeInterval(seconds), directory: directory)!
        }
        let trip = root.appendingPathComponent("trip")
        let original = select(trip)
        _ = update(trip, fix(1, latitude: 39.98), at: 1)
        precondition(update(trip, fix(50, latitude: 39.965), at: 50).revision == original.revision)
        // Coarser proximity evidence exercises recovery rather than the new geofence entry path.
        _ = update(trip, fix(80, latitude: 39.9505, accuracy: 60), at: 80)
        let near = fix(100, latitude: 39.9527)
        precondition(update(trip, near, at: 100).revision == original.revision)
        precondition(update(trip, near, at: 110).revision == original.revision)
        let recovered = update(trip, fix(110, latitude: 39.9556), at: 110)
        precondition(recovered.originId == "B" && recovered.destinationId == "A")
        precondition(recovered.revision == original.revision + 1)
        precondition(recovered.reason == "Return direction recovered; station arrival unconfirmed")
        precondition(SharedRouteCoordinator.current(directory: trip) == recovered)
        precondition(update(trip, fix(120, latitude: 39.9556), at: 120).revision == recovered.revision)

        for scenario in ["no-origin", "no-destination", "approaching", "stationary", "stale", "inaccurate", "manual-reset", "long-gap", "missing-location"] {
            let directory = root.appendingPathComponent(scenario)
            var route = select(directory)
            if scenario != "no-origin" { _ = update(directory, fix(1, latitude: 39.98), at: 1) }
            if scenario != "no-destination" { _ = update(directory, fix(80, latitude: 39.9505, accuracy: 60), at: 80) }
            if scenario == "manual-reset" { route = select(directory, at: 90) }
            _ = update(directory, fix(100, latitude: ["approaching", "stationary"].contains(scenario) ? 39.9556 : 39.9527,
                accuracy: scenario == "inaccurate" ? 76 : 20),
                at: scenario == "stale" ? 140 : 100)
            if scenario == "missing-location" { _ = update(directory, nil, at: 105) }
            let second = scenario == "long-gap" ? 170.0 : 110.0
            let unchanged = update(directory, fix(second, latitude: scenario == "approaching" ? 39.9527 : 39.9556,
                accuracy: scenario == "inaccurate" ? 76 : 20), at: scenario == "stale" ? second + 40 : second)
            precondition(unchanged.revision == route.revision, "Unsafe widget recovery: \(scenario)")
        }

        let stopped = root.appendingPathComponent("confirmed-arrival")
        _ = select(stopped)
        _ = update(stopped, fix(1, latitude: 39.98), at: 1)
        _ = update(stopped, fix(100, latitude: 39.95, speed: 0), at: 100)
        let arrived = update(stopped, fix(110, latitude: 39.95, speed: 0), at: 110)
        precondition(arrived.reason == "Background arrival" && arrived.revision == 2)

        let source = try String(contentsOfFile: "NextPATCOTrainWidget/NextPATCOTrainWidget.swift", encoding: .utf8)
        precondition(source.contains("SharedRouteCoordinator.resolveWidgetRoute(location: currentLocation"))
        precondition(source.contains("NextPATCOTrainWidgetProvider().selectedRoute(in: store, currentLocation: currentLocation,"))
        print("Widget return-direction checks passed: recovery, duplicates, intermediate stops, stale/coarse fixes, manual reset, gaps, missing location, shared state and arrival precedence")
    }
}
