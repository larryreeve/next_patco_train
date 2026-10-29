#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct ConservativeStationCheck {
    static func run() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let station = CLLocation(latitude: 39.95, longitude: -75.16)
        func fix(_ seconds: Double, meters: Double = 0, accuracy: Double = 20, speed: Double = 0) -> CLLocation {
            var low = 39.95, high = 40.0
            for _ in 0..<60 {
                let mid = (low + high) / 2
                if CLLocation(latitude: mid, longitude: -75.16).distance(from: station) < meters { low = mid } else { high = mid }
            }
            return CLLocation(coordinate: .init(latitude: (low + high) / 2, longitude: -75.16), altitude: 0,
                horizontalAccuracy: accuracy, verticalAccuracy: 1, course: 0, speed: speed, timestamp: base.addingTimeInterval(seconds))
        }
        func observe(_ gate: inout DestinationArrivalGate, _ reading: CLLocation, at seconds: Double,
                     otherDistance: Double = 500) -> Bool {
            gate.accepts(destinationId: "B", station: station, location: reading, nearestOtherStationDistance: otherDistance,
                routeSelectedAt: base.addingTimeInterval(-60), now: base.addingTimeInterval(seconds))
        }
        // Reconstructed distances/accuracy from Oct 6; no GPS coordinates or speed were supplied in the log.
        for (distance, accuracy) in [(281.0, 17.0), (25, 1414), (658, 871), (620, 49)] {
            var gate = DestinationArrivalGate()
            XCTAssertTrue(!observe(&gate, fix(0, meters: distance, accuracy: accuracy), at: 0))
            XCTAssertTrue(!observe(&gate, fix(10, meters: distance, accuracy: accuracy), at: 10))
        }
        for speed in [-1.0, 0.501, 1.5, 12, Double.nan, Double.infinity] {
            var gate = DestinationArrivalGate()
            XCTAssertTrue(!observe(&gate, fix(0, speed: speed), at: 0))
            XCTAssertTrue(!observe(&gate, fix(10, speed: speed), at: 10))
        }
        var gate = DestinationArrivalGate()
        XCTAssertTrue(!observe(&gate, fix(0, meters: 18, accuracy: 49), at: 0))
        XCTAssertTrue(!observe(&gate, fix(0, meters: 18, accuracy: 49), at: 10))
        XCTAssertTrue(observe(&gate, fix(10, meters: 18, accuracy: 49), at: 10))
        XCTAssertTrue(!gate.usedNearestStationFallback)
        // Lost quality, ambiguous station, elapsed gaps, and motion each restart the dwell window.
        for bad in [fix(5, accuracy: 51), fix(5, speed: -1), fix(5, speed: 4), fix(5, meters: 151)] {
            gate = DestinationArrivalGate()
            XCTAssertTrue(!observe(&gate, fix(0), at: 0))
            _ = observe(&gate, bad, at: 5)
            XCTAssertTrue(!observe(&gate, fix(10), at: 10))
        }
        gate = DestinationArrivalGate()
        XCTAssertTrue(!observe(&gate, fix(0), at: 0))
        XCTAssertTrue(!observe(&gate, fix(5), at: 5, otherDistance: 60))
        XCTAssertTrue(!observe(&gate, fix(10), at: 10))
        gate = DestinationArrivalGate()
        XCTAssertTrue(!observe(&gate, fix(0), at: 0))
        XCTAssertTrue(!observe(&gate, fix(16), at: 16))
        XCTAssertTrue(observe(&gate, fix(26), at: 26))
        gate = DestinationArrivalGate()
        XCTAssertTrue(!observe(&gate, fix(0), at: 0))
        XCTAssertTrue(!observe(&gate, fix(10, meters: 21), at: 10))
        XCTAssertTrue(observe(&gate, fix(20, meters: 21), at: 20))
        // Legacy gates must not inherit the old broad fallback or uncertain-arrival evidence.
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(gate)) as! [String: Any]
        legacy.removeValue(forKey: "stopEvidence")
        gate = try JSONDecoder().decode(DestinationArrivalGate.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(!observe(&gate, fix(30), at: 30))
        let stations = [("A", 39.98), ("C", 39.965), ("B", 39.95)].map { id, lat in
            Station(id: id, code: id, name: id, latitude: lat, longitude: -75.16, zone: "1", url: "")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let route = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", now: base.addingTimeInterval(-60), directory: directory)!
        var arrivalCheck: DestinationArrivalGate?
        _ = SharedRouteCoordinator.resolve(location: fix(0, speed: -1), stations: stations, now: base, directory: directory,
            onArrivalCheck: { arrivalCheck = $0 })
        XCTAssertTrue(arrivalCheck?.lastDecision.contains("Precise GPS arrival rejected: Stopped motion not established by location speed") == true)
        let first = SharedRouteCoordinator.resolve(location: fix(0), stations: stations, now: base, directory: directory,
            onArrivalCheck: { arrivalCheck = $0 })!
        XCTAssertTrue(arrivalCheck?.diagnosticDescription(for: fix(0), now: base).contains("0 of 10 sec") == true)
        XCTAssertTrue(first.originId == route.originId && first.revision == route.revision)
        let duplicate = SharedRouteCoordinator.resolve(location: fix(0), stations: stations, now: base.addingTimeInterval(10), directory: directory)!
        XCTAssertTrue(duplicate.revision == route.revision)
        let arrived = SharedRouteCoordinator.resolve(location: fix(10), stations: stations, now: base.addingTimeInterval(10), directory: directory,
            onArrivalCheck: { arrivalCheck = $0 })!
        XCTAssertTrue(arrivalCheck?.confirmed == true)
        XCTAssertTrue(arrived.originId == "B" && arrived.destinationId == "A" && arrived.revision == route.revision + 1)
        let lostDirectory = directory.appendingPathComponent("lost-location")
        _ = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", now: base.addingTimeInterval(-60), directory: lostDirectory)
        _ = SharedRouteCoordinator.resolve(location: fix(20), stations: stations, now: base.addingTimeInterval(20), directory: lostDirectory)
        _ = SharedRouteCoordinator.checkArrival(expectedRevision: 1, location: nil, stations: stations,
            now: base.addingTimeInterval(25), directory: lostDirectory)
        let restarted = SharedRouteCoordinator.resolve(location: fix(30), stations: stations,
            now: base.addingTimeInterval(30), directory: lostDirectory)!
        XCTAssertTrue(restarted.revision == 1 && restarted.originId == "A")
        let recovered = SharedRouteCoordinator.resolve(location: fix(40), stations: stations,
            now: base.addingTimeInterval(40), directory: lostDirectory)!
        XCTAssertTrue(recovered.revision == 2 && recovered.originId == "B")
        var presence = StationStopEvidence()
        // Oct 8 Ashland: a four-second stop followed by a long gap is not ten seconds of evidence.
        for second in 0...3 {
            let reading = fix(Double(second), meters: 42, accuracy: 5, speed: 0.1)
            XCTAssertTrue(!presence.accepts(stationId: "A", station: station, location: reading,
                allowMissingSpeed: true, now: base.addingTimeInterval(Double(second))))
        }
        let afterGap = fix(84, meters: 53, accuracy: 9, speed: 1.9)
        XCTAssertTrue(!presence.accepts(stationId: "A", station: station, location: afterGap,
            allowMissingSpeed: true, now: base.addingTimeInterval(84)))
        XCTAssertTrue(presence.diagnosticDescription(for: afterGap, now: base.addingTimeInterval(84)).contains("Not stopped"))
        // Continued fresh samples through a stop confirm presence, without counting timer ticks.
        for second in 90...102 {
            let reading = fix(Double(second), meters: 43, accuracy: 5, speed: 0.1)
            let confirmed = presence.accepts(stationId: "A", station: station, location: reading,
                allowMissingSpeed: true, now: base.addingTimeInterval(Double(second)))
            XCTAssertTrue(confirmed == (second >= 100))
        }
        XCTAssertTrue(presence.diagnosticDescription(for: fix(102), now: base.addingTimeInterval(102)).contains("12 of 10 sec"))
        presence = StationStopEvidence()
        XCTAssertTrue(!presence.accepts(stationId: "B", station: station, location: fix(0), now: base))
        XCTAssertTrue(!presence.accepts(stationId: "B", station: station, location: fix(5, speed: 10), now: base.addingTimeInterval(5)))
        XCTAssertTrue(!presence.accepts(stationId: "B", station: station, location: fix(10), now: base.addingTimeInterval(10)))
        XCTAssertTrue(presence.accepts(stationId: "B", station: station, location: fix(20), now: base.addingTimeInterval(20)))
        // Oct 7 Haddonfield: 12 seconds stopped, 17-19 m away, 5 m accuracy.
        presence = StationStopEvidence()
        for second in 0...12 {
            let confirmed = presence.accepts(stationId: "C", station: station,
                location: fix(Double(second), meters: 17 + Double(second) / 6, accuracy: 5, speed: 0.2),
                allowMissingSpeed: true, now: base.addingTimeInterval(Double(second)))
            XCTAssertTrue(confirmed == (second >= 10))
        }
        // Oct 7 Woodcrest: missing speed can establish presence, never destination arrival.
        presence = StationStopEvidence()
        gate = DestinationArrivalGate()
        for second in 0...25 {
            let reading = fix(Double(second), meters: 39, accuracy: 3, speed: -1)
            let confirmed = presence.accepts(stationId: "C", station: station, location: reading,
                allowMissingSpeed: true, now: base.addingTimeInterval(Double(second)))
            XCTAssertTrue(confirmed == (second >= 10))
            XCTAssertTrue(!observe(&gate, reading, at: Double(second)))
        }
        // Sparse or duplicated fixes, drift, poor accuracy and explicit motion cannot substitute for a stop.
        for scenario in 0..<6 {
            presence = StationStopEvidence()
            for second in 0...30 {
                let reading = fix(scenario == 0 ? 0 : Double(second),
                    meters: scenario == 1 ? Double(second) * 2 : 39,
                    accuracy: scenario == 2 ? 11 : 3,
                    speed: scenario == 3 ? 1 : -1)
                if scenario == 4 && second != 0 && second != 30 { continue }
                if scenario == 5 && second != 0 && second != 10 && second != 20 && second != 30 { continue }
                XCTAssertTrue(!presence.accepts(stationId: "C", station: station, location: reading,
                    allowMissingSpeed: true, now: base.addingTimeInterval(Double(second))))
            }
        }
        // A temporary intermediate stop preserves endpoints and journey evidence, then restores on exit.
        let stopDirectory = directory.appendingPathComponent("intermediate")
        let outbound = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true,
            now: base, directory: stopDirectory)!
        let intermediate = SharedRouteCoordinator.selectStationDepartures(expectedRevision: outbound.revision,
            originId: "C", destinationId: "B", stations: stations, automatic: true,
            now: base.addingTimeInterval(30), directory: stopDirectory)!
        XCTAssertTrue(intermediate.savedOriginId == "A" && intermediate.savedDestinationId == "B")
        XCTAssertTrue(intermediate.temporaryRoute?.originId == "A" && intermediate.manual)
        XCTAssertTrue(intermediate.journeySelectedAt == (outbound.journeySelectedAt ?? outbound.updatedAt))
        let relaunched = SharedRouteCoordinator.current(directory: stopDirectory)!
        let restored = SharedRouteCoordinator.restoreStationRoute(expectedRevision: relaunched.revision,
            departureLocation: fix(40), requireDeparture: true, stations: stations,
            now: base.addingTimeInterval(40), directory: stopDirectory)!
        XCTAssertTrue(restored.originId == "A" && restored.destinationId == "B" && restored.manual)
        XCTAssertTrue(restored.temporaryRoute == nil)
        print("Conservative station checks passed: reported failures, stopped dwell, missing speed, duplicates, uncertainty, drift, legacy state and background arrival")
    }
}
