import Foundation
import CoreLocation

@main
struct CompassFallbackCheck {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = try JSONDecoder().decode(PATCOFeed.self,
            from: Data(contentsOf: URL(fileURLWithPath: "NextPATCOTrain/Resources/patco_schedule.json")))
        let ashland = feed.stops.first { $0.name == "Ashland" }!
        let locust = feed.stops.first { $0.name.contains("15/16") }!
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func fix(ageAtTap: Double, accuracy: Double = 16 * 0.3048,
                 coordinate: CLLocationCoordinate2D = .init(latitude: 39.752993, longitude: -75.099895)) -> CLLocation {
            CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: accuracy,
                verticalAccuracy: 1, timestamp: base.addingTimeInterval(-ageAtTap))
        }
        func scenario(_ name: String, age: Double, elapsed: Double, accuracy: Double = 16 * 0.3048,
                      stations: [Station]? = nil, coordinate: CLLocationCoordinate2D? = nil,
                      expected: NearestStationSelectionRequest.Outcome?, fallback: Bool = false) {
            let directory = root.appendingPathComponent(name)
            let route = SharedRouteCoordinator.commit(originId: ashland.id, destinationId: locust.id,
                manual: true, now: base.addingTimeInterval(-60), directory: directory)!
            var request = NearestStationSelectionRequest(expectedRevision: route.revision, requestedAt: base)
            let reading = fix(ageAtTap: age, accuracy: accuracy,
                coordinate: coordinate ?? .init(latitude: 39.752993, longitude: -75.099895))
            let outcome = request.poll(location: reading, authorization: .authorizedAlways, isForeground: true,
                isViewingToday: true, stations: stations ?? feed.stops, now: base.addingTimeInterval(elapsed), directory: directory)
            if let expected {
                precondition(outcome == expected, "\(name): \(outcome)")
                precondition(SharedRouteCoordinator.current(directory: directory) == route)
            } else {
                guard case .selected(let selected) = outcome else { preconditionFailure("\(name): \(outcome)") }
                let nearer = [ashland, locust].min { reading.distance(from: $0.location) < reading.distance(from: $1.location) }!
                let other = nearer.id == ashland.id ? locust : ashland
                precondition(selected.originId == nearer.id && selected.destinationId == other.id)
                precondition(Set([selected.savedOriginId, selected.savedDestinationId]) == Set([ashland.id, locust.id]))
                precondition(selected.manual && selected.revision == route.revision + 1)
                precondition(request.usedRecentLocationFallback == fallback)
            }
        }
        // Reproduce the photo's position and accuracy with no post-tap GPS callback.
        scenario("initial wait", age: 0.1, elapsed: 1.999, expected: .waiting)
        scenario("stationary reuse", age: 0.1, elapsed: 2, expected: nil, fallback: true)
        scenario("fresh preferred", age: -1, elapsed: 1, expected: nil)
        scenario("early age boundary", age: 8, elapsed: 2, accuracy: 75, expected: nil, fallback: true)
        scenario("early too old", age: 8.001, elapsed: 2, expected: .waiting)
        scenario("deadline fallback", age: 22, elapsed: 8, expected: nil, fallback: true)
        scenario("deadline stale", age: 22.001, elapsed: 8, expected: .staleLocation)
        scenario("deadline inaccurate", age: 0.1, elapsed: 8, accuracy: 75.001, expected: .inaccurateLocation)
        scenario("future fix", age: -9, elapsed: 8, expected: .invalidLocation)
        scenario("no stations", age: 0.1, elapsed: 8, stations: [], expected: .stationsUnavailable)
        scenario("overdue request", age: 0.1, elapsed: 10, expected: .timedOut)
        scenario("at origin", age: -1, elapsed: 1, coordinate: ashland.coordinate, expected: nil)
        scenario("at destination", age: -1, elapsed: 1, coordinate: locust.coordinate, expected: nil)
        let intermediate = feed.stops.first { $0.name == "Ferry Avenue" }!
        scenario("intermediate station preserves endpoints", age: -1, elapsed: 1,
            coordinate: intermediate.coordinate, expected: nil)
        scenario("missing endpoint", age: 0.1, elapsed: 8, stations: [ashland], expected: .stationsUnavailable)
        let midpoint = CLLocationCoordinate2D(latitude: (ashland.latitude + locust.latitude) / 2,
            longitude: (ashland.longitude + locust.longitude) / 2)
        scenario("ambiguous station", age: 0.1, elapsed: 8, coordinate: midpoint, expected: .ambiguousStation)
        // Repeated taps at either endpoint must not toggle back or replace the station pair.
        let repeatDirectory = root.appendingPathComponent("repeat direction")
        var repeated = SharedRouteCoordinator.commit(originId: ashland.id, destinationId: locust.id,
            manual: true, now: base.addingTimeInterval(-60), directory: repeatDirectory)!
        for (index, endpoint) in [locust, locust, ashland, ashland].enumerated() {
            let time = base.addingTimeInterval(Double(index))
            let reading = CLLocation(coordinate: endpoint.coordinate, altitude: 0,
                horizontalAccuracy: 5, verticalAccuracy: 1, timestamp: time)
            repeated = SharedRouteCoordinator.selectNearestStation(expectedRevision: repeated.revision,
                location: reading, stations: feed.stops, now: time, directory: repeatDirectory)!
            precondition(repeated.originId == endpoint.id)
            precondition(repeated.destinationId == (endpoint.id == ashland.id ? locust.id : ashland.id))
            precondition(Set([repeated.savedOriginId, repeated.savedDestinationId]) == Set([ashland.id, locust.id]))
        }
        // A manual route change wins over a pending fallback request.
        let directory = root.appendingPathComponent("manual race")
        let initial = SharedRouteCoordinator.commit(originId: ashland.id, destinationId: locust.id,
            manual: true, now: base.addingTimeInterval(-60), directory: directory)!
        var request = NearestStationSelectionRequest(expectedRevision: initial.revision, requestedAt: base)
        let manual = SharedRouteCoordinator.reverse(expectedRevision: initial.revision, now: base, directory: directory)!
        let outcome = request.poll(location: fix(ageAtTap: 0.1), authorization: .authorizedAlways,
            isForeground: true, isViewingToday: true, stations: feed.stops, now: base.addingTimeInterval(2), directory: directory)
        precondition(outcome == .routeChanged && SharedRouteCoordinator.current(directory: directory) == manual)
        precondition(NearestStationSelectionRequest.Outcome.ambiguousStation.failureMessage
            != NearestStationSelectionRequest.Outcome.timedOut.failureMessage)
        print("Compass fallback checks passed: reported position, stationary fixes, age/accuracy limits, ambiguity and route races")
    }
}
