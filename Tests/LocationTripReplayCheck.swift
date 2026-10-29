#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct LocationTripReplayCheck {
    struct Replay: Decodable { let name: String; let source: String; let events: [Event] }
    struct Event: Decodable {
        let seconds: Double
        let action: String
        let latitude: Double?
        let accuracy: Double?
        let age: Double?
        let speed: Double?
        let origin: String
        let destination: String
    }
    static func run() throws {
        let fixtures = try JSONDecoder().decode([Replay].self, from: Data(contentsOf:
            URL(fileURLWithPath: "Tests/Fixtures/location-trip-replays.json")))
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let stations = [("A", 39.98), ("C", 39.965), ("B", 39.95)].map { id, latitude in
            Station(id: id, code: id, name: id, latitude: latitude, longitude: -75.16, zone: "1", url: "")
        }
        for fixture in fixtures {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var route = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", now: base, directory: directory)!
            var previousLocation: CLLocation?
            var presence = StationStopEvidence()
            for event in fixture.events {
                let now = base.addingTimeInterval(event.seconds)
                switch event.action {
                case "relaunch":
                    route = SharedRouteCoordinator.current(directory: directory)!
                    presence = StationStopEvidence()
                case "reverse":
                    route = SharedRouteCoordinator.reverse(expectedRevision: route.revision, selectionLocation: previousLocation,
                        stations: stations, now: now, directory: directory)!
                case "reading":
                    let location = CLLocation(coordinate: .init(latitude: event.latitude!, longitude: -75.16),
                        altitude: 0, horizontalAccuracy: event.accuracy ?? 20, verticalAccuracy: 1, course: 0, speed: event.speed ?? 0,
                        timestamp: now.addingTimeInterval(-(event.age ?? 0)))
                    previousLocation = location
                    SharedRouteCoordinator.observeDeparture(location: location, stations: stations, now: now, directory: directory)
                    let gate = SharedRouteCoordinator.checkArrival(expectedRevision: route.revision,
                        location: location, stations: stations, now: now, directory: directory)!
                    route = SharedRouteCoordinator.current(directory: directory)!
                    if gate.confirmed {
                        let destination = SharedWidgetRouteMemory.returnDestination(arrivingAt: route.destinationId,
                            currentOrigin: route.originId, savedOrigin: route.savedOriginId, savedDestination: route.savedDestinationId)
                        route = SharedRouteCoordinator.commit(originId: route.destinationId, destinationId: destination,
                            expectedRevision: route.revision, arrival: true, observationAt: location.timestamp,
                            now: now, directory: directory)!
                    } else {
                        if route.temporaryRoute != nil {
                            route = SharedRouteCoordinator.restoreStationRoute(expectedRevision: route.revision,
                                departureLocation: location, requireDeparture: true, stations: stations, now: now, directory: directory)!
                        }
                        if route.temporaryRoute == nil,
                           let station = LocationGuidancePolicy.detectedStation(location, stations: stations, now: now),
                           presence.accepts(stationId: station.id, station: station.location,
                               location: location, allowMissingSpeed: true, now: now),
                           station.id != route.originId && station.id != route.destinationId {
                            route = SharedRouteCoordinator.selectStationDepartures(expectedRevision: route.revision,
                                originId: station.id, destinationId: route.destinationId, stations: stations,
                                selectionLocation: location, automatic: true, now: now, directory: directory)!
                        }
                        if LocationGuidancePolicy.detectedStation(location, stations: stations, now: now) == nil {
                            presence = StationStopEvidence()
                        }
                    }
                default: XCTFail("Unknown replay action: \(event.action)")
                }
                XCTAssertTrue(route.originId == event.origin && route.destinationId == event.destination,
                    "\(fixture.name), t=\(event.seconds): \(route.originId)->\(route.destinationId), expected \(event.origin)->\(event.destination)")
            }
        }
        print("Location trip replay checks passed: \(fixtures.count) complete multi-event trips")
    }
}
