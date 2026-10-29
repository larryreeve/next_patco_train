#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct CurrentStationCheck {
    static func run() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let station = CLLocation(latitude: 39.95, longitude: -75.16)
        func fix(_ t: Double, accuracy: Double = 19, speed: Double = 0, offset: Double = 73) -> CLLocation {
            CLLocation(coordinate: .init(latitude: 39.95 + offset / 111_195, longitude: -75.16), altitude: 0,
                horizontalAccuracy: accuracy, verticalAccuracy: 1, course: -1, speed: speed,
                timestamp: base.addingTimeInterval(t))
        }
        func accept(_ evidence: inout CurrentStationEvidence, _ t: Double, accuracy: Double = 19,
                    speed: Double = 0, offset: Double = 73, other: Double = 1000, wall: Double? = nil) -> Bool {
            evidence.accepts(stationId: "B", station: station,
                location: fix(t, accuracy: accuracy, speed: speed, offset: offset),
                nearestOtherDistance: other, now: base.addingTimeInterval(wall ?? t))
        }
        // Synthetic positions approximate the reported distances, not a full GPS replay.
        var evidence = CurrentStationEvidence()
        for t in 0...7 {
            XCTAssertTrue(accept(&evidence, Double(t)), "Westmont must register on its first inside fix")
        }
        XCTAssertTrue(accept(&evidence, 8, speed: 1.1), "Moving within the boundary must retain station presence")

        evidence = CurrentStationEvidence()
        for t in 0...10 {
            XCTAssertTrue(accept(&evidence, Double(t), accuracy: 29, speed: -1, offset: 42 - Double(t) / 2),
                "Haddonfield must not wait for speed or dwell evidence")
        }
        evidence = CurrentStationEvidence()
        for t in 0...10 {
            XCTAssertTrue(accept(&evidence, Double(t), accuracy: 25, speed: t % 2 == 0 ? -1 : 0.6),
                "Missing speed and small speed fluctuations must not interrupt presence")
        }
        for scenario in ["inaccurate", "outside", "ambiguous", "stale", "future", "invalidAccuracy"] {
            evidence = CurrentStationEvidence()
            for t in 0...20 {
                XCTAssertTrue(!accept(&evidence, Double(t), accuracy: scenario == "inaccurate" ? 51 : scenario == "invalidAccuracy" ? -1 : 25,
                    speed: -1,
                    offset: scenario == "outside" ? 140 : 73,
                    other: scenario == "ambiguous" ? 100 : 1000,
                    wall: Double(t) + (scenario == "stale" ? 16 : scenario == "future" ? -1 : 0)), "Unsafe presence: \(scenario)")
            }
        }
        evidence = CurrentStationEvidence()
        // Collingswood: first inside fix while still arriving at 43.5 mph.
        XCTAssertTrue(!accept(&evidence, 0, accuracy: 12, speed: 21.7, offset: 166))
        XCTAssertTrue(accept(&evidence, 1, accuracy: 3, speed: 19.4, offset: 129))
        XCTAssertTrue(accept(&evidence, 2, accuracy: 3, speed: 18.5, offset: 111))
        XCTAssertTrue(accept(&evidence, 3, accuracy: 3, speed: 12.5, offset: 7))
        XCTAssertTrue(!accept(&evidence, 4, accuracy: 2, speed: 16, offset: 165), "Exit must clear presence")
        XCTAssertTrue(accept(&evidence, 5, accuracy: 3, speed: 19.4, offset: 129), "Reentry must register immediately")
        evidence = CurrentStationEvidence()
        XCTAssertTrue(accept(&evidence, 0))
        for _ in 0...20 { XCTAssertTrue(accept(&evidence, 0, wall: 10)) }
        XCTAssertTrue(!accept(&evidence, 0, wall: 16), "A cached fix must expire")
        XCTAssertTrue(accept(&evidence, 16), "A fresh fix must not require a new dwell window")
        XCTAssertTrue(!accept(&evidence, 15, speed: 30), "Out-of-order readings cannot confirm")
        XCTAssertTrue(accept(&evidence, 21), "Out-of-order readings must not erase newer evidence")

        var destination = DestinationArrivalGate()
        for t in 0...30 {
            XCTAssertTrue(!destination.accepts(destinationId: "B", station: station,
                location: fix(Double(t), accuracy: 8, speed: -1), nearestOtherStationDistance: 1000,
                routeSelectedAt: base.addingTimeInterval(-1), now: base.addingTimeInterval(Double(t))),
                "Position-only presence must never weaken destination reversal rules")
        }
        XCTAssertTrue(CurrentStationEvidence.isPresenceReading(fix(0, accuracy: 29, speed: -1), now: base))
        print("Current station checks passed")
    }
}
