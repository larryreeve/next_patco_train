#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct JourneyLocationControllerCheck {
    static func run() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stations = [("2", 39.9), ("13", 39.9955), ("14", 40.0)].map { id, lat in
            Station(id: id, code: id, name: id, latitude: lat, longitude: -75, zone: "1", url: "")
        }
        func fix(_ seconds: Double, lat: Double = 40, accuracy: Double = 5) -> CLLocation {
            CLLocation(coordinate: .init(latitude: lat, longitude: -75), altitude: 0,
                horizontalAccuracy: accuracy, verticalAccuracy: 1, course: -1, speed: 0,
                timestamp: base.addingTimeInterval(seconds))
        }
        var stationEvidence = JourneyStationEvidence()
        XCTAssertTrue(stationEvidence.station(for: fix(1), stations: stations, now: base.addingTimeInterval(1))?.id == "14")
        XCTAssertTrue(stationEvidence.station(for: fix(1), stations: stations, now: base.addingTimeInterval(17)) == nil)
        XCTAssertTrue(stationEvidence.station(for: fix(20, accuracy: 1414), stations: stations,
                                             now: base.addingTimeInterval(20)) == nil)

        let selected = SharedRouteCoordinator.commit(originId: "2", destinationId: "14", now: base, directory: directory)!
        var now = base
        var commits = 0
        var checks = 0
        var controller = JourneyArrivalController(dependencies: .init(
            current: { SharedRouteCoordinator.current(directory: directory) },
            check: { revision, location, stations, expected in
                checks += 1
                return SharedRouteCoordinator.checkArrival(expectedRevision: revision, location: location,
                    stations: stations, now: now, directory: directory, expectedArrival: expected)
            },
            commit: { origin, destination, revision, timestamp in
                commits += 1
                return SharedRouteCoordinator.commit(originId: origin, destinationId: destination,
                    expectedRevision: revision, arrival: true, observationAt: timestamp, now: now, directory: directory)
            }, record: { _, _ in }))
        func evaluate(_ location: CLLocation, today: Bool = true) -> JourneyArrivalController.Completion? {
            now = location.timestamp
            return controller.evaluate(location: location, stations: stations, station: nil,
                destinationId: "14", revision: selected.revision, expectedArrival: nil, isViewingToday: today)
        }
        XCTAssertTrue(evaluate(fix(1), today: false) == nil && checks == 0)
        XCTAssertTrue(evaluate(fix(1, lat: 39.91)) == nil)
        XCTAssertTrue(evaluate(fix(60, lat: 39.98)) == nil)
        let completed = evaluate(fix(100))!
        XCTAssertTrue(!completed.inferred && completed.station.id == "14" && completed.returnStation.id == "2")
        XCTAssertTrue(completed.route.revision == selected.revision + 1 && commits == 1)
        XCTAssertTrue(evaluate(fix(105)) == nil && commits == 1, "Duplicate callback cannot complete twice")

        // Even a confirmed gate cannot overwrite a route changed after evidence evaluation.
        var accepted = DestinationArrivalGate()
        for time in [200.0, 205.0] {
            _ = accepted.accepts(destinationId: "14", station: stations[2].location, location: fix(time),
                nearestOtherStationDistance: 450, routeSelectedAt: base, now: fix(time).timestamp)
        }
        XCTAssertTrue(accepted.confirmed)
        controller.dependencies.check = { _, _, _, _ in accepted }
        XCTAssertTrue(evaluate(fix(210)) == nil && commits == 1)
        print("Journey location controller checks passed: station quality, future planning, arrival, duplicate and stale route")
    }
}
