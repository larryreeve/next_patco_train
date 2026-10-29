#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct EstimatedArrivalCheck {
    static func run() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let origin = CLLocation(latitude: 39.9, longitude: -75)
        let destination = CLLocation(latitude: 40, longitude: -75)
        func fix(_ seconds: Double, latitude: Double = 39.9997, accuracy: Double = 1414,
                 speed: Double = -1) -> CLLocation {
            CLLocation(coordinate: .init(latitude: latitude, longitude: -75), altitude: 0,
                       horizontalAccuracy: accuracy, verticalAccuracy: 1, course: -1, speed: speed,
                       timestamp: base.addingTimeInterval(seconds))
        }
        func seeded() -> DestinationArrivalGate {
            var gate = DestinationArrivalGate()
            for location in [fix(1, latitude: 39.91, accuracy: 10), fix(60, latitude: 39.98, accuracy: 20)] {
                gate.observeJourney(origin: origin, destination: destination, location: location,
                                    selectedAt: base, now: location.timestamp)
            }
            return gate
        }
        func accept(_ gate: inout DestinationArrivalGate, _ location: CLLocation,
                    other: Double = 450, now: Date? = nil, underground: Bool = true,
                    suppressed: Bool = false) -> Bool {
            gate.accepts(destinationId: "14", station: destination, location: location,
                         nearestOtherStationDistance: other, routeSelectedAt: base,
                         now: now ?? location.timestamp, undergroundDestination: underground,
                         arrivalSuppressed: suppressed)
        }
        var gate = seeded()
        XCTAssertTrue(!accept(&gate, fix(100, latitude: 39.9991)))
        XCTAssertTrue(!accept(&gate, fix(100, latitude: 39.9991), now: base.addingTimeInterval(110)))
        // Cached tunnel readings must not erase newer destination evidence.
        XCTAssertTrue(!accept(&gate, fix(60, latitude: 39.98, accuracy: 20), now: base.addingTimeInterval(120)))
        gate = try JSONDecoder().decode(DestinationArrivalGate.self, from: JSONEncoder().encode(gate))
        XCTAssertTrue(!accept(&gate, fix(109)))
        XCTAssertTrue(accept(&gate, fix(110)))
        XCTAssertTrue(gate.usedNearestStationFallback && gate.lastDecision.contains("Estimated arrival"))
        let diagnostic = DiagnosticContext.arrival(component: "shared.arrival", route: nil, location: fix(110), gate: gate)
        XCTAssertTrue(diagnostic.decision == .accepted && diagnostic.confidence == .estimated)
        XCTAssertTrue(diagnostic.observationTimestamp == fix(110).timestamp && diagnostic.rejectionReason == nil)
        for scenario in ["no journey", "no progress", "too soon", "gap", "outside", "ambiguous",
                         "speed", "inaccurate", "stale", "future", "surface", "suppressed", "expired"] {
            var candidate = scenario == "no journey" || scenario == "no progress" ? DestinationArrivalGate() : seeded()
            if scenario == "no progress" {
                let location = fix(1, latitude: 39.91, accuracy: 10)
                candidate.observeJourney(origin: origin, destination: destination, location: location,
                                         selectedAt: base, now: location.timestamp)
            }
            XCTAssertTrue(!accept(&candidate, fix(100)))
            let seconds = scenario == "too soon" ? 109.0 : scenario == "gap" ? 191 : scenario == "expired" ? 1300 : 110
            let reading = fix(seconds, latitude: scenario == "outside" ? 39.998 : 39.9997,
                              accuracy: scenario == "inaccurate" ? 2500 : 1414,
                              speed: scenario == "speed" ? 10 : -1)
            let now = base.addingTimeInterval(seconds + (scenario == "stale" ? 16 : scenario == "future" ? -1 : 0))
            XCTAssertTrue(!accept(&candidate, reading, other: scenario == "ambiguous" ? 100 : 450,
                                now: now, underground: scenario != "surface", suppressed: scenario == "suppressed"), scenario)
        }
        var contradicted = seeded()
        XCTAssertTrue(!accept(&contradicted, fix(100)))
        XCTAssertTrue(!accept(&contradicted, fix(110, latitude: 39.995)))
        XCTAssertTrue(contradicted.lastDecision.contains("underground estimate reset: outside destination proximity radius"))
        XCTAssertTrue(!accept(&contradicted, fix(130)))
        XCTAssertTrue(accept(&contradicted, fix(160)))

        // Replay the morning's sparse destination readings: 108 m, then 47 m after 63 sec.
        for gap in [55.0, 63.0, 90.0, 91.0] {
            var sparse = seeded()
            XCTAssertTrue(!accept(&sparse, fix(100, latitude: 39.99903)))
            sparse = try JSONDecoder().decode(DestinationArrivalGate.self, from: JSONEncoder().encode(sparse))
            XCTAssertTrue(accept(&sparse, fix(100 + gap, latitude: 39.99958)) == (gap <= 90))
            XCTAssertTrue(sparse.lastDecision.contains(gap <= 90 ? "2 distinct readings" : "evidence restarted: reading gap exceeded 90 sec"))
        }
        var silent = seeded()
        XCTAssertTrue(!accept(&silent, fix(100)))
        XCTAssertTrue(!accept(&silent, fix(100), now: base.addingTimeInterval(163)), "Silence and cached fixes cannot confirm arrival")
        silent.prepareSelection(destinationId: "14", station: destination,
                                location: fix(150, latitude: 39.98, accuracy: 10), now: base.addingTimeInterval(150))
        XCTAssertTrue(!accept(&silent, fix(163)), "A route selection must discard old journey evidence")
        var changedDestination = seeded()
        XCTAssertTrue(!accept(&changedDestination, fix(100)))
        let next = fix(163)
        XCTAssertTrue(!changedDestination.accepts(destinationId: "13", station: destination, location: next,
            nearestOtherStationDistance: 450, routeSelectedAt: base, now: next.timestamp, undergroundDestination: true))
        XCTAssertTrue(changedDestination.lastDecision.contains("1 distinct readings"))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stations = [("2", 39.9), ("13", 39.9955), ("14", 40.0)].map { id, latitude in
            Station(id: id, code: id, name: id, latitude: latitude, longitude: -75, zone: "1", url: "")
        }
        var route = SharedRouteCoordinator.commit(originId: "2", destinationId: "14", now: base, directory: root)!
        for reading in [fix(1, latitude: 39.91, accuracy: 10), fix(60, latitude: 39.98, accuracy: 20), fix(100), fix(130)] {
            route = SharedRouteCoordinator.resolve(location: reading, stations: stations,
                now: reading.timestamp, directory: root)!
        }
        XCTAssertTrue(route.originId == "14" && route.destinationId == "2" && route.reason == "Estimated arrival")
        let revision = route.revision
        route = SharedRouteCoordinator.resolve(location: fix(140), stations: stations,
                                               now: base.addingTimeInterval(140), directory: root)!
        XCTAssertTrue(route.revision == revision, "Estimated arrival must reverse only once")
        route = SharedRouteCoordinator.commit(originId: "2", destinationId: "14", manual: true,
                                              now: base.addingTimeInterval(150), directory: root)!
        route = SharedRouteCoordinator.selectStationDepartures(expectedRevision: route.revision,
            originId: "13", destinationId: "14", stations: stations, automatic: true,
            now: base.addingTimeInterval(151), directory: root)!
        let tempRevision = route.revision
        route = SharedRouteCoordinator.confirmTripArrival(originId: "2", destinationId: "14",
            expectedRevision: tempRevision, now: base.addingTimeInterval(152), directory: root)!
        XCTAssertTrue(route.originId == "14" && route.destinationId == "2" && route.temporaryRoute == nil)
        XCTAssertTrue(SharedRouteCoordinator.confirmTripArrival(originId: "2", destinationId: "14",
            expectedRevision: tempRevision, directory: root)?.revision == route.revision)
        XCTAssertTrue(SharedRouteCoordinator.confirmTripArrival(originId: "2", destinationId: "14",
            expectedRevision: route.revision, directory: root)?.revision == route.revision,
            "A different selected route must not be overwritten")
        print("Estimated arrival checks passed: journey evidence, persistence, proximity, timing, rejection, reversal and manual trip completion")
    }
}
