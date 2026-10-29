#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct RouteTransitionCheck {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stations = [("A", 39.98), ("C", 39.965), ("B", 39.95)].map { id, latitude in
            Station(id: id, code: id, name: id, latitude: latitude, longitude: -75.16, zone: "1", url: "")
        }
        func fix(_ latitude: Double, _ seconds: Double, accuracy: Double = 20) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: -75.16),
                       altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 1, course: 0, speed: 0,
                       timestamp: now.addingTimeInterval(seconds))
        }
        var route = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", now: now, directory: root)!
        func check(_ location: CLLocation) -> DestinationArrivalGate {
            SharedRouteCoordinator.checkArrival(expectedRevision: route.revision, location: location,
                stations: stations, now: location.timestamp, directory: root)!
        }
        // A nearby coarse reading is not proof of a journey.
        XCTAssertTrue(!check(fix(39.9503, 1, accuracy: 1414)).confirmed)
        XCTAssertTrue(!check(fix(39.9556, 2, accuracy: 52)).confirmed)
        XCTAssertTrue(!check(fix(39.98, 3)).confirmed)
        XCTAssertTrue(!check(fix(39.965, 4)).confirmed)
        route = SharedRouteCoordinator.selectStationDepartures(expectedRevision: route.revision,
            originId: "C", destinationId: "B", stations: stations, automatic: true,
            now: now.addingTimeInterval(5), directory: root)!
        XCTAssertTrue(!route.manual && route.temporaryRoute?.originId == "A")
        let stationRevision = route.revision
        for reading in [nil, fix(39.965, 5.5, accuracy: 1414), fix(39.97, 5.5, accuracy: 1414)] as [CLLocation?] {
            route = SharedRouteCoordinator.restoreStationRoute(expectedRevision: stationRevision,
                departureLocation: reading, requireDeparture: true, stations: stations,
                now: now.addingTimeInterval(5.5), directory: root)!
            XCTAssertTrue(route.revision == stationRevision && route.originId == "C"
                && route.temporaryRoute?.originId == "A",
                "GPS loss alone must not count as proven physical departure")
        }
        // Reload everything from disk, as on app relaunch.
        route = SharedRouteCoordinator.current(directory: root)!
        XCTAssertTrue(route.arrivalGate != nil && route.journeySelectedAt == now)
        XCTAssertTrue(!check(fix(39.952, 6)).confirmed)
        XCTAssertTrue(!check(fix(39.952, 7)).confirmed)
        XCTAssertTrue(!check(fix(39.952, 16)).confirmed)
        XCTAssertTrue(!check(fix(39.952, 17)).usedNearestStationFallback)
        route = SharedRouteCoordinator.restoreStationRoute(expectedRevision: route.revision,
            now: now.addingTimeInterval(18), directory: root)!
        XCTAssertTrue(route.originId == "A" && route.destinationId == "B" && !route.manual)
        XCTAssertTrue(route.temporaryRoute == nil)
        XCTAssertTrue(!check(fix(39.9556, 19, accuracy: 52)).confirmed)
        // A manual reversal clears old trip evidence and remains protected after a stop.
        route = SharedRouteCoordinator.reverse(expectedRevision: route.revision,
            now: now.addingTimeInterval(20), directory: root)!
        XCTAssertTrue(route.manual && route.arrivalGate == nil && route.temporaryRoute == nil)
        route = SharedRouteCoordinator.selectStationDepartures(expectedRevision: route.revision,
            originId: "C", destinationId: "A", stations: stations, automatic: true,
            now: now.addingTimeInterval(21), directory: root)!
        route = SharedRouteCoordinator.current(directory: root)!
        let returnId = SharedWidgetRouteMemory.returnDestination(arrivingAt: "A", currentOrigin: route.originId,
            savedOrigin: route.savedOriginId, savedDestination: route.savedDestinationId)
        XCTAssertTrue(returnId == "B")
        XCTAssertTrue(SharedRouteCoordinator.restoreStationRoute(expectedRevision: route.revision - 1,
            directory: root)?.revision == route.revision)
        route = SharedRouteCoordinator.restoreStationRoute(expectedRevision: route.revision,
            now: now.addingTimeInterval(22), directory: root)!
        XCTAssertTrue(route.manual && route.originId == "B" && route.destinationId == "A")
        XCTAssertTrue(SharedRouteCoordinator.commit(originId: "A", destinationId: "B",
            expectedRevision: route.revision, directory: root)?.revision == route.revision)
        // Old route snapshots without the new optional fields still decode.
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(route)) as! [String: Any]
        for key in ["arrivalGate", "temporaryRoute", "journeySelectedAt"] { legacy.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(SharedRouteCoordinator.Route.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(decoded.arrivalGate == nil && decoded.temporaryRoute == nil)
        // Arrival on the return leg uses the saved opposite endpoint, not the temporary origin.
        route = SharedRouteCoordinator.selectStationDepartures(expectedRevision: route.revision,
            originId: "C", destinationId: "A", stations: stations, automatic: true,
            now: now.addingTimeInterval(23), directory: root)!
        XCTAssertTrue(!check(fix(39.98, 24)).confirmed)
        XCTAssertTrue(check(fix(39.98, 34)).confirmed)
        route = SharedRouteCoordinator.commit(originId: "A", destinationId: returnId,
            expectedRevision: route.revision, arrival: true, observationAt: now.addingTimeInterval(34),
            now: now.addingTimeInterval(34), directory: root)!
        XCTAssertTrue(route.originId == "A" && route.destinationId == "B" && !route.manual)
        XCTAssertTrue(route.temporaryRoute == nil && route.arrivalGate == nil)
        // Stale, future and low-accuracy readings cannot establish progress for fallback.
        for invalid in [fix(39.98, 25, accuracy: 1414), fix(39.98, 26), fix(39.98, 100)] {
            _ = SharedRouteCoordinator.checkArrival(expectedRevision: route.revision, location: invalid,
                stations: stations, now: now.addingTimeInterval(70), directory: root)
        }
        XCTAssertTrue(!check(fix(39.9503, 71, accuracy: 1414)).confirmed)
        XCTAssertTrue(!check(fix(39.9556, 85, accuracy: 52)).confirmed)
        XCTAssertTrue(SharedRouteCoordinator.checkArrival(expectedRevision: route.revision,
            location: fix(39.95, 84), stations: stations, now: now.addingTimeInterval(86),
            directory: root)?.confirmed == false)
        // Explicit route selection starts a new journey rather than inheriting prior evidence.
        route = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true,
            now: now.addingTimeInterval(90), directory: root)!
        XCTAssertTrue(route.arrivalGate == nil && route.journeySelectedAt == nil)
        _ = check(fix(40.5, 91))
        _ = check(fix(40.4, 92))
        XCTAssertTrue(!check(fix(39.9503, 93, accuracy: 1414)).confirmed)
        XCTAssertTrue(!check(fix(39.9556, 105, accuracy: 52)).confirmed)
        // UI expiry restores the original route without claiming physical departure or arrival.
        let original = SharedRouteCoordinator.current(directory: root)!
        let temporary = SharedRouteCoordinator.selectStationDepartures(expectedRevision: original.revision,
            originId: "C", destinationId: "B", stations: stations, automatic: true,
            now: now.addingTimeInterval(106), directory: root)!
        let expired = SharedRouteCoordinator.restoreStationRoute(expectedRevision: temporary.revision,
            departureLocation: nil, requireDeparture: false, stations: stations,
            now: now.addingTimeInterval(122), directory: root)!
        XCTAssertTrue(expired.originId == original.originId && expired.destinationId == original.destinationId)
        XCTAssertTrue(expired.savedOriginId == original.savedOriginId && expired.savedDestinationId == original.savedDestinationId)
        XCTAssertTrue(expired.temporaryRoute == nil && expired.arrivalGate == temporary.arrivalGate)
        XCTAssertTrue(expired.journeySelectedAt == temporary.journeySelectedAt)
        let newer = SharedRouteCoordinator.reverse(expectedRevision: expired.revision,
            now: now.addingTimeInterval(123), directory: root)!
        let staleExpiry = SharedRouteCoordinator.restoreStationRoute(expectedRevision: temporary.revision,
            now: now.addingTimeInterval(124), directory: root)!
        XCTAssertTrue(staleExpiry.revision == newer.revision && staleExpiry.originId == newer.originId)
        let source = try SourceInspection.home()
        XCTAssertTrue(source.components(separatedBy: "clearExpiredStationSelection()").count >= 5,
            "Timer, missing-location and rejected-station paths must share temporary route cleanup")
        print("Route transition checks passed")
    }
}
