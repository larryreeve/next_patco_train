#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct DestinationGeofenceCheck {
    static func run() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let stations = [("A", 39.98), ("C", 39.965), ("B", 39.95)].map { id, latitude in
            Station(id: id, code: id, name: id, latitude: latitude, longitude: -75.16, zone: "1", url: "")
        }
        func fix(_ t: Double, offset: Double, speed: Double = 18, accuracy: Double = 10) -> CLLocation {
            CLLocation(coordinate: .init(latitude: 39.95 + offset / 111_195, longitude: -75.16),
                altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 1, course: 0, speed: speed,
                timestamp: base.addingTimeInterval(t))
        }
        func accept(_ gate: inout DestinationArrivalGate, _ t: Double, offset: Double,
                    speed: Double = 18, accuracy: Double = 10, other: Double = 1000, suppressed: Bool = false) -> Bool {
            gate.accepts(destinationId: "B", station: stations[2].location,
                location: fix(t, offset: offset, speed: speed, accuracy: accuracy),
                nearestOtherStationDistance: other, routeSelectedAt: base,
                now: base.addingTimeInterval(t), arrivalSuppressed: suppressed)
        }
        for speed in [18.0, -1, 0] {
            var gate = DestinationArrivalGate()
            XCTAssertTrue(!accept(&gate, 1, offset: 250, speed: speed))
            XCTAssertTrue(accept(&gate, 2, offset: 100, speed: speed), "Entry needs neither stopped speed nor dwell")
            XCTAssertTrue(gate.lastDecision.contains("geofence"))
            XCTAssertTrue(!accept(&gate, 2, offset: 100, speed: speed), "Duplicate fix cannot confirm twice")
        }
        for scenario in ["poor", "outside", "ambiguous", "suppressed", "expired"] {
            var gate = DestinationArrivalGate()
            XCTAssertTrue(!accept(&gate, 1, offset: 250))
            XCTAssertTrue(!accept(&gate, scenario == "expired" ? 5500 : 2,
                offset: scenario == "outside" ? 145 : 100,
                accuracy: scenario == "poor" ? 285 : 10,
                other: scenario == "ambiguous" ? 130 : 1000, suppressed: scenario == "suppressed"), scenario)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for widget in [false, true] {
            let directory = root.appendingPathComponent(widget ? "widget" : "app")
            let original = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true, now: base, directory: directory)!
            if widget {
                _ = SharedRouteCoordinator.resolveWidgetRoute(location: fix(1, offset: 250), stations: stations, now: base.addingTimeInterval(1), directory: directory)
                let arrived = SharedRouteCoordinator.resolveWidgetRoute(location: fix(2, offset: 100), stations: stations, now: base.addingTimeInterval(2), directory: directory)!
                XCTAssertTrue(arrived.originId == "B" && arrived.destinationId == "A")
            } else {
                _ = SharedRouteCoordinator.checkArrival(expectedRevision: original.revision, location: fix(1, offset: 250), stations: stations, now: base.addingTimeInterval(1), directory: directory)
                XCTAssertTrue(SharedRouteCoordinator.checkArrival(expectedRevision: original.revision,
                    location: fix(2, offset: 100), stations: stations, now: base.addingTimeInterval(2), directory: directory)!.confirmed)
            }
        }
        let original = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true, now: base, directory: root)!
        XCTAssertTrue(SharedRouteCoordinator.destinationRegionEntered(stationId: "C", expectedRevision: original.revision,
            stations: stations, now: base.addingTimeInterval(1), directory: root) == original)
        let arrived = SharedRouteCoordinator.destinationRegionEntered(stationId: "B", expectedRevision: original.revision,
            stations: stations, now: base.addingTimeInterval(1), directory: root)!
        XCTAssertTrue(arrived.originId == "B" && arrived.destinationId == "A" && arrived.lastLocationAt == nil)
        XCTAssertTrue(SharedRouteCoordinator.destinationRegionEntered(stationId: "B", expectedRevision: original.revision,
            stations: stations, now: base.addingTimeInterval(2), directory: root) == arrived)
        let blocked = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true,
            selectionLocation: fix(3, offset: 0), destinationLocation: stations[2].location,
            now: base.addingTimeInterval(3), directory: root)!
        XCTAssertTrue(SharedRouteCoordinator.destinationRegionEntered(stationId: "B", expectedRevision: blocked.revision,
            stations: stations, now: base.addingTimeInterval(4), directory: root) == blocked)
        SharedRouteCoordinator.destinationRegionExited(stationId: "B", expectedRevision: blocked.revision, directory: root)
        XCTAssertTrue(SharedRouteCoordinator.destinationRegionEntered(stationId: "B", expectedRevision: blocked.revision,
            stations: stations, now: base.addingTimeInterval(5), directory: root)!.originId == "B")
        print("Destination geofence checks passed: moving/unknown-speed entry, app/widget persistence, native events, stale revisions, suppression and duplicate protection")
    }
}
